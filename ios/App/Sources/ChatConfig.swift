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

enum APIEndpointMode: String, Codable, CaseIterable {
    case chatCompletions
    case responses
    case imageGenerations
    case videoGenerations
    case audioTranscriptions
    case embeddings
    case models

    var title: String {
        switch self {
        case .chatCompletions:
            return "聊天"
        case .responses:
            return "响应"
        case .imageGenerations:
            return "生图"
        case .videoGenerations:
            return "生视频"
        case .audioTranscriptions:
            return "语音转文字"
        case .embeddings:
            return "向量"
        case .models:
            return "模型列表"
        }
    }

    var shortLabel: String {
        switch self {
        case .chatCompletions:
            return "Chat"
        case .responses:
            return "响应"
        case .imageGenerations:
            return "Image"
        case .videoGenerations:
            return "Video"
        case .audioTranscriptions:
            return "Audio"
        case .embeddings:
            return "Embedding"
        case .models:
            return "Models"
        }
    }

    var requiresTextPrompt: Bool {
        switch self {
        case .chatCompletions, .responses, .imageGenerations, .videoGenerations, .embeddings:
            return true
        case .audioTranscriptions, .models:
            return false
        }
    }
}

struct ChatConfig: Codable, Equatable {
    static let defaultChatCompletionsPath = "/v1/chat/completions"
    static let defaultResponsesPath = "/v1/responses"
    static let defaultImagesGenerationsPath = "/v1/images/generations"
    static let defaultVideoGenerationsPath = "/v1/videos/generations"
    static let defaultAudioTranscriptionsPath = "/v1/audio/transcriptions"
    static let defaultEmbeddingsPath = "/v1/embeddings"
    static let defaultModelsPath = "/v1/models"

    var apiURL: String
    var apiKey: String
    var model: String
    var endpointMode: APIEndpointMode
    var chatCompletionsPath: String
    var responsesPath: String
    var imagesGenerationsPath: String
    var videoGenerationsPath: String
    var audioTranscriptionsPath: String
    var embeddingsPath: String
    var modelsPath: String
    var imageGenerationSize: String
    var timeout: Double
    var streamEnabled: Bool
    var frontendAutoBuildEnabled: Bool
    var themeMode: AppThemeMode
    var codeThemeMode: CodeThemeMode
    var realtimeContextEnabled: Bool
    var weatherContextEnabled: Bool
    var weatherLocation: String
    var marketContextEnabled: Bool
    var marketSymbols: String
    var hotNewsContextEnabled: Bool
    var hotNewsCount: Int
    var memoryModeEnabled: Bool
    var soundEffectsEnabled: Bool
    var replySpeechPlaybackEnabled: Bool

    static let `default` = ChatConfig(
        apiURL: "https://xxx.com",
        apiKey: "",
        model: "gpt-5.4",
        endpointMode: .chatCompletions,
        chatCompletionsPath: ChatConfig.defaultChatCompletionsPath,
        responsesPath: ChatConfig.defaultResponsesPath,
        imagesGenerationsPath: ChatConfig.defaultImagesGenerationsPath,
        videoGenerationsPath: ChatConfig.defaultVideoGenerationsPath,
        audioTranscriptionsPath: ChatConfig.defaultAudioTranscriptionsPath,
        embeddingsPath: ChatConfig.defaultEmbeddingsPath,
        modelsPath: ChatConfig.defaultModelsPath,
        imageGenerationSize: "1024x1024",
        timeout: 30,
        streamEnabled: true,
        frontendAutoBuildEnabled: false,
        themeMode: .system,
        codeThemeMode: .followApp,
        realtimeContextEnabled: false,
        weatherContextEnabled: false,
        weatherLocation: "Shanghai",
        marketContextEnabled: false,
        marketSymbols: "GC=F,CL=F,BZ=F,SI=F,HG=F,^GSPC,^IXIC,^DJI,^RUT,^N225,^HSI,^FTSE,^GDAXI,AAPL,NVDA,TSLA,MSFT,AMZN",
        hotNewsContextEnabled: false,
        hotNewsCount: 6,
        memoryModeEnabled: false,
        soundEffectsEnabled: true,
        replySpeechPlaybackEnabled: false
    )

