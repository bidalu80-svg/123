import Foundation

struct RemoteTerminalHealth: Decodable {
    let ok: Bool
    let status: String?
    let runningJobs: Int?
    let queuedJobs: Int?
    let knownJobs: Int?
    let maxConcurrentJobs: Int?
    let defaultTimeoutSeconds: Int?

    private enum CodingKeys: String, CodingKey {
        case ok
        case status
        case runningJobs = "running_jobs"
        case queuedJobs = "queued_jobs"
        case knownJobs = "known_jobs"
        case maxConcurrentJobs = "max_concurrent_jobs"
        case defaultTimeoutSeconds = "default_timeout_seconds"
    }
}

struct RemoteTerminalJobSnapshot: Decodable, Identifiable {
    let id: String
    let status: String
    let command: String?
    let cwd: String?
    let createdAt: Double?
    let stdout: String
    let stderr: String
    let truncatedStdout: Bool
    let truncatedStderr: Bool
    let timedOut: Bool
    let exitCode: Int?
    let error: String?
    let durationMs: Int?

    private enum CodingKeys: String, CodingKey {
        case id
        case status
        case command
        case cwd
        case createdAt = "created_at"
        case stdout
        case stderr
        case truncatedStdout = "truncated_stdout"
        case truncatedStderr = "truncated_stderr"
        case timedOut = "timed_out"
        case exitCode = "exit_code"
        case error
        case durationMs = "duration_ms"
    }
}

enum RemoteTerminalServiceError: LocalizedError {
    case invalidBaseURL
    case requestFailed(String)
    case invalidResponse
    case serverError(String)
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "终端服务地址无效"
        case .requestFailed(let value):
            return "请求失败：\(value)"
        case .invalidResponse:
            return "终端服务返回无效响应"
        case .serverError(let value):
            return "终端服务错误：\(value)"
        case .decodeFailed:
            return "终端服务返回解析失败"
        }
    }
}

final class RemoteTerminalService {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func health(baseURL: String, token: String) async throws -> RemoteTerminalHealth {
        let url = try endpointURL(baseURL: baseURL, path: "api/terminal/health")
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "GET"
        injectAuthHeaders(token: token, into: &request)
        return try await send(request: request, decodeTo: RemoteTerminalHealth.self)
    }

    func startJob(
        baseURL: String,
        token: String,
        command: String,
        cwd: String?,
        timeoutSeconds: Int,
        maxOutputBytes: Int
    ) async throws -> String {
        let url = try endpointURL(baseURL: baseURL, path: "api/terminal/start")
        var request = URLRequest(url: url, timeoutInterval: 40)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        injectAuthHeaders(token: token, into: &request)

        let payload: [String: Any] = [
            "command": command,
            "cwd": cwd ?? "",
            "timeout_seconds": timeoutSeconds,
            "max_output_bytes": maxOutputBytes
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let response = try await send(request: request, decodeTo: StartJobResponse.self)
        guard response.ok, let jobID = response.jobID, !jobID.isEmpty else {
            throw RemoteTerminalServiceError.serverError(response.error ?? "start_failed")
        }
        return jobID
    }

    func fetchJob(baseURL: String, token: String, jobID: String) async throws -> RemoteTerminalJobSnapshot {
        let url = try endpointURL(baseURL: baseURL, path: "api/terminal/jobs/\(jobID)")
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "GET"
        injectAuthHeaders(token: token, into: &request)
        return try await send(request: request, decodeTo: RemoteTerminalJobSnapshot.self)
    }

    func cancelJob(baseURL: String, token: String, jobID: String) async throws {
        let url = try endpointURL(baseURL: baseURL, path: "api/terminal/jobs/\(jobID)/cancel")
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        injectAuthHeaders(token: token, into: &request)
        request.httpBody = Data("{}".utf8)
        _ = try await send(request: request, decodeTo: GenericResponse.self)
    }

    private func endpointURL(baseURL raw: String, path: String) throws -> URL {
        var normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            throw RemoteTerminalServiceError.invalidBaseURL
        }
        if !normalized.hasPrefix("http://") && !normalized.hasPrefix("https://") {
            normalized = "http://\(normalized)"
        }
        guard var url = URL(string: normalized) else {
            throw RemoteTerminalServiceError.invalidBaseURL
        }
        for segment in path.split(separator: "/") {
            url.appendPathComponent(String(segment))
        }
        return url
    }

    private func injectAuthHeaders(token raw: String, into request: inout URLRequest) {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        request.setValue(token, forHTTPHeaderField: "X-Terminal-Token")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    private func send<T: Decodable>(request: URLRequest, decodeTo type: T.Type) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RemoteTerminalServiceError.requestFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw RemoteTerminalServiceError.invalidResponse
        }

        if !(200...299).contains(http.statusCode) {
            if let generic = try? JSONDecoder().decode(GenericResponse.self, from: data),
               let error = generic.error, !error.isEmpty {
                throw RemoteTerminalServiceError.serverError(error)
            }
            throw RemoteTerminalServiceError.serverError("HTTP \(http.statusCode)")
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw RemoteTerminalServiceError.decodeFailed
        }
    }

    private struct StartJobResponse: Decodable {
        let ok: Bool
        let jobID: String?
        let error: String?

        private enum CodingKeys: String, CodingKey {
            case ok
            case jobID = "job_id"
            case error
        }
    }

    private struct GenericResponse: Decodable {
        let ok: Bool?
        let error: String?
    }
}

