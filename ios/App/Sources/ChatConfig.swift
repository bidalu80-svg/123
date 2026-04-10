import Foundation

enum AppThemeMode: String, Codable, CaseIterable {
    case system
    case light
    case dark
}

enum CodeThemeMode: String, Codable, CaseIterable {
    case followApp
    case vscodeDark
    case githubLight
}

struct ChatConfig: Codable, Equatable {
    var apiURL: String
    var apiKey: String
    var model: String
    var timeout: Double
    var streamEnabled: Bool
    var themeMode: AppThemeMode
    var codeThemeMode: CodeThemeMode

    static let `default` = ChatConfig(
        apiURL: "https://xxx/v1/chat/completions",
        apiKey: "",
        model: "gpt-5.4-pro",
        timeout: 30,
        streamEnabled: true,
        themeMode: .system,
        codeThemeMode: .followApp
    )

    init(
        apiURL: String,
        apiKey: String,
        model: String,
        timeout: Double,
        streamEnabled: Bool,
        themeMode: AppThemeMode = .system,
        codeThemeMode: CodeThemeMode = .followApp
    ) {
        self.apiURL = apiURL
        self.apiKey = apiKey
        self.model = model
        self.timeout = timeout
        self.streamEnabled = streamEnabled
        self.themeMode = themeMode
        self.codeThemeMode = codeThemeMode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        apiURL = try c.decode(String.self, forKey: .apiURL)
        apiKey = try c.decode(String.self, forKey: .apiKey)
        model = try c.decode(String.self, forKey: .model)
        timeout = try c.decode(Double.self, forKey: .timeout)
        streamEnabled = try c.decode(Bool.self, forKey: .streamEnabled)
        themeMode = try c.decodeIfPresent(AppThemeMode.self, forKey: .themeMode) ?? .system
        codeThemeMode = try c.decodeIfPresent(CodeThemeMode.self, forKey: .codeThemeMode) ?? .followApp
    }
}

enum ChatConfigStore {
    private static let configKey = "chatapp.chat.config"

    static func load() -> ChatConfig {
        if let data = UserDefaults.standard.data(forKey: configKey),
           let config = try? JSONDecoder().decode(ChatConfig.self, from: data) {
            return config
        }

        let bundleURL = (Bundle.main.object(forInfoDictionaryKey: "CHAT_API_URL") as? String) ?? ChatConfig.default.apiURL
        let bundleModel = (Bundle.main.object(forInfoDictionaryKey: "CHAT_MODEL") as? String) ?? ChatConfig.default.model

        return ChatConfig(
            apiURL: bundleURL,
            apiKey: "",
            model: bundleModel,
            timeout: ChatConfig.default.timeout,
            streamEnabled: ChatConfig.default.streamEnabled,
            themeMode: ChatConfig.default.themeMode,
            codeThemeMode: ChatConfig.default.codeThemeMode
        )
    }

    static func save(_ config: ChatConfig) {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: configKey)
        }
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: configKey)
    }

    static func normalizedURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }
        return "https://\(trimmed)"
    }
}