    init(
        apiURL: String,
        apiKey: String,
        model: String,
        endpointMode: APIEndpointMode = .chatCompletions,
        chatCompletionsPath: String = ChatConfig.defaultChatCompletionsPath,
        responsesPath: String = ChatConfig.defaultResponsesPath,
        imagesGenerationsPath: String = ChatConfig.defaultImagesGenerationsPath,
        videoGenerationsPath: String = ChatConfig.defaultVideoGenerationsPath,
        audioTranscriptionsPath: String = ChatConfig.defaultAudioTranscriptionsPath,
        embeddingsPath: String = ChatConfig.defaultEmbeddingsPath,
        modelsPath: String = ChatConfig.defaultModelsPath,
        imageGenerationSize: String = "1024x1024",
        timeout: Double,
        streamEnabled: Bool,
        frontendAutoBuildEnabled: Bool = false,
        themeMode: AppThemeMode = .system,
        codeThemeMode: CodeThemeMode = .followApp,
        realtimeContextEnabled: Bool = false,
        weatherContextEnabled: Bool = false,
        weatherLocation: String = "Shanghai",
        marketContextEnabled: Bool = false,
        marketSymbols: String = "GC=F,CL=F,BZ=F,SI=F,HG=F,^GSPC,^IXIC,^DJI,^RUT,^N225,^HSI,^FTSE,^GDAXI,AAPL,NVDA,TSLA,MSFT,AMZN",
        hotNewsContextEnabled: Bool = false,
        hotNewsCount: Int = 6,
        memoryModeEnabled: Bool = false,
        soundEffectsEnabled: Bool = true,
        replySpeechPlaybackEnabled: Bool = false
    ) {
        self.apiURL = apiURL
        self.apiKey = apiKey
        self.model = model
        self.endpointMode = endpointMode
        self.chatCompletionsPath = chatCompletionsPath
        self.responsesPath = responsesPath
        self.imagesGenerationsPath = imagesGenerationsPath
        self.videoGenerationsPath = videoGenerationsPath
        self.audioTranscriptionsPath = audioTranscriptionsPath
        self.embeddingsPath = embeddingsPath
        self.modelsPath = modelsPath
        self.imageGenerationSize = imageGenerationSize
        self.timeout = timeout
        self.streamEnabled = streamEnabled
        self.frontendAutoBuildEnabled = frontendAutoBuildEnabled
        self.themeMode = themeMode
        self.codeThemeMode = codeThemeMode
        self.realtimeContextEnabled = realtimeContextEnabled
        self.weatherContextEnabled = weatherContextEnabled
        self.weatherLocation = weatherLocation
        self.marketContextEnabled = marketContextEnabled
        self.marketSymbols = marketSymbols
        self.hotNewsContextEnabled = hotNewsContextEnabled
        self.hotNewsCount = hotNewsCount
        self.memoryModeEnabled = memoryModeEnabled
        self.soundEffectsEnabled = soundEffectsEnabled
        self.replySpeechPlaybackEnabled = replySpeechPlaybackEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        apiURL = try c.decode(String.self, forKey: .apiURL)
        apiKey = try c.decode(String.self, forKey: .apiKey)
        model = try c.decode(String.self, forKey: .model)
        endpointMode = try c.decodeIfPresent(APIEndpointMode.self, forKey: .endpointMode) ?? .chatCompletions
        chatCompletionsPath = try c.decodeIfPresent(String.self, forKey: .chatCompletionsPath) ?? ChatConfig.defaultChatCompletionsPath
        responsesPath = try c.decodeIfPresent(String.self, forKey: .responsesPath) ?? ChatConfig.defaultResponsesPath
        imagesGenerationsPath = try c.decodeIfPresent(String.self, forKey: .imagesGenerationsPath) ?? ChatConfig.defaultImagesGenerationsPath
        videoGenerationsPath = try c.decodeIfPresent(String.self, forKey: .videoGenerationsPath) ?? ChatConfig.defaultVideoGenerationsPath
        audioTranscriptionsPath = try c.decodeIfPresent(String.self, forKey: .audioTranscriptionsPath) ?? ChatConfig.defaultAudioTranscriptionsPath
        embeddingsPath = try c.decodeIfPresent(String.self, forKey: .embeddingsPath) ?? ChatConfig.defaultEmbeddingsPath
        modelsPath = try c.decodeIfPresent(String.self, forKey: .modelsPath) ?? ChatConfig.defaultModelsPath
        imageGenerationSize = try c.decodeIfPresent(String.self, forKey: .imageGenerationSize) ?? "1024x1024"
        timeout = try c.decode(Double.self, forKey: .timeout)
        streamEnabled = try c.decode(Bool.self, forKey: .streamEnabled)
        frontendAutoBuildEnabled = try c.decodeIfPresent(Bool.self, forKey: .frontendAutoBuildEnabled) ?? false
        themeMode = try c.decodeIfPresent(AppThemeMode.self, forKey: .themeMode) ?? .system
        codeThemeMode = try c.decodeIfPresent(CodeThemeMode.self, forKey: .codeThemeMode) ?? .followApp
        realtimeContextEnabled = try c.decodeIfPresent(Bool.self, forKey: .realtimeContextEnabled) ?? false
        weatherContextEnabled = try c.decodeIfPresent(Bool.self, forKey: .weatherContextEnabled) ?? false
        weatherLocation = try c.decodeIfPresent(String.self, forKey: .weatherLocation) ?? "Shanghai"
        marketContextEnabled = try c.decodeIfPresent(Bool.self, forKey: .marketContextEnabled) ?? false
        marketSymbols = try c.decodeIfPresent(String.self, forKey: .marketSymbols) ?? "GC=F,CL=F,BZ=F,SI=F,HG=F,^GSPC,^IXIC,^DJI,^RUT,^N225,^HSI,^FTSE,^GDAXI,AAPL,NVDA,TSLA,MSFT,AMZN"
        hotNewsContextEnabled = try c.decodeIfPresent(Bool.self, forKey: .hotNewsContextEnabled) ?? false
        hotNewsCount = try c.decodeIfPresent(Int.self, forKey: .hotNewsCount) ?? 6
        memoryModeEnabled = try c.decodeIfPresent(Bool.self, forKey: .memoryModeEnabled) ?? false
        soundEffectsEnabled = try c.decodeIfPresent(Bool.self, forKey: .soundEffectsEnabled) ?? true
        replySpeechPlaybackEnabled = try c.decodeIfPresent(Bool.self, forKey: .replySpeechPlaybackEnabled) ?? false
    }

