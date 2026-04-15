import Foundation

enum AuthServiceError: LocalizedError {
    case invalidBaseURL
    case invalidAccount
    case weakPassword
    case invalidResponse
    case http(status: Int, message: String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "认证服务地址无效。"
        case .invalidAccount:
            return "账号格式无效。"
        case .weakPassword:
            return "密码至少需要 6 位。"
        case .invalidResponse:
            return "认证服务返回了无法识别的响应。"
        case .http(let status, let message):
            if message.isEmpty {
                return "认证请求失败（HTTP \(status)）。"
            }
            return "认证请求失败（HTTP \(status)）：\(message)"
        case .server(let message):
            return message
        }
    }
}

final class AuthService {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
            return
        }
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    func register(baseURL: String, account: String, password: String) async throws -> AuthSession {
        let normalizedAccount = Self.normalizedAccount(account)
        guard Self.isAccountValid(normalizedAccount) else {
            throw AuthServiceError.invalidAccount
        }
        guard Self.isPasswordValid(password) else {
            throw AuthServiceError.weakPassword
        }

        let payload: [String: Any] = [
            "phone": normalizedAccount,
            "password": password
        ]
        let object = try await sendRequest(
            baseURL: baseURL,
            path: "/auth/register",
            method: "POST",
            body: payload,
            bearerToken: nil,
            extraHeaders: [
                "X-Device-Install-ID": DeviceInstallIdentity.currentID()
            ]
        )
        guard let session = parseSession(from: object) else {
            throw AuthServiceError.invalidResponse
        }
        return session
    }

    func login(baseURL: String, account: String, password: String) async throws -> AuthSession {
        let normalizedAccount = Self.normalizedAccount(account)
        guard Self.isAccountValid(normalizedAccount) else {
            throw AuthServiceError.invalidAccount
        }
        guard Self.isPasswordValid(password) else {
            throw AuthServiceError.weakPassword
        }

        let payload: [String: Any] = [
            "phone": normalizedAccount,
            "password": password
        ]
        let object = try await sendRequest(
            baseURL: baseURL,
            path: "/auth/login",
            method: "POST",
            body: payload,
            bearerToken: nil,
            extraHeaders: [
                "X-Device-Install-ID": DeviceInstallIdentity.currentID()
            ]
        )
        guard let session = parseSession(from: object) else {
            throw AuthServiceError.invalidResponse
        }
        return session
    }

    func logout(baseURL: String, token: String) async {
        _ = try? await sendRequest(
            baseURL: baseURL,
            path: "/auth/logout",
            method: "POST",
            body: [:],
            bearerToken: token
        )
    }

    func loginWithGoogle(baseURL: String, idToken: String) async throws -> AuthSession {
        let token = idToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw AuthServiceError.server("Google 登录凭证为空。")
        }

        let payload: [String: Any] = [
            "idToken": token
        ]

        let object = try await sendRequest(
            baseURL: baseURL,
            path: "/auth/google",
            method: "POST",
            body: payload,
            bearerToken: nil,
            extraHeaders: [
                "X-Device-Install-ID": DeviceInstallIdentity.currentID()
            ]
        )
        guard let session = parseSession(from: object) else {
            throw AuthServiceError.invalidResponse
        }
        return session
    }

    func loginWithApple(baseURL: String, idToken: String) async throws -> AuthSession {
        let token = idToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw AuthServiceError.server("Apple 登录凭证为空。")
        }

        let payload: [String: Any] = [
            "idToken": token
        ]

        let object = try await sendRequest(
            baseURL: baseURL,
            path: "/auth/apple",
            method: "POST",
            body: payload,
            bearerToken: nil,
            extraHeaders: [
                "X-Device-Install-ID": DeviceInstallIdentity.currentID()
            ]
        )
        guard let session = parseSession(from: object) else {
            throw AuthServiceError.invalidResponse
        }
        return session
    }

    static func normalizedAccount(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isAccountValid(_ raw: String) -> Bool {
        let pattern = #"^[A-Za-z0-9_.+\-@]{2,64}$"#
        return raw.range(of: pattern, options: .regularExpression) != nil
    }

    static func isPasswordValid(_ raw: String) -> Bool {
        raw.count >= 6 && raw.count <= 64
    }

    private func sendRequest(
        baseURL: String,
        path: String,
        method: String,
        body: [String: Any],
        bearerToken: String?,
        extraHeaders: [String: String] = [:]
    ) async throws -> [String: Any] {
        let normalized = AuthSessionStore.normalizedBaseURL(baseURL)
        guard !normalized.isEmpty, let url = URL(string: normalized + path) else {
            throw AuthServiceError.invalidBaseURL
        }

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearerToken, !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        for (header, value) in extraHeaders where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue(value, forHTTPHeaderField: header)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthServiceError.invalidResponse
        }

        let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if (200...299).contains(http.statusCode) {
            if let ok = object["ok"] as? Bool, !ok {
                let message = (object["message"] as? String) ?? "认证服务返回失败。"
                throw AuthServiceError.server(message)
            }
            return object
        }

        let message = (object["message"] as? String) ?? String(data: data, encoding: .utf8) ?? ""
        throw AuthServiceError.http(status: http.statusCode, message: message)
    }

    private func parseSession(from object: [String: Any]) -> AuthSession? {
        let payload: [String: Any]
        if let data = object["data"] as? [String: Any] {
            payload = data
        } else {
            payload = object
        }

        guard let token = payload["token"] as? String, !token.isEmpty else {
            return nil
        }

        let expiresAt = Self.parseDate(payload["expiresAt"]) ?? Self.parseDate(payload["expires_at"])
        guard let userObject = payload["user"] as? [String: Any],
              let userID = userObject["id"] as? String,
              let phone = userObject["phone"] as? String else {
            return nil
        }

        let createdAt = Self.parseDate(userObject["createdAt"]) ?? Self.parseDate(userObject["created_at"])
        let user = AuthUser(id: userID, phone: phone, createdAt: createdAt)
        return AuthSession(token: token, expiresAt: expiresAt, user: user)
    }

    private static func parseDate(_ raw: Any?) -> Date? {
        if let raw {
            if let text = raw as? String {
                return iso8601WithFractional.date(from: text) ?? iso8601.date(from: text)
            }
            if let number = parseInt(raw) {
                return Date(timeIntervalSince1970: TimeInterval(number))
            }
        }
        return nil
    }

    private static func parseInt(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        if let text = raw as? String { return Int(text) }
        return nil
    }

    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
