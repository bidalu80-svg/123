import Foundation

struct ChatConfig: Codable, Equatable {
    var apiURL: String
    var apiKey: String
    var model: String
    var timeout: Double
    var streamEnabled: Bool

    static let `default` = ChatConfig(
        apiURL: "https://xxx/v1/chat/completions",
        apiKey: "",
        model: "gpt-5.4-pro",
        timeout: 30,
        streamEnabled: true
    )
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
            streamEnabled: ChatConfig.default.streamEnabled
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
