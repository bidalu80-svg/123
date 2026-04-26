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

enum ReplySpeechVoicePreset: String, Codable, CaseIterable {
    case systemNatural
    case livelyFemale
    case warmNarrator
    case doubaoLike
    case xiaoduLike

    var title: String {
        switch self {
        case .systemNatural:
            return "系统自然"
        case .livelyFemale:
            return "活泼女声"
        case .warmNarrator:
            return "温和旁白"
        case .doubaoLike:
            return "豆包风（近似）"
        case .xiaoduLike:
            return "小度风（近似）"
        }
    }
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

enum APIProviderMode: String, Codable, CaseIterable {
    case auto
    case openAICompatible
    case azureOpenAI
    case anthropic
    case gemini
    case xAI

    var title: String {
        switch self {
        case .auto:
            return "自动识别"
        case .openAICompatible:
            return "OpenAI 兼容"
        case .azureOpenAI:
            return "Azure OpenAI"
        case .anthropic:
            return "Anthropic"
        case .gemini:
            return "Google Gemini"
        case .xAI:
            return "xAI"
        }
    }

    var supportsResponsesAPI: Bool {
        switch self {
        case .auto, .openAICompatible, .azureOpenAI, .xAI:
            return true
        case .anthropic, .gemini:
            return false
        }
    }
}

enum BuiltinAISkill: String, Codable, CaseIterable {
    case skillCreator = "skill-creator"

    var displayName: String {
        switch self {
        case .skillCreator:
            return "技能创建器"
        }
    }

    var descriptionCN: String {
        switch self {
        case .skillCreator:
            return "用于创建或更新 Skill。默认内置技能模板，可按需自行修改。"
        }
    }

