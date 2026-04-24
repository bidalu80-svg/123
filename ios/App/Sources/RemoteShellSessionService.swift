import Foundation

struct RemoteShellSessionSnapshot: Equatable {
    let sessionID: String
    let output: String
    let workingDirectory: String
    let isRunning: Bool
    let exitCode: Int?
    let shellName: String
}

struct RemoteShellCapabilities: Equatable {
    struct ShellEntry: Equatable {
        let name: String
        let path: String
    }

    struct RuntimeEntry: Equatable {
        let runtime: String
        let command: String
        let path: String
    }

    let rootDirectory: String
    let defaultShell: String
    let shells: [ShellEntry]
    let runtimes: [RuntimeEntry]
}

enum RemoteShellSessionError: LocalizedError, Equatable {
    case invalidURL
    case invalidResponse(String)
    case httpError(status: Int, message: String)
    case missingSessionID

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "终端会话接口地址无效。"
        case .invalidResponse(let detail):
            return "终端会话响应格式无法识别：\(detail)"
        case .httpError(let status, let message):
            if message.isEmpty {
                return "终端会话请求失败（HTTP \(status)）。"
            }
            return "终端会话请求失败（HTTP \(status)）：\(message)"
        case .missingSessionID:
            return "终端会话缺少 sessionId。"
        }
    }
}

final class RemoteShellSessionService {
    static let shared = RemoteShellSessionService()

    private init() {}