    var normalizedBaseURL: String {
        ChatConfigStore.normalizedBaseURL(apiURL)
    }

    var chatCompletionsURLString: String {
        ChatConfigStore.endpointURL(apiURL, path: chatCompletionsPath, fallback: ChatConfig.defaultChatCompletionsPath)
    }

    var responsesURLString: String {
        ChatConfigStore.endpointURL(apiURL, path: responsesPath, fallback: ChatConfig.defaultResponsesPath)
    }

    var imagesGenerationsURLString: String {
        ChatConfigStore.endpointURL(apiURL, path: imagesGenerationsPath, fallback: ChatConfig.defaultImagesGenerationsPath)
    }

    var videoGenerationsURLString: String {
        ChatConfigStore.endpointURL(apiURL, path: videoGenerationsPath, fallback: ChatConfig.defaultVideoGenerationsPath)
    }

    var audioTranscriptionsURLString: String {
        ChatConfigStore.endpointURL(apiURL, path: audioTranscriptionsPath, fallback: ChatConfig.defaultAudioTranscriptionsPath)
    }

    var embeddingsURLString: String {
        ChatConfigStore.endpointURL(apiURL, path: embeddingsPath, fallback: ChatConfig.defaultEmbeddingsPath)
    }

    var activeEndpointURLString: String {
        switch endpointMode {
        case .chatCompletions:
            return chatCompletionsURLString
        case .responses:
            return responsesURLString
        case .imageGenerations:
            return imagesGenerationsURLString
        case .videoGenerations:
            return videoGenerationsURLString
        case .audioTranscriptions:
            return audioTranscriptionsURLString
        case .embeddings:
            return embeddingsURLString
        case .models:
            return modelsURLString
        }
    }

