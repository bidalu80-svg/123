import Foundation

struct MinimalAgentToolSpec {
    let name: String
    let description: String
    let parameters: [String: Any]
}

struct MinimalAgentToolCall {
    let id: String
    let name: String
    let arguments: [String: Any]
    let argumentsJSON: String
}

struct MinimalAgentToolTurnResponse {
    let responseID: String?
    let assistantText: String
    let toolCalls: [MinimalAgentToolCall]
}

struct MinimalAgentToolExecution {
    let renderedLog: String
    let output: String
}

enum MinimalAgentToolResponseParser {
    static func parseChatCompletionsResponse(_ object: [String: Any]) -> MinimalAgentToolTurnResponse {
        let text = normalizedAssistantText(StreamParser.extractPayload(from: object).text)
        let choice = (object["choices"] as? [[String: Any]])?.first
        let message = choice?["message"] as? [String: Any] ?? [:]
        return MinimalAgentToolTurnResponse(
            responseID: nil,
            assistantText: text,
            toolCalls: parseChatToolCalls(from: message)
        )
    }

    static func parseResponsesResponse(_ object: [String: Any]) -> MinimalAgentToolTurnResponse {
        let root = (object["response"] as? [String: Any]) ?? object
        let text = normalizedAssistantText(StreamParser.extractPayload(from: root).text)
        let output = root["output"] as? [[String: Any]] ?? []
        return MinimalAgentToolTurnResponse(
            responseID: firstNonEmptyString(root["id"], object["id"]),
            assistantText: text,
            toolCalls: parseResponsesToolCalls(from: output)
        )
    }

    private static func parseChatToolCalls(from message: [String: Any]) -> [MinimalAgentToolCall] {
        guard let rawCalls = message["tool_calls"] as? [[String: Any]] else {
            return []
        }
        return rawCalls.compactMap { raw in
            let function = raw["function"] as? [String: Any]
            let id = firstNonEmptyString(raw["id"], raw["tool_call_id"]) ?? UUID().uuidString
            let name = firstNonEmptyString(function?["name"], raw["name"]) ?? ""
            let arguments = function?["arguments"] ?? raw["arguments"] ?? raw["input"]
            return makeToolCall(id: id, name: name, rawArguments: arguments)
        }
    }

    private static func parseResponsesToolCalls(from output: [[String: Any]]) -> [MinimalAgentToolCall] {
        output.compactMap { item in
            let type = (item["type"] as? String ?? "").lowercased()
            guard type == "function_call" || type == "tool_call" else {
                return nil
            }
            let id = firstNonEmptyString(item["call_id"], item["id"]) ?? UUID().uuidString
            let name = firstNonEmptyString(item["name"], (item["function"] as? [String: Any])?["name"]) ?? ""
            let arguments = item["arguments"] ?? item["input"] ?? item["parameters"]
            return makeToolCall(id: id, name: name, rawArguments: arguments)
        }
    }