    var defaultPrompt: String {
        switch self {
        case .skillCreator:
            return """
            ---
            name: skill-creator
            version: 2.0.0
            description: Guide for creating effective skills. This skill should be used when users want to create a new skill (or update an existing skill) that extends Claude's capabilities with specialized knowledge, workflows, or tool integrations.
            ---

            # Skill Creator

            This skill provides guidance for creating effective skills.

            ## About Skills

            Skills are modular, self-contained packages that extend Claude's capabilities by providing
            specialized knowledge, workflows, and tools. Think of them as "onboarding guides" for specific
            domains or tasks—they transform Claude from a general-purpose agent into a specialized agent
            equipped with procedural knowledge that no model can fully possess.

            ### What Skills Provide

            1. Specialized workflows - Multi-step procedures for specific domains
            2. Tool integrations - Instructions for working with specific file formats or APIs
            3. Domain expertise - Company-specific knowledge, schemas, business logic
            4. Bundled resources - Scripts, references, and assets for complex and repetitive tasks

            ## Core Principles

            ### Concise is Key

            The context window is a public good. Skills share the context window with everything else Claude needs: system prompt, conversation history, other Skills' metadata, and the actual user request.

            **Default assumption: Claude is already very smart.** Only add context Claude doesn't already have. Challenge each piece of information: "Does Claude really need this explanation?" and "Does this paragraph justify its token cost?"

            Prefer concise examples over verbose explanations.

            ### Set Appropriate Degrees of Freedom

            Match the level of specificity to the task's fragility and variability:

            - **High freedom (text-based instructions)**: Use when multiple approaches are valid.
            - **Medium freedom (pseudocode or scripts with parameters)**: Use when a preferred pattern exists.
            - **Low freedom (specific scripts, few parameters)**: Use when operations are fragile, consistency is critical, or a specific sequence must be followed.

            ### Anatomy of a Skill

            Every skill consists of a required SKILL.md file and optional bundled resources:

            ```
            skill-name/
            ├── SKILL.md (required)
            │   ├── YAML frontmatter (name + description required)
            │   └── Markdown instructions
            └── Bundled Resources (optional)
                ├── scripts/       - Executable code
                ├── references/    - Documentation loaded as needed
                └── assets/        - Files used in output (templates, icons, etc.)
            ```

            #### SKILL.md Frontmatter

            - `name` (required): The skill name
            - `description` (required): What the skill does and when to trigger it. Be comprehensive—this is the primary triggering mechanism.

            #### SKILL.md Body

            Instructions and guidance, loaded after the skill triggers. Keep under 500 lines; split into reference files when approaching this limit.

            ### Progressive Disclosure

            Skills use three loading levels:
            1. **Metadata** - Always in context (~100 words)
            2. **SKILL.md body** - When skill triggers (<5k words)
            3. **Bundled resources** - As needed (unlimited)

            ## Skill Creation Process

            1. **Understand** the skill with concrete examples from the user
            2. **Plan** reusable contents (scripts, references, assets)
            3. **Create** the SKILL.md with proper frontmatter and instructions
            4. **Test** by using the skill on real tasks
            5. **Iterate** based on actual usage

            ### Writing the SKILL.md

            - Use imperative/infinitive form
            - `description` field should include all "when to use" triggers (body is loaded after triggering)
            - Only add context Claude doesn't already have
            - Prefer concise examples over verbose explanations
            - Keep essential workflow in SKILL.md; move detailed reference material to separate files

            ### What NOT to Include

            Do not create extraneous files: README.md, INSTALLATION_GUIDE.md, CHANGELOG.md, etc. The skill should only contain what an AI agent needs to do the job.
            """
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
    static let defaultShellExecutionPath = "/v1/mcp/call_tool"
    static let defaultRemotePythonExecutionPath = ""
    static let defaultBuiltInRemotePythonShellExecuteURL = "http://8.218.177.114/v1/shell/execute"
    static let legacyAutoRemotePythonExecutionPath = "/v1/python/execute"

    var apiURL: String
    var apiKey: String
    var model: String
    var providerMode: APIProviderMode
    var providerAPIVersion: String
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
    var shellExecutionPath: String
    var shellExecutionAPIKey: String
    var shellExecutionTimeout: Double
    var shellExecutionWorkingDirectory: String
    var remotePythonExecutionEnabled: Bool
    var remotePythonExecutionPath: String
    var remotePythonExecutionAPIKey: String
    var remotePythonExecutionTimeout: Double
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
    var autoSkillActivationEnabled: Bool
    var soundEffectsEnabled: Bool
    var replySpeechPlaybackEnabled: Bool
    var replySpeechVoicePreset: ReplySpeechVoicePreset
    var enabledBuiltinSkillIDs: [String]
    var customBuiltinSkillPrompts: [String: String]

    static let `default` = ChatConfig(
        apiURL: "",
        apiKey: "",
        model: "",
        providerMode: .auto,
        providerAPIVersion: "",
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
        frontendAutoBuildEnabled: true,
        shellExecutionPath: ChatConfig.defaultShellExecutionPath,
        shellExecutionAPIKey: "",
        shellExecutionTimeout: 90,
        shellExecutionWorkingDirectory: "latest",
        remotePythonExecutionEnabled: true,
        remotePythonExecutionPath: ChatConfig.defaultRemotePythonExecutionPath,
        remotePythonExecutionAPIKey: "",
        remotePythonExecutionTimeout: 180,
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
        autoSkillActivationEnabled: true,
        soundEffectsEnabled: true,
        replySpeechPlaybackEnabled: false,
        replySpeechVoicePreset: .systemNatural,
        enabledBuiltinSkillIDs: [],
        customBuiltinSkillPrompts: [:]
    )

    init(
        apiURL: String,
        apiKey: String,
        model: String,
        providerMode: APIProviderMode = .auto,
        providerAPIVersion: String = "",
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
        frontendAutoBuildEnabled: Bool = true,
        shellExecutionPath: String = ChatConfig.defaultShellExecutionPath,
        shellExecutionAPIKey: String = "",
        shellExecutionTimeout: Double = 90,
        shellExecutionWorkingDirectory: String = "latest",
        remotePythonExecutionEnabled: Bool = true,
        remotePythonExecutionPath: String = ChatConfig.defaultRemotePythonExecutionPath,
        remotePythonExecutionAPIKey: String = "",
        remotePythonExecutionTimeout: Double = 180,
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
        autoSkillActivationEnabled: Bool = true,
        soundEffectsEnabled: Bool = true,
        replySpeechPlaybackEnabled: Bool = false,
        replySpeechVoicePreset: ReplySpeechVoicePreset = .systemNatural,
        enabledBuiltinSkillIDs: [String] = [],
        customBuiltinSkillPrompts: [String: String] = [:]
    ) {
        self.apiURL = apiURL
        self.apiKey = apiKey
        self.model = model
        self.providerMode = providerMode
        self.providerAPIVersion = providerAPIVersion
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
        _ = frontendAutoBuildEnabled
        self.frontendAutoBuildEnabled = true
        self.shellExecutionPath = shellExecutionPath
        self.shellExecutionAPIKey = shellExecutionAPIKey
        self.shellExecutionTimeout = shellExecutionTimeout
        self.shellExecutionWorkingDirectory = shellExecutionWorkingDirectory
        self.remotePythonExecutionEnabled = remotePythonExecutionEnabled
        self.remotePythonExecutionPath = remotePythonExecutionPath
        self.remotePythonExecutionAPIKey = remotePythonExecutionAPIKey
        self.remotePythonExecutionTimeout = remotePythonExecutionTimeout
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
        self.autoSkillActivationEnabled = autoSkillActivationEnabled
        self.soundEffectsEnabled = soundEffectsEnabled
        self.replySpeechPlaybackEnabled = replySpeechPlaybackEnabled
        self.replySpeechVoicePreset = replySpeechVoicePreset
        self.enabledBuiltinSkillIDs = enabledBuiltinSkillIDs
        self.customBuiltinSkillPrompts = customBuiltinSkillPrompts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        apiURL = try c.decode(String.self, forKey: .apiURL)
        apiKey = try c.decode(String.self, forKey: .apiKey)
        model = try c.decode(String.self, forKey: .model)
        providerMode = try c.decodeIfPresent(APIProviderMode.self, forKey: .providerMode) ?? .auto
        providerAPIVersion = try c.decodeIfPresent(String.self, forKey: .providerAPIVersion) ?? ""
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
        frontendAutoBuildEnabled = true
        shellExecutionPath = try c.decodeIfPresent(String.self, forKey: .shellExecutionPath) ?? ChatConfig.defaultShellExecutionPath
        shellExecutionAPIKey = try c.decodeIfPresent(String.self, forKey: .shellExecutionAPIKey) ?? ""
        shellExecutionTimeout = try c.decodeIfPresent(Double.self, forKey: .shellExecutionTimeout) ?? 90
        shellExecutionWorkingDirectory = try c.decodeIfPresent(String.self, forKey: .shellExecutionWorkingDirectory) ?? "latest"
        remotePythonExecutionEnabled = try c.decodeIfPresent(Bool.self, forKey: .remotePythonExecutionEnabled) ?? true
        remotePythonExecutionPath = try c.decodeIfPresent(String.self, forKey: .remotePythonExecutionPath) ?? ChatConfig.defaultRemotePythonExecutionPath
        remotePythonExecutionAPIKey = try c.decodeIfPresent(String.self, forKey: .remotePythonExecutionAPIKey) ?? ""
        remotePythonExecutionTimeout = try c.decodeIfPresent(Double.self, forKey: .remotePythonExecutionTimeout) ?? 180
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
        autoSkillActivationEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoSkillActivationEnabled) ?? true
        soundEffectsEnabled = try c.decodeIfPresent(Bool.self, forKey: .soundEffectsEnabled) ?? true
        replySpeechPlaybackEnabled = try c.decodeIfPresent(Bool.self, forKey: .replySpeechPlaybackEnabled) ?? false
        replySpeechVoicePreset = try c.decodeIfPresent(ReplySpeechVoicePreset.self, forKey: .replySpeechVoicePreset) ?? .systemNatural
        enabledBuiltinSkillIDs = try c.decodeIfPresent([String].self, forKey: .enabledBuiltinSkillIDs) ?? []
        customBuiltinSkillPrompts = try c.decodeIfPresent([String: String].self, forKey: .customBuiltinSkillPrompts) ?? [:]
    }

    var normalizedBaseURL: String {
        ChatConfigStore.normalizedBaseURL(apiURL)
    }

    var resolvedProviderMode: APIProviderMode {
        if providerMode != .auto {
            return providerMode
        }

        let loweredURL = normalizedBaseURL.lowercased()
        if loweredURL.contains(".openai.azure.com")
            || loweredURL.contains("azure.com/openai")
            || loweredURL.contains("/openai/") {
            return .azureOpenAI
        }
        if loweredURL.contains("anthropic.com") {
            return .anthropic
        }
        if loweredURL.contains("generativelanguage.googleapis.com")
            || loweredURL.contains("googleapis.com/generativelanguage")
            || loweredURL.contains("gemini.googleapis.com") {
            return .gemini
        }
        if loweredURL.contains("x.ai") || loweredURL.contains("api.x.ai") {
            return .xAI
        }
        return .openAICompatible
    }

    var normalizedProviderAPIVersion: String {
        let trimmed = providerAPIVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        switch resolvedProviderMode {
        case .azureOpenAI:
            return "2024-06-01"
        case .anthropic:
            return "2023-06-01"
        case .gemini:
            return "v1beta"
        case .auto, .openAICompatible, .xAI:
            return ""
        }
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

    var shellExecutionURLString: String {
        ChatConfigStore.endpointURL(apiURL, path: shellExecutionPath, fallback: ChatConfig.defaultShellExecutionPath)
    }

    var resolvedShellExecutionAPIKey: String {
        guard !shellExecutionURLString.isEmpty else { return "" }
        let shellKey = shellExecutionAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !shellKey.isEmpty {
            return shellKey
        }
        return apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var remotePythonExecutionURLString: String {
        let configuredPath = remotePythonExecutionPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configuredPath.isEmpty else { return "" }
        return ChatConfigStore.endpointURL(
            apiURL,
            path: configuredPath,
            fallback: ""
        )
    }

    var resolvedRemotePythonExecutionAPIKey: String {
        guard !remotePythonExecutionURLString.isEmpty else { return "" }
        let remoteKey = remotePythonExecutionAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remoteKey.isEmpty {
            return remoteKey
        }
        return apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var effectiveRemotePythonExecutionURLString: String {
        let direct = remotePythonExecutionURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !direct.isEmpty {
            return direct
        }
        guard remotePythonExecutionEnabled else { return "" }
        return ChatConfig.defaultBuiltInRemotePythonShellExecuteURL
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
    private static let legacyBundledDefaultAPIURL = "http://8.218.177.114"
    private static let legacyBundledDefaultModel = "astron-code-latest"

    static func load() -> ChatConfig {
        let bundleURL = (Bundle.main.object(forInfoDictionaryKey: "CHAT_API_URL") as? String) ?? ChatConfig.default.apiURL
        let rawBundleModel = (Bundle.main.object(forInfoDictionaryKey: "CHAT_MODEL") as? String) ?? ChatConfig.default.model
        let bundleModel = migratedModelNameIfNeeded(rawBundleModel)

        if let data = UserDefaults.standard.data(forKey: configKey),
           let config = try? JSONDecoder().decode(ChatConfig.self, from: data) {
            var normalizedConfig = normalize(config)
            clearLegacyBundledDefaultsIfNeeded(&normalizedConfig)
            if shouldReplacePlaceholderAPIURL(normalizedConfig.apiURL) {
                normalizedConfig.apiURL = normalizedBaseURL(bundleURL)
                if normalizedConfig.model.isEmpty
                    || normalizedConfig.model == ChatConfig.default.model
                    || normalizedConfig.model == "gpt-5.4"
                    || normalizedConfig.model == legacyDefaultModel {
                    normalizedConfig.model = bundleModel
                }
                save(normalizedConfig)
            }
            return normalize(normalizedConfig)
        }

        return ChatConfig(
            apiURL: normalizedBaseURL(bundleURL),
            apiKey: "",
            model: bundleModel,
            providerMode: ChatConfig.default.providerMode,
            providerAPIVersion: ChatConfig.default.providerAPIVersion,
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
            shellExecutionPath: ChatConfig.default.shellExecutionPath,
            shellExecutionAPIKey: ChatConfig.default.shellExecutionAPIKey,
            shellExecutionTimeout: ChatConfig.default.shellExecutionTimeout,
            shellExecutionWorkingDirectory: ChatConfig.default.shellExecutionWorkingDirectory,
            remotePythonExecutionEnabled: ChatConfig.default.remotePythonExecutionEnabled,
            remotePythonExecutionPath: ChatConfig.default.remotePythonExecutionPath,
            remotePythonExecutionAPIKey: ChatConfig.default.remotePythonExecutionAPIKey,
            remotePythonExecutionTimeout: ChatConfig.default.remotePythonExecutionTimeout,
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
            autoSkillActivationEnabled: ChatConfig.default.autoSkillActivationEnabled,
            soundEffectsEnabled: ChatConfig.default.soundEffectsEnabled,
            replySpeechPlaybackEnabled: ChatConfig.default.replySpeechPlaybackEnabled,
            replySpeechVoicePreset: ChatConfig.default.replySpeechVoicePreset,
            enabledBuiltinSkillIDs: ChatConfig.default.enabledBuiltinSkillIDs,
            customBuiltinSkillPrompts: ChatConfig.default.customBuiltinSkillPrompts
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

    private static func shouldReplacePlaceholderAPIURL(_ raw: String) -> Bool {
        let normalized = normalizedBaseURL(raw)
        return normalized.isEmpty
            || normalized == "https://xxx.com"
            || normalized == "http://xxx.com"
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
        let normalizedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
            return trimmed
        }
        if trimmed.isEmpty {
            guard !normalizedFallback.isEmpty else { return "" }
            if normalizedFallback.hasPrefix("/") {
                return normalizedFallback
            }
            return "/\(normalizedFallback)"
        }
        let base = trimmed
        if base.hasPrefix("/") {
            return base
        }
        return "/\(base)"
    }

    static func endpointURL(_ raw: String, path: String, fallback: String) -> String {
        let normalizedPath = normalizeEndpointPath(path, fallback: fallback)
        guard !normalizedPath.isEmpty else { return "" }
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
            ChatConfig.defaultModelsPath,
            ChatConfig.defaultShellExecutionPath
        ]
        .filter { !$0.isEmpty }
    }

    private static func normalize(_ config: ChatConfig) -> ChatConfig {
        let normalizedModel = migratedModelNameIfNeeded(config.model)
        let enabledSkillSet = Set(config.enabledBuiltinSkillIDs)
        let normalizedSkillIDs = BuiltinAISkill.allCases
            .map(\.rawValue)
            .filter { enabledSkillSet.contains($0) }
        let normalizedCustomSkillPrompts = config.customBuiltinSkillPrompts.reduce(into: [String: String]()) { partial, pair in
            let key = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard BuiltinAISkill(rawValue: key) != nil else { return }
            let value = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            partial[key] = value
        }
        return ChatConfig(
            apiURL: normalizedBaseURL(config.apiURL),
            apiKey: config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            model: normalizedModel.trimmingCharacters(in: .whitespacesAndNewlines),
            providerMode: config.providerMode,
            providerAPIVersion: config.providerAPIVersion.trimmingCharacters(in: .whitespacesAndNewlines),
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
            frontendAutoBuildEnabled: true,
            shellExecutionPath: ChatConfigStore.normalizeEndpointPath(
                config.shellExecutionPath,
                fallback: ChatConfig.defaultShellExecutionPath
            ),
            shellExecutionAPIKey: config.shellExecutionAPIKey.trimmingCharacters(in: .whitespacesAndNewlines),
            shellExecutionTimeout: min(max(config.shellExecutionTimeout, 5), 300),
            shellExecutionWorkingDirectory: config.shellExecutionWorkingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? ChatConfig.default.shellExecutionWorkingDirectory
                : config.shellExecutionWorkingDirectory.trimmingCharacters(in: .whitespacesAndNewlines),
            remotePythonExecutionEnabled: normalizedRemotePythonExecutionEnabled(config),
            remotePythonExecutionPath: normalizedRemotePythonExecutionPath(config),
            remotePythonExecutionAPIKey: config.remotePythonExecutionAPIKey.trimmingCharacters(in: .whitespacesAndNewlines),
            remotePythonExecutionTimeout: min(max(config.remotePythonExecutionTimeout, 10), 900),
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
            autoSkillActivationEnabled: config.autoSkillActivationEnabled,
            soundEffectsEnabled: config.soundEffectsEnabled,
            replySpeechPlaybackEnabled: config.replySpeechPlaybackEnabled,
            replySpeechVoicePreset: config.replySpeechVoicePreset,
            enabledBuiltinSkillIDs: normalizedSkillIDs,
            customBuiltinSkillPrompts: normalizedCustomSkillPrompts
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

    private static func clearLegacyBundledDefaultsIfNeeded(_ config: inout ChatConfig) {
        let hasAuth = !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !hasAuth,
           normalizedBaseURL(config.apiURL) == normalizedBaseURL(legacyBundledDefaultAPIURL) {
            config.apiURL = ""
        }

        if !hasAuth,
           config.model.trimmingCharacters(in: .whitespacesAndNewlines) == legacyBundledDefaultModel {
            config.model = ""
        }
    }

    private static func normalizedRemotePythonExecutionEnabled(_ config: ChatConfig) -> Bool {
        return config.remotePythonExecutionEnabled
    }

    private static func normalizedRemotePythonExecutionPath(_ config: ChatConfig) -> String {
        let configuredPath = config.remotePythonExecutionPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDefaultBase = normalizedBaseURL(ChatConfig.default.apiURL)
        let normalizedCurrentBase = normalizedBaseURL(config.apiURL)
        let remoteKey = config.remotePythonExecutionAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

        if configuredPath == ChatConfig.legacyAutoRemotePythonExecutionPath,
           normalizedCurrentBase != normalizedDefaultBase,
           remoteKey.isEmpty {
            return ""
        }

        return normalizeEndpointPath(
            configuredPath,
            fallback: ChatConfig.defaultRemotePythonExecutionPath
        )
    }
}
