import Foundation

struct ShellExecutionResult: Equatable {
    let command: String
    let output: String
    let exitCode: Int
    let durationMs: Int?
    let finalWorkingDirectory: String?
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
    private let finalWorkingDirectoryMarker = "__IEXA_FINAL_CWD__="

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
        let endpointCandidates = shellEndpointCandidates(from: endpointText)
        guard !endpointCandidates.isEmpty else {
            throw RemoteShellExecutionError.invalidURL
        }

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestTimeout = min(max(timeout, 5), 300)
        let wrappedCommand = wrappedCommandForWorkingDirectory(trimmedCommand)
        var payload: [String: Any] = [
            "command": wrappedCommand,
            "timeout": Int(requestTimeout)
        ]
        if let workingDirectory {
            let cwd = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cwd.isEmpty {
                payload["cwd"] = cwd
            }
        }
        let requestBody = try JSONSerialization.data(withJSONObject: payload)

        var notFoundEndpoints: [String] = []
        var lastTransportError: Error?

        for (index, candidateURL) in endpointCandidates.enumerated() {
            var request = URLRequest(url: candidateURL, timeoutInterval: requestTimeout)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !trimmedKey.isEmpty {
                request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = requestBody

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw RemoteShellExecutionError.invalidResponse("缺少 HTTP 响应头")
                }

                if (200...299).contains(http.statusCode) {
                    guard !data.isEmpty else {
                        throw RemoteShellExecutionError.noData
                    }
                    return try parseResult(data: data, command: trimmedCommand)
                }

                let candidateEndpoint = candidateURL.absoluteString
                let message = parsedErrorMessage(
                    from: data,
                    endpoint: candidateEndpoint,
                    status: http.statusCode
                )

                if http.statusCode == 404 {
                    notFoundEndpoints.append(candidateEndpoint)
                    if index < endpointCandidates.count - 1 {
                        continue
                    }
                    let fallbackMessage = mergedNotFoundMessage(
                        parsedMessage: message,
                        attemptedEndpoints: notFoundEndpoints
                    )
                    throw RemoteShellExecutionError.httpError(status: 404, message: fallbackMessage)
                }

                throw RemoteShellExecutionError.httpError(status: http.statusCode, message: message)
            } catch let error as RemoteShellExecutionError {
                throw error
            } catch {
                lastTransportError = error
                if shouldTryNextEndpoint(after: error), index < endpointCandidates.count - 1 {
                    continue
                }
                throw error
            }
        }

        if !notFoundEndpoints.isEmpty {
            throw RemoteShellExecutionError.httpError(
                status: 404,
                message: mergedNotFoundMessage(parsedMessage: "", attemptedEndpoints: notFoundEndpoints)
            )
        }

        if let lastTransportError {
            throw lastTransportError
        }

        throw RemoteShellExecutionError.invalidURL
    }

    private func parseResult(data: Data, command: String) throws -> ShellExecutionResult {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return parseDictionaryResult(object, command: command)
        }

        if let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            let (cleanedOutput, finalWorkingDirectory) = extractFinalWorkingDirectory(from: text)
            return ShellExecutionResult(
                command: command,
                output: cleanedOutput,
                exitCode: 0,
                durationMs: nil,
                finalWorkingDirectory: finalWorkingDirectory
            )
        }

        throw RemoteShellExecutionError.invalidResponse("既不是 JSON，也不是可读文本")
    }

    private func parseDictionaryResult(_ object: [String: Any], command: String) -> ShellExecutionResult {
        if let nested = object["result"] as? [String: Any] {
            return parseDictionaryResult(nested, command: command)
        }

        let stdoutRaw = firstString(
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

        let parsedFinalWorkingDirectory = firstString(
            keys: ["finalCwd", "final_cwd", "pwd", "workingDirectory", "working_directory"],
            in: object
        )
        let (stdout, derivedFinalWorkingDirectory) = extractFinalWorkingDirectory(from: stdoutRaw)
        let mergedOutput = mergeOutput(stdout: stdout, stderr: stderr, fallback: message)
        let normalized = mergedOutput.isEmpty ? "命令执行完成（无输出）" : mergedOutput

        return ShellExecutionResult(
            command: command,
            output: normalized,
            exitCode: exitCode,
            durationMs: durationMs,
            finalWorkingDirectory: parsedFinalWorkingDirectory.isEmpty ? derivedFinalWorkingDirectory : parsedFinalWorkingDirectory
        )
    }

    private func wrappedCommandForWorkingDirectory(_ command: String) -> String {
        """
        \(command)
        __iexa_status=$?
        printf '\\n\(finalWorkingDirectoryMarker)%s\\n' "$PWD"
        exit $__iexa_status
        """
    }

    private func extractFinalWorkingDirectory(from output: String) -> (String, String?) {
        guard output.contains(finalWorkingDirectoryMarker) else {
            return (output, nil)
        }

        let lines = output.components(separatedBy: .newlines)
        var cleanedLines: [String] = []
        var finalWorkingDirectory: String?

        for line in lines {
            if line.hasPrefix(finalWorkingDirectoryMarker) {
                let path = String(line.dropFirst(finalWorkingDirectoryMarker.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty {
                    finalWorkingDirectory = path
                }
                continue
            }
            cleanedLines.append(line)
        }

        var cleanedOutput = cleanedLines.joined(separator: "\n")
        while cleanedOutput.contains("\n\n\n") {
            cleanedOutput = cleanedOutput.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return (cleanedOutput.trimmingCharacters(in: .whitespacesAndNewlines), finalWorkingDirectory)
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

    private func shellEndpointCandidates(from endpoint: String) -> [URL] {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let baseURL = URL(string: trimmed) else {
            return []
        }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return [baseURL]
        }

        let preferredPath: String = {
            let path = components.percentEncodedPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if path.isEmpty { return "/v1/shell/execute" }
            return path.hasPrefix("/") ? path : "/\(path)"
        }()
        let shellPaths = uniqueStrings([
            preferredPath,
            "/v1/shell/execute",
            "/shell/execute"
        ])

        var candidates: [URL] = []

        func appendCandidate(_ value: URL?) {
            guard let value else { return }
            guard !candidates.contains(value) else { return }
            candidates.append(value)
        }

        appendCandidate(baseURL)

        for path in shellPaths {
            var pathComponents = components
            pathComponents.percentEncodedPath = path
            appendCandidate(pathComponents.url)
        }

        if components.port != 8787 {
            for path in shellPaths {
                var portComponents = components
                portComponents.port = 8787
                portComponents.percentEncodedPath = path
                appendCandidate(portComponents.url)
            }
        }

        if components.scheme?.lowercased() == "https" {
            for path in shellPaths {
                var httpComponents = components
                httpComponents.scheme = "http"
                httpComponents.port = 8787
                httpComponents.percentEncodedPath = path
                appendCandidate(httpComponents.url)
            }
        }

        return candidates
    }

    private func shouldTryNextEndpoint(after error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .badURL,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .networkConnectionLost,
             .notConnectedToInternet,
             .secureConnectionFailed,
             .serverCertificateUntrusted,
             .timedOut:
            return true
        default:
            return false
        }
    }

    private func mergedNotFoundMessage(parsedMessage: String, attemptedEndpoints: [String]) -> String {
        if !parsedMessage.isEmpty,
           !parsedMessage.contains("终端接口返回 404"),
           !parsedMessage.contains("Not Found") {
            return parsedMessage
        }

        let tried = uniqueStrings(attemptedEndpoints)
        let topTried = tried.prefix(4).joined(separator: "\n")
        if topTried.isEmpty {
            return "终端接口返回 404。请在设置中把“终端执行接口”改成你服务器真实可用的 shell 路由（例如 http://<server-ip>:8787/v1/shell/execute）。"
        }
        return """
        终端接口返回 404，已自动尝试以下地址但仍不可用：
        \(topTried)

        请在服务器启动 shell_execute_server.py，并把“终端执行接口”改成 http://<server-ip>:8787/v1/shell/execute。
        """
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

    private func uniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
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
