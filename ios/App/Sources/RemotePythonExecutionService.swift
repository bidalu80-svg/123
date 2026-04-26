import Foundation

enum RemotePythonExecutionMode: String {
    case runFile = "run_file"
    case unitTests = "unit_tests"
    case compileAll = "compile_all"
}

struct RemotePythonExecutionResult: Equatable {
    let output: String
    let exitCode: Int
}

final class RemotePythonExecutionService {
    static let shared = RemotePythonExecutionService()

    private struct PayloadFile {
        let path: String
        let contentBase64: String
    }

    private struct RemoteShellExecutionResult {
        let output: String
        let exitCode: Int
        let finalWorkingDirectory: String?
    }

    private let fileManager = FileManager.default
    private let session: URLSession
    private let maxFiles = 180
    private let maxSingleFileBytes = 1_200_000
    private let maxTotalBytes = 7_500_000
    private let builtInShellExecuteURL = ChatConfig.defaultBuiltInRemotePythonShellExecuteURL
    private let builtInShellWorkingDirectory = "latest"
    private let shellUploadChunkSize = 5_800

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
            return
        }

        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 900
        self.session = URLSession(configuration: configuration)
    }

    func execute(
        mode: RemotePythonExecutionMode,
        projectURL: URL,
        entryPath: String? = nil,
        stdin: String? = nil,
        config: ChatConfig
    ) async throws -> RemotePythonExecutionResult {
        let files = try collectProjectFiles(from: projectURL)
        let endpoint = config.remotePythonExecutionURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !endpoint.isEmpty {
            return try await executeViaDedicatedRunner(
                endpoint: endpoint,
                mode: mode,
                files: files,
                entryPath: entryPath,
                stdin: stdin,
                config: config
            )
        }

        return try await executeViaBuiltInShellRunner(
            mode: mode,
            files: files,
            entryPath: entryPath,
            stdin: stdin,
            config: config
        )
    }

    private func executeViaDedicatedRunner(
        endpoint: String,
        mode: RemotePythonExecutionMode,
        files: [PayloadFile],
        entryPath: String?,
        stdin: String?,
        config: ChatConfig
    ) async throws -> RemotePythonExecutionResult {
        guard let url = URL(string: endpoint) else {
            throw NSError(
                domain: "RemotePythonExecutionService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "远端 Python 执行地址无效。"]
            )
        }

        var payload: [String: Any] = [
            "mode": mode.rawValue,
            "timeout": Int(config.remotePythonExecutionTimeout.rounded()),
            "files": files.map { file in
                [
                    "path": file.path,
                    "content_base64": file.contentBase64
                ]
            }
        ]

        if let entryPath,
           !entryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["entry_path"] = entryPath
        }
        if let stdin {
            payload["stdin"] = stdin
        }

        var request = URLRequest(
            url: url,
            timeoutInterval: max(30, min(config.remotePythonExecutionTimeout, 900))
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let token = config.resolvedRemotePythonExecutionAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(token, forHTTPHeaderField: "x-api-key")
            request.setValue(token, forHTTPHeaderField: "api-key")
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "RemotePythonExecutionService",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "远端 Python 响应无效。"]
            )
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "RemotePythonExecutionService",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "远端 Python 返回 JSON 无效（HTTP \(httpResponse.statusCode)）。"]
            )
        }

        if !(200...299).contains(httpResponse.statusCode) {
            let message = firstNonEmptyString(
                object["detail"],
                object["message"],
                object["error"],
                object["combined_output"]
            ) ?? "HTTP \(httpResponse.statusCode)"
            throw NSError(
                domain: "RemotePythonExecutionService",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "远端 Python 执行失败：\(message)"]
            )
        }

        let exitCode = parseInt(object["exit_code"]) ?? parseInt(object["exitCode"]) ?? 1
        let stdout = firstNonEmptyString(object["stdout"]) ?? ""
        let stderr = firstNonEmptyString(object["stderr"]) ?? ""
        let installLog = firstNonEmptyString(object["install_log"], object["installLog"]) ?? ""
        let combinedOutput = firstNonEmptyString(
            object["combined_output"],
            object["combinedOutput"],
            object["output"]
        ) ?? ([stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n"))

        var segments: [String] = ["[远端 Python 执行]"]
        if !installLog.isEmpty {
            segments.append("安装日志：\n\(installLog)")
        }
        if !combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            segments.append(combinedOutput)
        } else if !stdout.isEmpty || !stderr.isEmpty {
            segments.append([stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n"))
        } else {
            segments.append("执行完成（无输出）")
        }

        return RemotePythonExecutionResult(
            output: segments.joined(separator: "\n\n"),
            exitCode: exitCode
        )
    }

    private func executeViaBuiltInShellRunner(
        mode: RemotePythonExecutionMode,
        files: [PayloadFile],
        entryPath: String?,
        stdin: String?,
        config: ChatConfig
    ) async throws -> RemotePythonExecutionResult {
        let jobID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let workspace = ".iexa_remote_python/\(jobID)"
        let timeout = Int(min(max(config.remotePythonExecutionTimeout.rounded(), 30), 300))
        let endpoint = builtInShellExecuteURL
        let apiKey = config.resolvedShellExecutionAPIKey
        let cwd = builtInShellWorkingDirectory
        let result: RemotePythonExecutionResult

        do {
            _ = try await shellExecute(
                endpoint: endpoint,
                apiKey: apiKey,
                cwd: cwd,
                command: "mkdir -p \(shellQuote(workspace))",
                timeout: 30
            )

            for file in files {
                try await uploadFileToBuiltInShellRunner(
                    file,
                    workspace: workspace,
                    endpoint: endpoint,
                    apiKey: apiKey,
                    cwd: cwd
                )
            }

            let installLog = try await prepareBuiltInShellEnvironment(
                workspace: workspace,
                files: files,
                endpoint: endpoint,
                apiKey: apiKey,
                cwd: cwd,
                timeout: timeout
            )

            let executeCommand = try builtInShellCommand(
                mode: mode,
                workspace: workspace,
                entryPath: entryPath,
                stdin: stdin
            )
            let execution = try await shellExecute(
                endpoint: endpoint,
                apiKey: apiKey,
                cwd: cwd,
                command: executeCommand,
                timeout: timeout
            )

            var sections: [String] = ["[远端 Python 执行·内置阿里云]"]
            if !installLog.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sections.append("安装日志：\n\(installLog)")
            }
            let trimmedOutput = execution.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedOutput.isEmpty {
                sections.append(trimmedOutput)
            } else {
                sections.append("执行完成（无输出）")
            }

            result = RemotePythonExecutionResult(
                output: sections.joined(separator: "\n\n"),
                exitCode: execution.exitCode
            )
        } catch {
            try? await shellExecute(
                endpoint: endpoint,
                apiKey: apiKey,
                cwd: cwd,
                command: "rm -rf \(shellQuote(workspace))",
                timeout: 30
            )
            throw error
        }
        try? await shellExecute(
            endpoint: endpoint,
            apiKey: apiKey,
            cwd: cwd,
            command: "rm -rf \(shellQuote(workspace))",
            timeout: 30
        )
        return result
    }

    private func prepareBuiltInShellEnvironment(
        workspace: String,
        files: [PayloadFile],
        endpoint: String,
        apiKey: String,
        cwd: String,
        timeout: Int
    ) async throws -> String {
        let lowercasedPaths = Set(files.map { $0.path.lowercased() })
        let hasRequirements = lowercasedPaths.contains("requirements.txt")
        let hasEditableProject = lowercasedPaths.contains("pyproject.toml") || lowercasedPaths.contains("setup.py")

        var commands: [String] = [
            "set -e",
            "cd \(shellQuote(workspace))",
            "python3 -m venv .venv",
            ".venv/bin/python -m pip install --upgrade pip setuptools wheel"
        ]

        if hasRequirements {
            commands.append(".venv/bin/python -m pip install -r requirements.txt")
        } else if hasEditableProject {
            commands.append(".venv/bin/python -m pip install -e .")
        }

        let result = try await shellExecute(
            endpoint: endpoint,
            apiKey: apiKey,
            cwd: cwd,
            command: commands.joined(separator: "\n"),
            timeout: timeout
        )

        guard result.exitCode == 0 else {
            throw NSError(
                domain: "RemotePythonExecutionService",
                code: result.exitCode,
                userInfo: [NSLocalizedDescriptionKey: "内置远端 Python 环境准备失败：\(result.output)"]
            )
        }

        return result.output
    }

    private func builtInShellCommand(
        mode: RemotePythonExecutionMode,
        workspace: String,
        entryPath: String?,
        stdin: String?
    ) throws -> String {
        var commands: [String] = [
            "set -e",
            "cd \(shellQuote(workspace))"
        ]

        switch mode {
        case .runFile:
            let trimmedPath = (entryPath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPath.isEmpty else {
                throw NSError(
                    domain: "RemotePythonExecutionService",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "远端 Python 入口文件路径为空。"]
                )
            }
            if let stdin, !stdin.isEmpty {
                let delimiter = "__IEXA_STDIN_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))__"
                commands.append(".venv/bin/python \(shellQuote(trimmedPath)) <<'\(delimiter)'")
                commands.append(stdin)
                commands.append(delimiter)
            } else {
                commands.append(".venv/bin/python \(shellQuote(trimmedPath))")
            }
        case .unitTests:
            commands.append(".venv/bin/python -m unittest discover -v")
        case .compileAll:
            commands.append(".venv/bin/python -m compileall .")
        }

        return commands.joined(separator: "\n")
    }

    private func uploadFileToBuiltInShellRunner(
        _ file: PayloadFile,
        workspace: String,
        endpoint: String,
        apiKey: String,
        cwd: String
    ) async throws {
        let destination = "\(workspace)/\(file.path.replacingOccurrences(of: "\\", with: "/"))"
        let tempBase64Path = destination + ".iexa.b64"
        let parent = (destination as NSString).deletingLastPathComponent

        _ = try await shellExecute(
            endpoint: endpoint,
            apiKey: apiKey,
            cwd: cwd,
            command: """
            mkdir -p \(shellQuote(parent))
            : > \(shellQuote(tempBase64Path))
            """,
            timeout: 30
        )

        let chunks = splitIntoChunks(file.contentBase64, chunkSize: shellUploadChunkSize)
        for chunk in chunks {
            _ = try await shellExecute(
                endpoint: endpoint,
                apiKey: apiKey,
                cwd: cwd,
                command: "printf '%s' \(shellQuote(chunk)) >> \(shellQuote(tempBase64Path))",
                timeout: 30
            )
        }

        let decodeCommand = """
        set -e
        python3 - <<'PY'
        from pathlib import Path
        import base64
        src = Path(\(pythonStringLiteral(tempBase64Path)))
        dst = Path(\(pythonStringLiteral(destination)))
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_bytes(base64.b64decode(src.read_text(encoding="utf-8")))
        try:
            src.unlink()
        except FileNotFoundError:
            pass
        PY
        """

        let decodeResult = try await shellExecute(
            endpoint: endpoint,
            apiKey: apiKey,
            cwd: cwd,
            command: decodeCommand,
            timeout: 30
        )
        guard decodeResult.exitCode == 0 else {
            throw NSError(
                domain: "RemotePythonExecutionService",
                code: decodeResult.exitCode,
                userInfo: [NSLocalizedDescriptionKey: "上传远端 Python 文件失败：\(file.path)\n\(decodeResult.output)"]
            )
        }
    }

    private func shellExecute(
        endpoint: String,
        apiKey: String,
        cwd: String,
        command: String,
        timeout: Int
    ) async throws -> RemoteShellExecutionResult {
        guard let url = URL(string: endpoint) else {
            throw NSError(
                domain: "RemotePythonExecutionService",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "内置远端执行入口无效。"]
            )
        }

        var request = URLRequest(url: url, timeoutInterval: Double(max(15, timeout + 15)))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let token = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let payload: [String: Any] = [
            "command": command,
            "cwd": cwd,
            "timeout": max(5, min(timeout, 300))
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "RemotePythonExecutionService",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: "内置远端执行响应无效。"]
            )
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "RemotePythonExecutionService",
                code: 9,
                userInfo: [NSLocalizedDescriptionKey: "内置远端执行返回 JSON 无效（HTTP \(httpResponse.statusCode)）。"]
            )
        }

        if !(200...299).contains(httpResponse.statusCode) {
            let message = nestedShellErrorMessage(from: object) ?? "HTTP \(httpResponse.statusCode)"
            throw NSError(
                domain: "RemotePythonExecutionService",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "内置远端执行失败：\(message)"]
            )
        }

        let output = firstNonEmptyString(
            object["output"],
            object["stdout"],
            object["stderr"]
        ) ?? ""
        let exitCode = parseInt(object["exitCode"]) ?? parseInt(object["exit_code"]) ?? 1
        let finalCwd = firstNonEmptyString(
            object["finalCwd"],
            object["finalWorkingDirectory"],
            object["cwd"]
        )
        return RemoteShellExecutionResult(
            output: output,
            exitCode: exitCode,
            finalWorkingDirectory: finalCwd
        )
    }

    private func collectProjectFiles(from projectURL: URL) throws -> [PayloadFile] {
        guard let enumerator = fileManager.enumerator(
            at: projectURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw NSError(
                domain: "RemotePythonExecutionService",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "无法遍历项目目录。"]
            )
        }

        let root = projectURL.standardizedFileURL.path
        var totalBytes = 0
        var result: [PayloadFile] = []

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else {
                continue
            }

            let size = values.fileSize ?? 0
            if size <= 0 || size > maxSingleFileBytes {
                continue
            }

            let data = try Data(contentsOf: fileURL)
            if totalBytes + data.count > maxTotalBytes {
                break
            }

            let absolute = fileURL.standardizedFileURL.path
            let relative = absolute.hasPrefix(root + "/")
                ? String(absolute.dropFirst(root.count + 1))
                : fileURL.lastPathComponent

            result.append(
                PayloadFile(
                    path: relative,
                    contentBase64: data.base64EncodedString()
                )
            )
            totalBytes += data.count

            if result.count >= maxFiles {
                break
            }
        }

        guard !result.isEmpty else {
            throw NSError(
                domain: "RemotePythonExecutionService",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "没有可上传到远端 Python 的项目文件。"]
            )
        }

        return result
    }

    private func firstNonEmptyString(_ values: Any?...) -> String? {
        for value in values {
            if let string = value as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    private func parseInt(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let intValue = value as? Int {
            return intValue
        }
        if let string = value as? String {
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private func nestedShellErrorMessage(from object: [String: Any]) -> String? {
        if let direct = firstNonEmptyString(object["message"], object["detail"], object["output"]) {
            return direct
        }
        if let error = object["error"] as? [String: Any] {
            return firstNonEmptyString(error["message"], error["detail"])
        }
        return nil
    }

    private func splitIntoChunks(_ text: String, chunkSize: Int) -> [String] {
        guard chunkSize > 0, !text.isEmpty else { return [] }
        var result: [String] = []
        var currentIndex = text.startIndex
        while currentIndex < text.endIndex {
            let endIndex = text.index(currentIndex, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[currentIndex..<endIndex]))
            currentIndex = endIndex
        }
        return result
    }

    private func shellQuote(_ raw: String) -> String {
        "'\(raw.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private func pythonStringLiteral(_ raw: String) -> String {
        let escaped = raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