    func startSession(
        endpoint: String,
        apiKey: String,
        workingDirectory: String?,
        shell: String? = nil
    ) async throws -> RemoteShellSessionSnapshot {
        var payload: [String: Any] = [:]
        if let workingDirectory {
            let trimmed = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                payload["cwd"] = trimmed
            }
        }
        if let shell {
            let trimmed = shell.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                payload["shell"] = trimmed
            }
        }
        return try await performPOST(
            endpoint: endpoint,
            apiKey: apiKey,
            routeCandidates: sessionEndpointCandidates(from: endpoint, suffixes: [
                "/v1/shell/session/start",
                "/shell/session/start"
            ]),
            payload: payload
        )
    }

    func sendInput(
        sessionID: String,
        input: String,
        endpoint: String,
        apiKey: String,
        appendNewline: Bool = true
    ) async throws -> RemoteShellSessionSnapshot {
        try await performPOST(
            endpoint: endpoint,
            apiKey: apiKey,
            routeCandidates: sessionEndpointCandidates(from: endpoint, suffixes: [
                "/v1/shell/session/input",
                "/shell/session/input"
            ]),
            payload: [
                "sessionId": sessionID,
                "input": input,
                "appendNewline": appendNewline
            ]
        )
    }

    func fetchCapabilities(
        endpoint: String,
        apiKey: String
    ) async throws -> RemoteShellCapabilities {
        let candidates = sessionEndpointCandidates(from: endpoint, suffixes: [
            "/v1/shell/capabilities",
            "/shell/capabilities"
        ])
        guard !candidates.isEmpty else {
            throw RemoteShellSessionError.invalidURL
        }

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var lastError: Error?

        for candidate in candidates {
            var request = URLRequest(url: candidate, timeoutInterval: 30)
            request.httpMethod = "GET"
            if !trimmedKey.isEmpty {
                request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
            }

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                return try parseCapabilities(data: data, response: response)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? RemoteShellSessionError.invalidURL
    }

    func sendSignal(
        sessionID: String,
        signal: String,
        endpoint: String,
        apiKey: String
    ) async throws -> RemoteShellSessionSnapshot {
        try await performPOST(
            endpoint: endpoint,
            apiKey: apiKey,
            routeCandidates: sessionEndpointCandidates(from: endpoint, suffixes: [
                "/v1/shell/session/signal",
                "/shell/session/signal"
            ]),
            payload: [
                "sessionId": sessionID,
                "signal": signal
            ]
        )
    }

    func pollSession(
        sessionID: String,
        endpoint: String,
        apiKey: String
    ) async throws -> RemoteShellSessionSnapshot {
        let candidates = sessionEndpointCandidates(from: endpoint, suffixes: [
            "/v1/shell/session/poll",
            "/shell/session/poll"
        ]).compactMap { url -> URL? in
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return url
            }
            var queryItems = components.queryItems ?? []
            queryItems.removeAll { $0.name.lowercased() == "sessionid" }
            queryItems.append(URLQueryItem(name: "sessionId", value: sessionID))
            components.queryItems = queryItems
            return components.url
        }
        return try await performGET(apiKey: apiKey, candidates: candidates)
    }

    func stopSession(
        sessionID: String,
        endpoint: String,
        apiKey: String
    ) async throws -> RemoteShellSessionSnapshot {
        try await performPOST(
            endpoint: endpoint,
            apiKey: apiKey,
            routeCandidates: sessionEndpointCandidates(from: endpoint, suffixes: [
                "/v1/shell/session/stop",
                "/shell/session/stop"
            ]),
            payload: [
                "sessionId": sessionID
            ]
        )
    }

    private func performPOST(
        endpoint: String,
        apiKey: String,
        routeCandidates: [URL],
        payload: [String: Any]
    ) async throws -> RemoteShellSessionSnapshot {
        guard !routeCandidates.isEmpty else {
            throw RemoteShellSessionError.invalidURL
        }

        let requestBody = try JSONSerialization.data(withJSONObject: payload)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        var lastError: Error?
        for candidate in routeCandidates {
            var request = URLRequest(url: candidate, timeoutInterval: 60)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !trimmedKey.isEmpty {
                request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = requestBody

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                return try parseSnapshot(data: data, response: response)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? RemoteShellSessionError.invalidURL
    }

    private func performGET(
        apiKey: String,
        candidates: [URL]
    ) async throws -> RemoteShellSessionSnapshot {
        guard !candidates.isEmpty else {
            throw RemoteShellSessionError.invalidURL
        }

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var lastError: Error?

        for candidate in candidates {
            var request = URLRequest(url: candidate, timeoutInterval: 60)
            request.httpMethod = "GET"
            if !trimmedKey.isEmpty {
                request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
            }

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                return try parseSnapshot(data: data, response: response)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? RemoteShellSessionError.invalidURL
    }

    private func parseSnapshot(data: Data, response: URLResponse) throws -> RemoteShellSessionSnapshot {
        guard let http = response as? HTTPURLResponse else {
            throw RemoteShellSessionError.invalidResponse("缺少 HTTP 响应头")
        }

        guard (200...299).contains(http.statusCode) else {
            let message = parsedErrorMessage(from: data)
            throw RemoteShellSessionError.httpError(status: http.statusCode, message: message)
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RemoteShellSessionError.invalidResponse("响应不是 JSON")
        }

        let sessionID = firstString(keys: ["sessionId", "session_id", "id"], in: object)
        guard !sessionID.isEmpty else {
            throw RemoteShellSessionError.missingSessionID
        }

        let output = firstString(keys: ["output", "stdout", "text"], in: object)
        let workingDirectory = firstString(keys: ["cwd", "workingDirectory", "working_directory", "finalCwd"], in: object)
        let isRunning = firstBool(keys: ["isRunning", "running", "is_running"], in: object) ?? true
        let exitCode = firstInt(keys: ["exitCode", "exit_code", "code", "status"], in: object)
        let shellName = firstString(keys: ["shell", "shellName", "shell_name"], in: object)

        return RemoteShellSessionSnapshot(
            sessionID: sessionID,
            output: output,
            workingDirectory: workingDirectory,
            isRunning: isRunning,
            exitCode: exitCode,
            shellName: shellName
        )
    }

    private func parseCapabilities(data: Data, response: URLResponse) throws -> RemoteShellCapabilities {
        guard let http = response as? HTTPURLResponse else {
            throw RemoteShellSessionError.invalidResponse("缺少 HTTP 响应头")
        }

        guard (200...299).contains(http.statusCode) else {
            let message = parsedErrorMessage(from: data)
            throw RemoteShellSessionError.httpError(status: http.statusCode, message: message)
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RemoteShellSessionError.invalidResponse("能力响应不是 JSON")
        }

        let rootDirectory = firstString(keys: ["rootDir", "root_dir"], in: object)
        let defaultShell = firstString(keys: ["defaultShell", "default_shell"], in: object)

        let shells: [RemoteShellCapabilities.ShellEntry] = (object["shells"] as? [[String: Any]] ?? []).compactMap { item in
            let name = firstString(keys: ["name"], in: item)
            let path = firstString(keys: ["path"], in: item)
            guard !name.isEmpty, !path.isEmpty else { return nil }
            return .init(name: name, path: path)
        }

        let runtimesDict = object["runtimes"] as? [String: [String: Any]] ?? [:]
        let runtimes = runtimesDict.keys.sorted().compactMap { key -> RemoteShellCapabilities.RuntimeEntry? in
            guard let item = runtimesDict[key] else { return nil }
            let command = firstString(keys: ["command"], in: item)
            let path = firstString(keys: ["path"], in: item)
            guard !command.isEmpty, !path.isEmpty else { return nil }
            return .init(runtime: key, command: command, path: path)
        }

        return RemoteShellCapabilities(
            rootDirectory: rootDirectory,
            defaultShell: defaultShell,
            shells: shells,
            runtimes: runtimes
        )
    }

    private func sessionEndpointCandidates(from endpoint: String, suffixes: [String]) -> [URL] {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let baseURL = URL(string: trimmed) else {
            return []
        }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return [baseURL]
        }

        let currentPath = components.percentEncodedPath
        let inferredBasePath: String = {
            if currentPath.hasSuffix("/v1/shell/execute") {
                return String(currentPath.dropLast("/execute".count))
            }
            if currentPath.hasSuffix("/shell/execute") {
                return String(currentPath.dropLast("/execute".count))
            }
            return ""
        }()

        var candidates: [URL] = []
        func appendCandidate(_ url: URL?) {
            guard let url else { return }
            if !candidates.contains(url) {
                candidates.append(url)
            }
        }

        for suffix in suffixes {
            var updated = components
            if !inferredBasePath.isEmpty,
               suffix.hasPrefix("/v1/shell/"),
               inferredBasePath.hasPrefix("/v1/shell") {
                updated.percentEncodedPath = suffix
            } else if !inferredBasePath.isEmpty,
                      suffix.hasPrefix("/shell/"),
                      inferredBasePath.hasPrefix("/shell") {
                updated.percentEncodedPath = suffix
            } else {
                updated.percentEncodedPath = suffix
            }
            appendCandidate(updated.url)
        }

        return candidates
    }

    private func parsedErrorMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let errorObject = object["error"] as? [String: Any] {
                let nested = firstString(keys: ["message", "detail", "reason"], in: errorObject)
                if !nested.isEmpty {
                    return nested
                }
            }
            let message = firstString(keys: ["message", "error", "detail", "reason"], in: object)
            if !message.isEmpty {
                return message
            }
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
            if let value = object[key] as? String,
               let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return parsed
            }
        }
        return nil
    }

    private func firstBool(keys: [String], in object: [String: Any]) -> Bool? {
        for key in keys {
            if let value = object[key] as? Bool {
                return value
            }
            if let value = object[key] as? String {
                let lowered = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if lowered == "true" {
                    return true
                }
                if lowered == "false" {
                    return false
                }
            }
        }
        return nil
    }
}