    var completionURLString: String {
        chatCompletionsURLString
    }

    var modelsURLString: String {
        ChatConfigStore.endpointURL(apiURL, path: modelsPath, fallback: ChatConfig.defaultModelsPath)
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
    private static let onboardingDoneKey = "chatapp.config.onboarding.done"
    private static let legacyDefaultModel = "gpt-5.4-pro"

    static func load() -> ChatConfig {
        if let data = UserDefaults.standard.data(forKey: configKey),
           let config = try? JSONDecoder().decode(ChatConfig.self, from: data) {
            return normalize(config)
        }

        let bundleURL = (Bundle.main.object(forInfoDictionaryKey: "CHAT_API_URL") as? String) ?? ChatConfig.default.apiURL
        let rawBundleModel = (Bundle.main.object(forInfoDictionaryKey: "CHAT_MODEL") as? String) ?? ChatConfig.default.model
        let bundleModel = migratedModelNameIfNeeded(rawBundleModel)

        return ChatConfig(
            apiURL: normalizedBaseURL(bundleURL),
            apiKey: "",
            model: bundleModel,
            endpointMode: ChatConfig.default.endpointMode,
            chatCompletionsPath: ChatConfig.default.chatCompletionsPath,
            responsesPath: ChatConfig.default.responsesPath,
            imagesGenerationsPath: ChatConfig.default.imagesGenerationsPath,
            videoGenerationsPath: ChatConfig.default.videoGenerationsPath,
            audioTranscriptionsPath: ChatConfig.default.audioTranscriptionsPath,
            embeddingsPath: ChatConfig.default.embeddingsPath,
            modelsPath: ChatConfig.default.modelsPath,
            imageGenerationSize: ChatConfig.default.imageGenerationSize,
            timeout: ChatConfig.default.timeout,
            streamEnabled: ChatConfig.default.streamEnabled,
            frontendAutoBuildEnabled: ChatConfig.default.frontendAutoBuildEnabled,
            themeMode: ChatConfig.default.themeMode,
            codeThemeMode: ChatConfig.default.codeThemeMode,
            realtimeContextEnabled: ChatConfig.default.realtimeContextEnabled,
            weatherContextEnabled: ChatConfig.default.weatherContextEnabled,
            weatherLocation: ChatConfig.default.weatherLocation,
            marketContextEnabled: ChatConfig.default.marketContextEnabled,
            marketSymbols: ChatConfig.default.marketSymbols,
            hotNewsContextEnabled: ChatConfig.default.hotNewsContextEnabled,
            hotNewsCount: ChatConfig.default.hotNewsCount,
            memoryModeEnabled: ChatConfig.default.memoryModeEnabled,
            soundEffectsEnabled: ChatConfig.default.soundEffectsEnabled,
            replySpeechPlaybackEnabled: ChatConfig.default.replySpeechPlaybackEnabled
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
            for endpoint in endpointSuffixCandidates() {
                let lowerEndpoint = endpoint.lowercased()
                if lowered.hasSuffix(lowerEndpoint) {
                    let cut = String(path.dropLast(endpoint.count))
                    components.percentEncodedPath = cut.isEmpty ? "" : cut
                    break
                }
            }
        }

        let normalized = components.string ?? withScheme
        return normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized
    }

    static func normalizeEndpointPath(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
            return trimmed
        }
        let base = trimmed.isEmpty ? fallback : trimmed
        if base.hasPrefix("/") {
            return base
        }
        return "/\(base)"
    }

