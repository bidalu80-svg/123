import Foundation

struct ShellExecutionResult: Equatable {
    let command: String
    let output: String
    let exitCode: Int
    let durationMs: Int?
}

enum RemoteShellExecutionError: LocalizedError, Equatable {
    case emptyCommand
    case invalidURL
    case noData
    case invalidResponse(String)
    case httpError(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .emptyCommand:
            return "命令为空，无法执行。"
        case .invalidURL:
            return "终端执行接口地址无效。"
        case .noData:
            return "终端接口未返回数据。"
        case .invalidResponse(let detail):
            return "终端接口响应格式无法识别：\(detail)"
        case .httpError(let status, let message):
            if message.isEmpty {
                return "终端接口请求失败（HTTP \(status)）。"
            }
            return "终端接口请求失败（HTTP \(status)）：\(message)"
        }
    }
}

final class RemoteShellExecutionService {
    static let shared = RemoteShellExecutionService()

    private init() {}

    func run(
        command: String,
        endpoint: String,
        apiKey: String,
        workingDirectory: String?,
        timeout: TimeInterval
    ) async throws -> ShellExecutionResult {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else {
            throw RemoteShellExecutionError.emptyCommand
        }

        let endpointText = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpointText.isEmpty, let url = URL(string: endpointText) else {
            throw RemoteShellExecutionError.invalidURL
        }

        var request = URLRequest(url: url, timeoutInterval: min(max(timeout, 5), 300))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        }

        var payload: [String: Any] = [
            "command": trimmedCommand,
            "timeout": Int(min(max(timeout, 5), 300))
        ]
        if let workingDirectory {
            let cwd = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cwd.isEmpty {
                payload["cwd"] = cwd
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteShellExecutionError.invalidResponse("缺少 HTTP 响应头")
        }

        if !(200...299).contains(http.statusCode) {
            let message = parsedErrorMessage(from: data)
            throw RemoteShellExecutionError.httpError(status: http.statusCode, message: message)
        }

        guard !data.isEmpty else {
            throw RemoteShellExecutionError.noData
        }

        return try parseResult(data: data, command: trimmedCommand)
    }

    private func parseResult(data: Data, command: String) throws -> ShellExecutionResult {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return parseDictionaryResult(object, command: command)
        }

        if let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return ShellExecutionResult(command: command, output: text, exitCode: 0, durationMs: nil)
        }

        throw RemoteShellExecutionError.invalidResponse("既不是 JSON，也不是可读文本")
    }

    private func parseDictionaryResult(_ object: [String: Any], command: String) -> ShellExecutionResult {
        if let nested = object["result"] as? [String: Any] {
            return parseDictionaryResult(nested, command: command)
        }

        let stdout = firstString(
            keys: ["output", "stdout", "text", "combined_output", "combinedOutput", "logs"],
            in: object
        )
        let stderr = firstString(
            keys: ["stderr", "error", "errors"],
            in: object
        )
        let message = firstString(
            keys: ["message", "detail"],
            in: object
        )

        let exitCode = firstInt(
            keys: ["exit_code", "exitCode", "code", "status"],
            in: object
        ) ?? ((object["success"] as? Bool) == false ? 1 : 0)

        let durationMs = firstInt(
            keys: ["duration_ms", "durationMs", "elapsed_ms", "elapsedMs"],
            in: object
        ) ?? firstDouble(
            keys: ["duration", "elapsed"],
            in: object
        ).map { Int($0 * 1000) }

        let mergedOutput = mergeOutput(stdout: stdout, stderr: stderr, fallback: message)
        let normalized = mergedOutput.isEmpty ? "命令执行完成（无输出）" : mergedOutput

        return ShellExecutionResult(
            command: command,
            output: normalized,
            exitCode: exitCode,
            durationMs: durationMs
        )
    }

    private func mergeOutput(stdout: String, stderr: String, fallback: String) -> String {
        let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let fb = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty, !err.isEmpty {
            return "\(out)\n\n[stderr]\n\(err)"
        }
        if !out.isEmpty {
            return out
        }
        if !err.isEmpty {
            return err
        }
        return fb
    }

    private func parsedErrorMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let message = firstString(
                keys: ["message", "error", "detail", "reason"],
                in: object
            )
            if !message.isEmpty {
                return message
            }
        }

        if let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }
        return ""
    }

    private func firstString(keys: [String], in object: [String: Any]) -> String {
        for key in keys {
            if let value = object[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return ""
    }

    private func firstInt(keys: [String], in object: [String: Any]) -> Int? {
        for key in keys {
            if let value = object[key] as? Int {
                return value
            }
            if let value = object[key] as? Double {
                return Int(value)
            }
            if let value = object[key] as? String, let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return parsed
            }
        }
        return nil
    }

    private func firstDouble(keys: [String], in object: [String: Any]) -> Double? {
        for key in keys {
            if let value = object[key] as? Double {
                return value
            }
            if let value = object[key] as? Int {
                return Double(value)
            }
            if let value = object[key] as? String, let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return parsed
            }
        }
        return nil
    }
}
