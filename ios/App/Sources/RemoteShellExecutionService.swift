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
            let message = parsedErrorMessage(
                from: data,
                endpoint: endpointText,
                status: http.statusCode
            )
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

    private func parsedErrorMessage(from data: Data, endpoint: String, status: Int) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let errorObject = object["error"] as? [String: Any] {
                let nestedMessage = firstString(
                    keys: ["message", "detail", "reason", "error_description"],
                    in: errorObject
                )
                if !nestedMessage.isEmpty {
                    return clipErrorMessage(nestedMessage)
                }
            }
            let message = firstString(
                keys: ["message", "error", "detail", "reason"],
                in: object
            )
            if !message.isEmpty {
                return clipErrorMessage(message)
            }
        }

        if let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            if looksLikeHTMLResponse(text) {
                return buildNotFoundGuidance(endpoint: endpoint, status: status)
            }
            return clipErrorMessage(text)
        }
        if status == 404 {
            return buildNotFoundGuidance(endpoint: endpoint, status: status)
        }
        return ""
    }

    private func buildNotFoundGuidance(endpoint: String, status: Int) -> String {
        if status != 404 {
            return "接口请求失败（HTTP \(status)）。"
        }
        return "终端接口返回 404，当前地址为 \(endpoint)。请在设置中把“终端执行接口”改成你服务器真实可用的 shell 路由（例如 http://<server-ip>:8787/v1/shell/execute）。"
    }

    private func looksLikeHTMLResponse(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("<!doctype html")
            || lowered.contains("<html")
            || lowered.contains("<head")
            || lowered.contains("<body")
    }

    private func clipErrorMessage(_ text: String, limit: Int = 360) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
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
