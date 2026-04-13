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
    static let completionPath = "/v1/chat/completions"
    static let modelsPath = "/v1/models"

    var apiURL: String
    var apiKey: String
    var model: String
    var timeout: Double
    var streamEnabled: Bool
    var themeMode: AppThemeMode
    var codeThemeMode: CodeThemeMode
    var realtimeContextEnabled: Bool
    var weatherContextEnabled: Bool
    var weatherLocation: String

    static let `default` = ChatConfig(
        apiURL: "https://xxx.com",
        apiKey: "",
        model: "gpt-5.4-pro",
        timeout: 30,
        streamEnabled: true,
        themeMode: .system,
        codeThemeMode: .followApp,
        realtimeContextEnabled: true,
        weatherContextEnabled: true,
        weatherLocation: "Shanghai"
    )

    init(
        apiURL: String,
        apiKey: String,
        model: String,
        timeout: Double,
        streamEnabled: Bool,
        themeMode: AppThemeMode = .system,
        codeThemeMode: CodeThemeMode = .followApp,
        realtimeContextEnabled: Bool = true,
        weatherContextEnabled: Bool = true,
        weatherLocation: String = "Shanghai"
    ) {
        self.apiURL = apiURL
        self.apiKey = apiKey
        self.model = model
        self.timeout = timeout
        self.streamEnabled = streamEnabled
        self.themeMode = themeMode
        self.codeThemeMode = codeThemeMode
        self.realtimeContextEnabled = realtimeContextEnabled
        self.weatherContextEnabled = weatherContextEnabled
        self.weatherLocation = weatherLocation
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
        realtimeContextEnabled = try c.decodeIfPresent(Bool.self, forKey: .realtimeContextEnabled) ?? true
        weatherContextEnabled = try c.decodeIfPresent(Bool.self, forKey: .weatherContextEnabled) ?? true
        weatherLocation = try c.decodeIfPresent(String.self, forKey: .weatherLocation) ?? "Shanghai"
    }

    var normalizedBaseURL: String {
        ChatConfigStore.normalizedBaseURL(apiURL)
    }

    var completionURLString: String {
        ChatConfigStore.completionsURL(apiURL)
    }

    var modelsURLString: String {
        ChatConfigStore.modelsURL(apiURL)
    }

    var siteDisplayName: String {
        guard let host = URL(string: normalizedBaseURL)?.host, !host.isEmpty else {
            return normalizedBaseURL.replacingOccurrences(of: "https://", with: "")
        }
        return host
    }
}

enum ChatConfigStore {
    private static let configKey = "chatapp.chat.config"

    static func load() -> ChatConfig {
        if let data = UserDefaults.standard.data(forKey: configKey),
           let config = try? JSONDecoder().decode(ChatConfig.self, from: data) {
            return normalize(config)
        }

        let bundleURL = (Bundle.main.object(forInfoDictionaryKey: "CHAT_API_URL") as? String) ?? ChatConfig.default.apiURL
        let bundleModel = (Bundle.main.object(forInfoDictionaryKey: "CHAT_MODEL") as? String) ?? ChatConfig.default.model

        return ChatConfig(
            apiURL: normalizedBaseURL(bundleURL),
            apiKey: "",
            model: bundleModel,
            timeout: ChatConfig.default.timeout,
            streamEnabled: ChatConfig.default.streamEnabled,
            themeMode: ChatConfig.default.themeMode,
            codeThemeMode: ChatConfig.default.codeThemeMode,
            realtimeContextEnabled: ChatConfig.default.realtimeContextEnabled,
            weatherContextEnabled: ChatConfig.default.weatherContextEnabled,
            weatherLocation: ChatConfig.default.weatherLocation
        )
    }

    static func save(_ config: ChatConfig) {
        let normalized = normalize(config)
        if let data = try? JSONEncoder().encode(normalized) {
            UserDefaults.standard.set(data, forKey: configKey)
        }
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: configKey)
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

        guard var components = URLComponents(string: withScheme) else {
            return withScheme
        }

        if let path = components.percentEncodedPath.removingPercentEncoding {
            let lowered = path.lowercased()
            if lowered.hasSuffix(ChatConfig.completionPath) {
                let cut = String(path.dropLast(ChatConfig.completionPath.count))
                components.percentEncodedPath = cut.isEmpty ? "" : cut
            } else if lowered.hasSuffix(ChatConfig.modelsPath) {
                let cut = String(path.dropLast(ChatConfig.modelsPath.count))
                components.percentEncodedPath = cut.isEmpty ? "" : cut
            }
        }

        let normalized = components.string ?? withScheme
        return normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized
    }

    static func completionsURL(_ raw: String) -> String {
        let base = normalizedBaseURL(raw)
        guard !base.isEmpty else { return "" }
        return "\(base)\(ChatConfig.completionPath)"
    }

    static func modelsURL(_ raw: String) -> String {
        let base = normalizedBaseURL(raw)
        guard !base.isEmpty else { return "" }
        return "\(base)\(ChatConfig.modelsPath)"
    }

    private static func normalize(_ config: ChatConfig) -> ChatConfig {
        ChatConfig(
            apiURL: normalizedBaseURL(config.apiURL),
            apiKey: config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            model: config.model.trimmingCharacters(in: .whitespacesAndNewlines),
            timeout: min(max(config.timeout, 5), 120),
            streamEnabled: config.streamEnabled,
            themeMode: config.themeMode,
            codeThemeMode: config.codeThemeMode,
            realtimeContextEnabled: config.realtimeContextEnabled,
            weatherContextEnabled: config.weatherContextEnabled,
            weatherLocation: config.weatherLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
