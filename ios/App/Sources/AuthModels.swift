import Foundation

enum AuthMode: String, CaseIterable, Identifiable {
    case login
    case register

    var id: String { rawValue }

    var title: String {
        switch self {
        case .login:
            return "登录"
        case .register:
            return "注册"
        }
    }
}

struct AuthUser: Codable, Equatable {
    let id: String
    let phone: String
    let createdAt: Date?
}

struct AuthSession: Codable, Equatable {
    let token: String
    let expiresAt: Date?
    let user: AuthUser
}

struct AuthCodeSendResult: Equatable {
    let message: String
    let cooldownSeconds: Int
}

struct AuthTokenPayload: Codable {
    let token: String
    let expiresAt: Date?
    let user: AuthUser
}

enum AuthSessionStore {
    private static let sessionKey = "chatapp.auth.session"
    private static let endpointKey = "chatapp.auth.baseurl"

    static func loadSession(defaults: UserDefaults = .standard) -> AuthSession? {
        guard let data = defaults.data(forKey: sessionKey) else { return nil }
        return try? decoder.decode(AuthSession.self, from: data)
    }

    static func saveSession(_ session: AuthSession, defaults: UserDefaults = .standard) {
        guard let data = try? encoder.encode(session) else { return }
        defaults.set(data, forKey: sessionKey)
    }

    static func clearSession(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: sessionKey)
    }

    static func loadBaseURL(defaults: UserDefaults = .standard) -> String {
        if let saved = defaults.string(forKey: endpointKey), !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return saved
        }
        return (Bundle.main.object(forInfoDictionaryKey: "AUTH_API_URL") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func saveBaseURL(_ raw: String, defaults: UserDefaults = .standard) {
        defaults.set(normalizedBaseURL(raw), forKey: endpointKey)
    }

    static func normalizedBaseURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let withScheme: String
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            withScheme = trimmed
        } else {
            withScheme = "https://\(trimmed)"
        }
        return withScheme.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