    static func endpointURL(_ raw: String, path: String, fallback: String) -> String {
        let normalizedPath = normalizeEndpointPath(path, fallback: fallback)
        let loweredPath = normalizedPath.lowercased()
        if loweredPath.hasPrefix("http://") || loweredPath.hasPrefix("https://") {
            return normalizedPath
        }
        let base = normalizedBaseURL(raw)
        guard !base.isEmpty else { return "" }
        return "\(base)\(normalizedPath)"
    }

    static func completionsURL(_ raw: String) -> String {
        endpointURL(raw, path: ChatConfig.defaultChatCompletionsPath, fallback: ChatConfig.defaultChatCompletionsPath)
    }

    static func modelsURL(_ raw: String) -> String {
        endpointURL(raw, path: ChatConfig.defaultModelsPath, fallback: ChatConfig.defaultModelsPath)
    }

    private static func endpointSuffixCandidates() -> [String] {
        [
            ChatConfig.defaultChatCompletionsPath,
            ChatConfig.defaultResponsesPath,
            ChatConfig.defaultImagesGenerationsPath,
            ChatConfig.defaultVideoGenerationsPath,
            ChatConfig.defaultAudioTranscriptionsPath,
            ChatConfig.defaultEmbeddingsPath,
            ChatConfig.defaultModelsPath
        ]
    }

    private static func normalize(_ config: ChatConfig) -> ChatConfig {
        let normalizedModel = migratedModelNameIfNeeded(config.model)
        return ChatConfig(
            apiURL: normalizedBaseURL(config.apiURL),
            apiKey: config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            model: normalizedModel.trimmingCharacters(in: .whitespacesAndNewlines),
            endpointMode: config.endpointMode,
            chatCompletionsPath: normalizeEndpointPath(config.chatCompletionsPath, fallback: ChatConfig.defaultChatCompletionsPath),
            responsesPath: normalizeEndpointPath(config.responsesPath, fallback: ChatConfig.defaultResponsesPath),
            imagesGenerationsPath: normalizeEndpointPath(config.imagesGenerationsPath, fallback: ChatConfig.defaultImagesGenerationsPath),
            videoGenerationsPath: normalizeEndpointPath(config.videoGenerationsPath, fallback: ChatConfig.defaultVideoGenerationsPath),
            audioTranscriptionsPath: normalizeEndpointPath(config.audioTranscriptionsPath, fallback: ChatConfig.defaultAudioTranscriptionsPath),
            embeddingsPath: normalizeEndpointPath(config.embeddingsPath, fallback: ChatConfig.defaultEmbeddingsPath),
            modelsPath: normalizeEndpointPath(config.modelsPath, fallback: ChatConfig.defaultModelsPath),
            imageGenerationSize: config.imageGenerationSize.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? ChatConfig.default.imageGenerationSize
                : config.imageGenerationSize.trimmingCharacters(in: .whitespacesAndNewlines),
            timeout: min(max(config.timeout, 5), 120),
            streamEnabled: config.streamEnabled,
            frontendAutoBuildEnabled: config.frontendAutoBuildEnabled,
            themeMode: config.themeMode,
            codeThemeMode: config.codeThemeMode,
            realtimeContextEnabled: config.realtimeContextEnabled,
            weatherContextEnabled: config.weatherContextEnabled,
            weatherLocation: config.weatherLocation.trimmingCharacters(in: .whitespacesAndNewlines),
            marketContextEnabled: config.marketContextEnabled,
            marketSymbols: config.marketSymbols.trimmingCharacters(in: .whitespacesAndNewlines),
            hotNewsContextEnabled: config.hotNewsContextEnabled,
            hotNewsCount: min(max(config.hotNewsCount, 1), 12),
            memoryModeEnabled: config.memoryModeEnabled,
            soundEffectsEnabled: config.soundEffectsEnabled,
            replySpeechPlaybackEnabled: config.replySpeechPlaybackEnabled
        )
    }

    private static func migratedModelNameIfNeeded(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: onboardingDoneKey)
        if !hasCompletedOnboarding && trimmed == legacyDefaultModel {
            return ChatConfig.default.model
        }
        return trimmed
    }
}
