#!/usr/bin/env swift
import Foundation

struct CLIOptions {
    var apiURL: String = ProcessInfo.processInfo.environment["CHAT_API_URL"] ?? ""
    var apiKey: String = ProcessInfo.processInfo.environment["CHAT_API_KEY"] ?? ""
    var model: String = ProcessInfo.processInfo.environment["CHAT_MODEL"] ?? "gpt-5.4-pro"
    var stream: Bool = true
    var agentMode: String = "none"
    var prompt: String = ""
    var interactive: Bool = false
    var webOutputDir: String?
    var openWebAfterWrite: Bool = false
}

struct APIMessage {
    let role: String
    let content: String

    var jsonObject: [String: Any] {
        ["role": role, "content": content]
    }
}

enum CLIError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case invalidURL
    case network(String)
    case noData

    var description: String {
        switch self {
        case .invalidArguments(let value):
            return "参数错误: \(value)"
        case .invalidURL:
            return "API URL 无效，请传入 --api-url"
        case .network(let value):
            return "网络错误: \(value)"
        case .noData:
            return "服务端未返回有效数据"
        }
    }
}

@main
struct TerminalAgentCLI {
    static func main() async {
        do {
            var options = try parseArguments(Array(CommandLine.arguments.dropFirst()))
            if options.interactive || options.prompt.isEmpty {
                try await runInteractive(options: &options)
            } else {
                try await runSingle(options: options, prompt: options.prompt)
            }
        } catch {
            fputs("\(error)\n\n", stderr)
            printUsage()
            Foundation.exit(1)
        }
    }