    private static func makeToolCall(id: String, name: String, rawArguments: Any?) -> MinimalAgentToolCall? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }

        if let dict = rawArguments as? [String: Any] {
            let json = jsonString(from: dict) ?? "{}"
            return MinimalAgentToolCall(id: id, name: trimmedName, arguments: dict, argumentsJSON: json)
        }

        if let text = rawArguments as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let payload = trimmed.isEmpty ? "{}" : trimmed
            if let data = payload.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return MinimalAgentToolCall(id: id, name: trimmedName, arguments: object, argumentsJSON: payload)
            }
            return MinimalAgentToolCall(id: id, name: trimmedName, arguments: [:], argumentsJSON: payload)
        }

        return MinimalAgentToolCall(id: id, name: trimmedName, arguments: [:], argumentsJSON: "{}")
    }

    private static func normalizedAssistantText(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstNonEmptyString(_ candidates: Any?...) -> String? {
        for candidate in candidates {
            if let text = candidate as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    private static func jsonString(from object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }
}

final class MinimalAgentToolRuntime {
    static let systemPrompt = """
    你现在具备 6 个正式工具：`list_dir`、`read_file`、`write_file`、`edit_file`、`grep_files`、`shell_exec`。
    执行规则：
    - 需要查看当前 latest 工作区时，优先调用工具，不要猜目录和文件内容。
    - 需要修改文件时，优先最小改动；小范围修改优先 `edit_file`，新建或整体重写使用 `write_file`。
    - 需要运行、安装、测试、构建时，使用 `shell_exec`，不要只把命令写给用户。
    - 不要把 `[[file:...]]`、`[[mkdir:...]]`、`touch`、`mkdir` 之类文本当成主要执行方式；能用工具就直接用工具。
    - `write_file` 会自动创建父目录，因此缺少目录时无需先输出伪指令。
    - 如果工具返回错误，必须基于错误继续处理或明确说明，不要假装成功。
    - 完成后用简短自然语言汇报结果。
    """

    private let shellExecutionService: RemoteShellExecutionService
    private let fileManager = FileManager.default

    init(shellExecutionService: RemoteShellExecutionService = .shared) {
        self.shellExecutionService = shellExecutionService
    }

    var toolSpecs: [MinimalAgentToolSpec] {
        [
            MinimalAgentToolSpec(
                name: "list_dir",
                description: "列出 latest 工作区中的目录内容。适合先查看项目结构。",
                parameters: [
                    "type": "object",
                    "properties": [
                        "path": [
                            "type": "string",
                            "description": "相对路径，留空表示 latest 根目录。"
                        ],
                        "limit": [
                            "type": "integer",
                            "description": "最多返回多少项，默认 120。"
                        ]
                    ]
                ]
            ),
            MinimalAgentToolSpec(
                name: "read_file",
                description: "读取 latest 工作区中的文本文件，可按行截取。",
                parameters: [
                    "type": "object",
                    "properties": [
                        "path": [
                            "type": "string",
                            "description": "相对文件路径。"
                        ],
                        "startLine": [
                            "type": "integer",
                            "description": "起始行号，1 开始。"
                        ],
                        "endLine": [
                            "type": "integer",
                            "description": "结束行号，1 开始。"
                        ],
                        "maxCharacters": [
                            "type": "integer",
                            "description": "最多返回多少字符，默认 6000。"
                        ]
                    ],
                    "required": ["path"]
                ]
            ),
            MinimalAgentToolSpec(
                name: "write_file",
                description: "写入 latest 工作区中的文件，会覆盖原文件并自动创建父目录。",
                parameters: [
                    "type": "object",
                    "properties": [
                        "path": [
                            "type": "string",
                            "description": "相对文件路径。"
                        ],
                        "content": [
                            "type": "string",
                            "description": "完整文件内容。"
                        ]
                    ],
                    "required": ["path", "content"]
                ]
            ),
            MinimalAgentToolSpec(
                name: "edit_file",
                description: "对 latest 工作区中的文件做一次精确文本替换，适合小范围修补。",
                parameters: [
                    "type": "object",
                    "properties": [
                        "path": [
                            "type": "string",
                            "description": "相对文件路径。"
                        ],
                        "oldText": [
                            "type": "string",
                            "description": "要替换的原文本，必须精确匹配。"
                        ],
                        "newText": [
                            "type": "string",
                            "description": "替换后的新文本。"
                        ]
                    ],
                    "required": ["path", "oldText", "newText"]
                ]
            ),
            MinimalAgentToolSpec(
                name: "grep_files",
                description: "在 latest 工作区中按文本搜索，返回匹配的文件和行号。",
                parameters: [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "要搜索的文本。"
                        ],
                        "path": [
                            "type": "string",
                            "description": "相对目录或文件路径，留空表示整个 latest。"
                        ],
                        "limit": [
                            "type": "integer",
                            "description": "最多返回多少条匹配，默认 40。"
                        ]
                    ],
                    "required": ["query"]
                ]
            ),
            MinimalAgentToolSpec(
                name: "shell_exec",
                description: "在远端 shell 工作区执行命令，适合安装依赖、运行测试、构建和查看命令输出。",
                parameters: [
                    "type": "object",
                    "properties": [
                        "command": [
                            "type": "string",
                            "description": "要执行的完整 shell 命令。"
                        ],
                        "timeoutSeconds": [
                            "type": "integer",
                            "description": "超时时间，默认使用设置中的终端超时。"
                        ]
                    ],
                    "required": ["command"]
                ]
            )
        ]
    }

    func execute(call: MinimalAgentToolCall, config: ChatConfig) async -> MinimalAgentToolExecution {
        switch call.name {
        case "list_dir":
            return executeListDir(arguments: call.arguments)
        case "read_file":
            return executeReadFile(arguments: call.arguments)
        case "write_file":
            return executeWriteFile(arguments: call.arguments)
        case "edit_file":
            return executeEditFile(arguments: call.arguments)
        case "grep_files":
            return executeGrepFiles(arguments: call.arguments)
        case "shell_exec":
            return await executeShellExec(arguments: call.arguments, config: config)
        default:
            return MinimalAgentToolExecution(
                renderedLog: "工具 `\(call.name)` 不可用",
                output: "错误：未知工具 `\(call.name)`。"
            )
        }
    }

    private func executeListDir(arguments: [String: Any]) -> MinimalAgentToolExecution {
        let rawPath = stringValue(arguments["path"])
        let displayPath = displayPathForLog(rawPath)
        do {
            let rootURL = try latestWorkspaceURL(createIfMissing: true)
            let targetURL: URL
            if let rawPath, !rawPath.isEmpty, rawPath != "." {
                targetURL = try resolveWorkspaceURL(for: rawPath, createWorkspaceIfMissing: true).url
            } else {
                targetURL = rootURL
            }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: targetURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return MinimalAgentToolExecution(
                    renderedLog: "列出 `\(displayPath)`",
                    output: "错误：目录 `\(displayPath)` 不存在。"
                )
            }

            let limit = boundedInt(arguments["limit"], defaultValue: 120, min: 1, max: 400)
            let entries = try fileManager.contentsOfDirectory(
                at: targetURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            let rendered = entries
                .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
                .prefix(limit)
                .map { url -> String in
                    let isDir = ((try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory) == true
                    return isDir ? "\(url.lastPathComponent)/" : url.lastPathComponent
                }

            let text = rendered.isEmpty ? "[empty]" : rendered.joined(separator: "\n")
            return MinimalAgentToolExecution(
                renderedLog: "列出 `\(displayPath)`",
                output: clippedOutput(text, limit: 6_000)
            )
        } catch {
            return MinimalAgentToolExecution(
                renderedLog: "列出 `\(displayPath)`",
                output: "错误：\(error.localizedDescription)"
            )
        }
    }

    private func executeReadFile(arguments: [String: Any]) -> MinimalAgentToolExecution {
        let rawPath = stringValue(arguments["path"]) ?? ""
        let displayPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let resolved = try resolveWorkspaceURL(for: rawPath)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: resolved.url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return MinimalAgentToolExecution(
                    renderedLog: "读取 `\(resolved.path)`",
                    output: "错误：文件 `\(resolved.path)` 不存在。"
                )
            }

            let content = try String(contentsOf: resolved.url, encoding: .utf8)
            let allLines = content.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            let startLine = boundedInt(arguments["startLine"], defaultValue: 1, min: 1, max: max(allLines.count, 1))
            let requestedEnd = boundedInt(arguments["endLine"], defaultValue: min(allLines.count, startLine + 199), min: startLine, max: max(allLines.count, startLine))
            let endLine = min(max(requestedEnd, startLine), allLines.count)
            let maxCharacters = boundedInt(arguments["maxCharacters"], defaultValue: 6_000, min: 400, max: 20_000)

            let slice = allLines.enumerated().compactMap { index, line -> String? in
                let lineNumber = index + 1
                guard lineNumber >= startLine, lineNumber <= endLine else { return nil }
                return "\(lineNumber)\t\(line)"
            }
            let text = slice.joined(separator: "\n")
            return MinimalAgentToolExecution(
                renderedLog: "读取 `\(resolved.path)`",
                output: clippedOutput(text.isEmpty ? "[empty file]" : text, limit: maxCharacters)
            )
        } catch {
            return MinimalAgentToolExecution(
                renderedLog: displayPath.isEmpty ? "读取文件" : "读取 `\(displayPath)`",
                output: "错误：\(error.localizedDescription)"
            )
        }
    }

    private func executeWriteFile(arguments: [String: Any]) -> MinimalAgentToolExecution {
        let rawPath = stringValue(arguments["path"]) ?? ""
        let content = stringValue(arguments["content"]) ?? ""
        do {
            let resolved = try resolveWorkspaceURL(for: rawPath, createWorkspaceIfMissing: true)
            try fileManager.createDirectory(at: resolved.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: resolved.url, atomically: true, encoding: .utf8)
            return MinimalAgentToolExecution(
                renderedLog: "写入 `\(resolved.path)`",
                output: "已写入 `\(resolved.path)`（\(content.count) 字符）。"
            )
        } catch {
            return MinimalAgentToolExecution(
                renderedLog: rawPath.isEmpty ? "写入文件" : "写入 `\(rawPath)`",
                output: "错误：\(error.localizedDescription)"
            )
        }
    }

    private func executeEditFile(arguments: [String: Any]) -> MinimalAgentToolExecution {
        let rawPath = stringValue(arguments["path"]) ?? ""
        let oldText = stringValue(arguments["oldText"]) ?? ""
        let newText = stringValue(arguments["newText"]) ?? ""
        do {
            let resolved = try resolveWorkspaceURL(for: rawPath)
            let content = try String(contentsOf: resolved.url, encoding: .utf8)
            guard let range = content.range(of: oldText) else {
                return MinimalAgentToolExecution(
                    renderedLog: "编辑 `\(resolved.path)`",
                    output: "错误：在 `\(resolved.path)` 中没有找到待替换文本。"
                )
            }

            var updated = content
            updated.replaceSubrange(range, with: newText)
            try updated.write(to: resolved.url, atomically: true, encoding: .utf8)
            return MinimalAgentToolExecution(
                renderedLog: "编辑 `\(resolved.path)`",
                output: "已编辑 `\(resolved.path)`。"
            )
        } catch {
            return MinimalAgentToolExecution(
                renderedLog: rawPath.isEmpty ? "编辑文件" : "编辑 `\(rawPath)`",
                output: "错误：\(error.localizedDescription)"
            )
        }
    }

    private func executeGrepFiles(arguments: [String: Any]) -> MinimalAgentToolExecution {
        let query = stringValue(arguments["query"]) ?? ""
        let rawPath = stringValue(arguments["path"])
        let displayQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayQuery.isEmpty else {
            return MinimalAgentToolExecution(
                renderedLog: "搜索文本",
                output: "错误：缺少搜索文本。"
            )
        }

        do {
            let rootURL = try latestWorkspaceURL(createIfMissing: true)
            let target: URL
            let displayPath = displayPathForLog(rawPath)
            if let rawPath, !rawPath.isEmpty, rawPath != "." {
                target = try resolveWorkspaceURL(for: rawPath).url
            } else {
                target = rootURL
            }

            var matches: [String] = []
            let limit = boundedInt(arguments["limit"], defaultValue: 40, min: 1, max: 200)

            if isRegularFile(target) {
                matches.append(contentsOf: grepMatches(in: target, root: rootURL, query: displayQuery, limit: limit))
            } else {
                guard let enumerator = fileManager.enumerator(
                    at: target,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else {
                    throw NSError(domain: "MinimalAgentToolRuntime", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法遍历目录。"])
                }
                for case let fileURL as URL in enumerator {
                    if matches.count >= limit { break }
                    guard isRegularFile(fileURL) else { continue }
                    let remaining = limit - matches.count
                    matches.append(contentsOf: grepMatches(in: fileURL, root: rootURL, query: displayQuery, limit: remaining))
                }
            }

            let output = matches.isEmpty ? "未找到匹配项。" : matches.joined(separator: "\n")
            return MinimalAgentToolExecution(
                renderedLog: "搜索 `\(displayQuery)`",
                output: clippedOutput(output, limit: 8_000)
            )
        } catch {
            return MinimalAgentToolExecution(
                renderedLog: "搜索 `\(displayQuery)`",
                output: "错误：\(error.localizedDescription)"
            )
        }
    }

    private func executeShellExec(arguments: [String: Any], config: ChatConfig) async -> MinimalAgentToolExecution {
        let command = stringValue(arguments["command"]) ?? ""
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else {
            return MinimalAgentToolExecution(
                renderedLog: "执行 shell 命令",
                output: "错误：命令为空。"
            )
        }

        let timeoutSeconds = TimeInterval(
            boundedInt(
                arguments["timeoutSeconds"],
                defaultValue: Int(config.shellExecutionTimeout),
                min: 5,
                max: 300
            )
        )
        let workingDirectory = config.shellExecutionWorkingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let result = try await shellExecutionService.run(
                command: trimmedCommand,
                endpoint: config.shellExecutionURLString,
                apiKey: config.apiKey,
                workingDirectory: workingDirectory.isEmpty ? nil : workingDirectory,
                timeout: timeoutSeconds
            )
            let suffix = result.exitCode == 0 ? "" : "\n\n[exit code \(result.exitCode)]"
            return MinimalAgentToolExecution(
                renderedLog: "执行 shell 命令",
                output: clippedOutput(result.output + suffix, limit: 12_000)
            )
        } catch {
            return MinimalAgentToolExecution(
                renderedLog: "执行 shell 命令",
                output: "错误：\(error.localizedDescription)"
            )
        }
    }

    private func latestWorkspaceURL(createIfMissing: Bool) throws -> URL {
        guard let latest = FrontendProjectBuilder.latestProjectURL() else {
            throw NSError(domain: "MinimalAgentToolRuntime", code: 1, userInfo: [NSLocalizedDescriptionKey: "latest 工作区不可用。"])
        }
        if createIfMissing, !fileManager.fileExists(atPath: latest.path) {
            try fileManager.createDirectory(at: latest, withIntermediateDirectories: true)
        }
        return latest
    }

    private func resolveWorkspaceURL(
        for rawPath: String,
        createWorkspaceIfMissing: Bool = false
    ) throws -> (url: URL, path: String) {
        guard let path = FrontendProjectBuilder.normalizeWorkspaceRelativePath(rawPath) else {
            throw NSError(domain: "MinimalAgentToolRuntime", code: 3, userInfo: [NSLocalizedDescriptionKey: "路径无效：\(rawPath)"])
        }
        let latest = try latestWorkspaceURL(createIfMissing: createWorkspaceIfMissing)
        return (latest.appendingPathComponent(path, isDirectory: false), path)
    }

    private func grepMatches(in fileURL: URL, root: URL, query: String, limit: Int) -> [String] {
        guard limit > 0,
              let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return []
        }
        let relativePath = relativePath(for: fileURL, root: root)
        let lines = content.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var output: [String] = []
        for (index, line) in lines.enumerated() {
            if output.count >= limit { break }
            if line.localizedCaseInsensitiveContains(query) {
                output.append("\(relativePath):\(index + 1): \(line)")
            }
        }
        return output
    }

    private func isRegularFile(_ url: URL) -> Bool {
        ((try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile) == true
    }

    private func relativePath(for fileURL: URL, root: URL) -> String {
        let absolute = fileURL.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        if absolute.hasPrefix(rootPath + "/") {
            return String(absolute.dropFirst(rootPath.count + 1))
        }
        return fileURL.lastPathComponent
    }

    private func displayPathForLog(_ rawPath: String?) -> String {
        let trimmed = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "." : trimmed
    }

    private func stringValue(_ raw: Any?) -> String? {
        if let text = raw as? String {
            return text
        }
        if let number = raw as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private func boundedInt(_ raw: Any?, defaultValue: Int, min: Int, max: Int) -> Int {
        let value: Int
        if let number = raw as? NSNumber {
            value = number.intValue
        } else if let text = raw as? String, let parsed = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            value = parsed
        } else {
            value = defaultValue
        }
        return Swift.max(min, Swift.min(max, value))
    }

    private func clippedOutput(_ raw: String, limit: Int) -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)) + "\n...[truncated]"
    }
}
