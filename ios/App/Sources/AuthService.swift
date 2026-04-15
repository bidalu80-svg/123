import Foundation

enum AuthServiceError: LocalizedError {
    case invalidBaseURL
    case invalidPhone
    case invalidCode
    case weakPassword
    case invalidResponse
    case http(status: Int, message: String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "认证服务地址无效。"
        case .invalidPhone:
            return "手机号格式无效，请输入国际格式或纯数字手机号。"
        case .invalidCode:
            return "验证码格式无效。"
        case .weakPassword:
            return "密码至少需要 8 位，并包含字母和数字。"
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

    func sendCode(baseURL: String, phone: String) async throws -> AuthCodeSendResult {
        let normalizedPhone = Self.normalizedPhone(phone)
        guard Self.isPhoneValid(normalizedPhone) else {
            throw AuthServiceError.invalidPhone
        }

        let payload: [String: Any] = [
            "phone": normalizedPhone,
            "purpose": "register"
        ]
        let object = try await sendRequest(
            baseURL: baseURL,
            path: "/auth/send-code",
            method: "POST",
            body: payload,
            bearerToken: nil
        )

        let message = (object["message"] as? String) ?? "验证码发送成功。"
        let cooldown = Self.parseInt(object["cooldownSeconds"])
            ?? Self.parseInt(object["cooldown_seconds"])
            ?? 60
        return AuthCodeSendResult(message: message, cooldownSeconds: max(cooldown, 0))
    }

    func register(baseURL: String, phone: String, password: String, code: String) async throws -> AuthSession {
        let normalizedPhone = Self.normalizedPhone(phone)
        guard Self.isPhoneValid(normalizedPhone) else {
            throw AuthServiceError.invalidPhone
        }
        guard Self.isPasswordValid(password) else {
            throw AuthServiceError.weakPassword
        }
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isCodeValid(trimmedCode) else {
            throw AuthServiceError.invalidCode
        }

        let payload: [String: Any] = [
            "phone": normalizedPhone,
            "password": password,
            "code": trimmedCode
        ]
        let object = try await sendRequest(
            baseURL: baseURL,
            path: "/auth/register",
            method: "POST",
            body: payload,
            bearerToken: nil
        )
        guard let session = parseSession(from: object) else {
            throw AuthServiceError.invalidResponse
        }
        return session
    }

    func login(baseURL: String, phone: String, password: String) async throws -> AuthSession {
        let normalizedPhone = Self.normalizedPhone(phone)
        guard Self.isPhoneValid(normalizedPhone) else {
            throw AuthServiceError.invalidPhone
        }
        guard Self.isPasswordValid(password) else {
            throw AuthServiceError.weakPassword
        }

        let payload: [String: Any] = [
            "phone": normalizedPhone,
            "password": password
        ]
        let object = try await sendRequest(
            baseURL: baseURL,
            path: "/auth/login",
            method: "POST",
            body: payload,
            bearerToken: nil
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

    static func normalizedPhone(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("+") {
            let suffix = trimmed.dropFirst().filter { $0.isNumber }
            return "+\(suffix)"
        }
        return trimmed.filter { $0.isNumber }
    }

    static func isPhoneValid(_ raw: String) -> Bool {
        let pattern = #"^\+?[1-9]\d{7,14}$"#
        return raw.range(of: pattern, options: .regularExpression) != nil
    }

    static func isCodeValid(_ raw: String) -> Bool {
        raw.range(of: #"^\d{4,8}$"#, options: .regularExpression) != nil
    }

    static func isPasswordValid(_ raw: String) -> Bool {
        let lengthOK = raw.count >= 8 && raw.count <= 64
        let hasLetter = raw.range(of: #"[A-Za-z]"#, options: .regularExpression) != nil
        let hasNumber = raw.range(of: #"\d"#, options: .regularExpression) != nil
        return lengthOK && hasLetter && hasNumber
    }

    private func sendRequest(
        baseURL: String,
        path: String,
        method: String,
        body: [String: Any],
        bearerToken: String?
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