    private static func parseArguments(_ args: [String]) throws -> CLIOptions {
        var options = CLIOptions()
        var index = 0
        var freeText: [String] = []

        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--api-url":
                index += 1
                guard index < args.count else { throw CLIError.invalidArguments("--api-url 缺少值") }
                options.apiURL = args[index]
            case "--api-key":
                index += 1
                guard index < args.count else { throw CLIError.invalidArguments("--api-key 缺少值") }
                options.apiKey = args[index]
            case "--model":
                index += 1
                guard index < args.count else { throw CLIError.invalidArguments("--model 缺少值") }
                options.model = args[index]
            case "--agent":
                index += 1
                guard index < args.count else { throw CLIError.invalidArguments("--agent 缺少值") }
                options.agentMode = args[index].lowercased()
            case "--stream":
                options.stream = true
            case "--no-stream":
                options.stream = false
            case "--interactive":
                options.interactive = true
            case "--prompt":
                index += 1
                guard index < args.count else { throw CLIError.invalidArguments("--prompt 缺少值") }
                options.prompt = args[index]
            case "--web-out":
                index += 1
                guard index < args.count else { throw CLIError.invalidArguments("--web-out 缺少值") }
                options.webOutputDir = args[index]
            case "--open":
                options.openWebAfterWrite = true
            case "--help", "-h":
                printUsage()
                Foundation.exit(0)
            default:
                freeText.append(arg)
            }
            index += 1
        }

        if options.prompt.isEmpty, !freeText.isEmpty {
            options.prompt = freeText.joined(separator: " ")
        }
        return options
    }

    private static func runInteractive(options: inout CLIOptions) async throws {
        print("Terminal Agent 已启动。输入 exit 退出。")
        while true {
            print("\n> ", terminator: "")
            fflush(stdout)
            guard let line = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) else { break }
            if line.lowercased() == "exit" || line.lowercased() == "quit" { break }
            if line.isEmpty { continue }
            try await runSingle(options: options, prompt: line)
        }
    }

    private static func runSingle(options: CLIOptions, prompt: String) async throws {
        let completionURL = normalizeCompletionURL(options.apiURL)
        guard let url = URL(string: completionURL), !completionURL.isEmpty else {
            throw CLIError.invalidURL
        }

        var messages = [APIMessage(role: "user", content: prompt)]
        if let systemPrompt = agentSystemPrompt(mode: options.agentMode) {
            messages.insert(APIMessage(role: "system", content: systemPrompt), at: 0)
        }

        let payload: [String: Any] = [
            "model": options.model,
            "stream": options.stream,
            "messages": messages.map(\.jsonObject)
        ]

        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !options.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(options.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        if options.stream {
            let text = try await sendStreaming(request)
            print("\n\n\(text)\n")
            try handleWebAgentOutputIfNeeded(mode: options.agentMode, reply: text, outputDir: options.webOutputDir, openAfterWrite: options.openWebAfterWrite)
        } else {
            let text = try await sendNonStreaming(request)
            print("\n\(text)\n")
            try handleWebAgentOutputIfNeeded(mode: options.agentMode, reply: text, outputDir: options.webOutputDir, openAfterWrite: options.openWebAfterWrite)
        }
    }

    private static func sendStreaming(_ request: URLRequest) async throws -> String {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw CLIError.network("无效响应") }
        guard (200...299).contains(http.statusCode) else { throw CLIError.network("HTTP \(http.statusCode)") }

        var full = ""
        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let payloadLine: String
            if trimmed.hasPrefix("data:") {
                payloadLine = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                payloadLine = trimmed
            }
            if payloadLine == "[DONE]" { break }
            guard let data = payloadLine.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let piece = extractText(from: obj)
            if !piece.isEmpty {
                print(piece, terminator: "")
                fflush(stdout)
                full += piece
            }
        }
        if full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CLIError.noData
        }
        return full
    }

    private static func sendNonStreaming(_ request: URLRequest) async throws -> String {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CLIError.network("无效响应") }
        guard (200...299).contains(http.statusCode) else { throw CLIError.network("HTTP \(http.statusCode)") }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CLIError.noData }
        let text = extractText(from: obj)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw CLIError.noData }
        return text
    }

    private static func extractText(from object: [String: Any]) -> String {
        var result = ""
        if let choices = object["choices"] as? [[String: Any]] {
            for choice in choices {
                if let delta = choice["delta"] as? [String: Any], let content = delta["content"] as? String {
                    result += content
                }
                if let message = choice["message"] as? [String: Any], let content = message["content"] as? String {
                    result += content
                }
                if let text = choice["text"] as? String {
                    result += text
                }
            }
        }
        if let text = object["text"] as? String {
            result += text
        }
        return result
    }

    private static func normalizeCompletionURL(_ rawURL: String) -> String {
        var base = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { return "" }
        if !base.hasPrefix("http://") && !base.hasPrefix("https://") {
            base = "https://\(base)"
        }
        let endings = ["/v1/chat/completions", "/v1/models"]
        for ending in endings where base.lowercased().hasSuffix(ending) {
            base = String(base.dropLast(ending.count))
            break
        }
        base = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(base)/v1/chat/completions"
    }

    private static func agentSystemPrompt(mode: String) -> String? {
        switch mode {
        case "none", "":
            return nil
        case "code":
            return """
            你是代码执行助手。给出可直接运行的命令和代码，优先标准库方案，不依赖外部包。
            """
        case "web":
            return """
            你是 Web 构建代理。请输出可直接运行的静态网站文件，并严格使用以下格式：
            [[file:index.html]]
            ...文件内容...
            [[endfile]]
            [[file:styles.css]]
            ...文件内容...
            [[endfile]]
            最后给出“运行说明”，必须使用零依赖方式（直接打开 index.html）。
            """
        default:
            return "你是终端 AI 代理，请给出可执行结果。"
        }
    }

    private static func handleWebAgentOutputIfNeeded(
        mode: String,
        reply: String,
        outputDir: String?,
        openAfterWrite: Bool
    ) throws {
        guard mode == "web", let outputDir, !outputDir.isEmpty else { return }
        let files = parseWebFiles(reply)
        guard !files.isEmpty else {
            print("未识别到 [[file:...]] 输出，跳过写入。")
            return
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        for item in files {
            let cleanPath = item.path.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanPath.isEmpty else { continue }
            let finalPath = (outputDir as NSString).appendingPathComponent(cleanPath)
            let parent = (finalPath as NSString).deletingLastPathComponent
            try fileManager.createDirectory(atPath: parent, withIntermediateDirectories: true)
            try item.content.write(toFile: finalPath, atomically: true, encoding: .utf8)
            print("已写入: \(finalPath)")
        }

        let indexPath = (outputDir as NSString).appendingPathComponent("index.html")
        print("网页输出目录: \(outputDir)")
        print("可直接打开预览: \(indexPath)")

        if openAfterWrite {
            #if os(macOS)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [indexPath]
            try? process.run()
            #endif
        }
    }

    private static func parseWebFiles(_ text: String) -> [(path: String, content: String)] {
        let pattern = #"\[\[file:(.+?)\]\]([\s\S]*?)\[\[endfile\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            guard let pathRange = Range(match.range(at: 1), in: text),
                  let contentRange = Range(match.range(at: 2), in: text) else { return nil }
            let path = String(text[pathRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let content = String(text[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
            return (path: path, content: content)
        }
    }

    private static func printUsage() {
        let usage = """
        用法:
          swift ios/Tools/terminal_agent.swift --api-url https://xxx.com --api-key sk-xxx --prompt "你好"
          swift ios/Tools/terminal_agent.swift --api-url https://xxx.com --agent web --web-out ./web --prompt "做一个登录页"
          swift ios/Tools/terminal_agent.swift --api-url https://xxx.com --interactive

        参数:
          --api-url <url>       API 基地址或 completions 地址
          --api-key <key>       API Key（可选）
          --model <name>        模型名，默认 gpt-5.4-pro
          --agent <mode>        none | code | web
          --stream              开启流式（默认）
          --no-stream           关闭流式
          --prompt <text>       单次请求内容
          --interactive         交互模式
          --web-out <dir>       web 模式下把文件写到目录
          --open                web 模式写文件后自动打开 index.html（macOS）
        """
        print(usage)
    }
}
