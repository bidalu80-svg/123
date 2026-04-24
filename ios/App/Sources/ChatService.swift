import Foundation

struct ChatTokenUsage: Equatable {
    var inputTokens: Int
    var outputTokens: Int
    var cachedTokens: Int

    var totalTokens: Int {
        max(0, inputTokens + outputTokens)
    }
}

struct ChatReply: Equatable {
    var text: String
    var imageAttachments: [ChatImageAttachment] = []
    var videoAttachments: [ChatVideoAttachment] = []
    var usage: ChatTokenUsage? = nil
}

struct ChatRequestBuilder {
    private static let iexaIdentitySystemPrompt = """
    你是 IEXA，一款面向代码、终端和文件任务的智能助手。用户问你“你是谁/你叫什么”时，请明确回答你叫 IEXA。
    默认回答风格请接近 Open Minis / ChatGPT 的轻量 agent 体验：
    - 优先用用户当前语言回复，口吻自然、直接、专业，不要官话。
    - 默认短句输出，先给结论或动作，再补必要说明；不要长篇铺垫。
    - 没被要求详细展开时，控制在短段落内；不要强行列很多层级。
    - 代码、命令、路径、模块名必须使用代码格式。
    - 需要执行任务时，优先像 agent 一样表达：看起来像“已经在推进工作”，而不是空泛建议。
    - 如果回答里涉及文件、代码模块、命令、记忆、项目生成，请适当插入简短步骤日志，每行一句，便于 UI 渲染为工具卡片。
    - 步骤日志尽量使用这类短句：`回忆相关偏好`、`读取 src/main.swift`、`写入 index.html`、`运行 npm test`、`执行 shell 命令`。
    - 输出命令时给可直接执行的完整命令，尽量放在独立代码块中。
    - 输出多文件项目时，严格使用 `[[file:relative/path.ext]] ... [[endfile]]`。
    - 用户明确要求特定格式时，严格遵循用户要求。
    - 涉及实时资讯、统计数据、新闻或可争议事实时，在结尾补充“来源：”并给出 1-3 个可点击网址。
    """
    private static let frontendAutoBuildSystemPrompt = """
    你当前处于“项目自动生成模式（多语言）”。当用户让你创建项目、脚手架、代码仓库或多文件示例时，遵循以下规则：
    1) 优先输出完整可运行的项目文件，不要只给片段，不要写“省略”。
    2) 多文件输出时，默认使用如下格式（非常重要）：
       [[file:relative/path.ext]]
       <完整文件内容>
       [[endfile]]
    3) `relative/path.ext` 必须是相对路径，不要使用绝对路径，不要包含 `..`。
    4) 语言不限：可生成 Python、Java、Go、Rust、Node.js/TypeScript、Swift、C/C++、PHP、Shell、SQL、配置文件等。
    5) 若用户未指定技术栈，先做合理技术决策，给出最小可运行结构（含必要入口文件和配置）。
    6) 若用户明确要求网页/前端项目，继续按网页最佳实践输出（例如 `index.html`、`styles.css`、`script.js` 或框架结构）。
    7) 所有文件必须互相连通，导入/引用路径必须正确。
    8) 必须补齐可运行所需的构建与依赖文件（如 `package.json`、`requirements.txt`、`Cargo.toml`、`go.mod`、`CMakeLists.txt`、`pom.xml`、`build.gradle` 等）。
    9) 输出前可先给 2-5 行很短的步骤日志，示例：`创建项目目录`、`写入 src/main.rs`、`补齐 Cargo.toml`、`准备预览入口`。
    10) 除非用户明确要求解释，尽量以“极短说明 + 完整文件输出”为主。
    11) 不要说“先检查 AGENTS.md / 先扫仓库 / 调用工具后再做”；直接输出可落盘文件内容。
    """
    private static let strictCodeOnlySystemPrompt = """
    当用户明确提出“只输出代码、不输出解释、保持逻辑不变、自动修复格式”时，必须严格执行：
    1) 仅输出一个 markdown 代码块。
    2) 代码块外不允许出现任何字符（包括标题、解释、注释、列表、提示语）。
    3) 保持原逻辑不变，只修复缩进、括号、换行与格式问题。
    4) 不要补充额外功能、不要删减核心语句。
    """
    private static let maxHistoryMessages = 22
    private static let maxHistoryCharacters = 42_000
    private static let maxSingleHistoryMessageChars = 7_000
    private static let maxHistoryFilePreviewChars = 2_400
    private static let keepInlineImageHistoryDepth = 1

    static func makeRequest(
        config: ChatConfig,
        history: [ChatMessage],
        message: ChatMessage,
        realtimeSystemContext: String? = nil,
        memorySystemContext: String? = nil
    ) throws -> URLRequest {
        let completionURL = config.chatCompletionsURLString
        guard let url = URL(string: completionURL), !completionURL.isEmpty else {
            throw ChatServiceError.invalidURL
        }

        var request = URLRequest(url: url, timeoutInterval: config.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let trimmedAPIKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAPIKey.isEmpty {
            request.setValue("Bearer \(trimmedAPIKey)", forHTTPHeaderField: "Authorization")
        }

        let normalizedMessages = buildMessagesWithIdentity(
            history: history,
            message: message,
            realtimeSystemContext: realtimeSystemContext,
            memorySystemContext: memorySystemContext,
            frontendAutoBuildEnabled: true,
            enabledBuiltinSkillIDs: config.enabledBuiltinSkillIDs,
            customBuiltinSkillPrompts: config.customBuiltinSkillPrompts
        )

        let payload: [String: Any] = [
            "model": config.model,
            "messages": normalizedMessages,
            "stream": config.streamEnabled
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    private static func buildMessagesWithIdentity(
        history: [ChatMessage],
        message: ChatMessage,
        realtimeSystemContext: String?,
        memorySystemContext: String?,
        frontendAutoBuildEnabled: Bool,
        enabledBuiltinSkillIDs: [String],
        customBuiltinSkillPrompts: [String: String]
    ) -> [[String: Any]] {
        let hasSystemMessage = history.contains { $0.role == .system } || message.role == .system
        var prefix: [[String: Any]] = []
        if !hasSystemMessage {
            prefix.append([
                "role": "system",
                "content": iexaIdentitySystemPrompt
            ])
        }

        let trimmedRealtimeContext = realtimeSystemContext?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedRealtimeContext.isEmpty {
            prefix.append([
                "role": "system",
                "content": trimmedRealtimeContext
            ])
        }

        let trimmedMemoryContext = memorySystemContext?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedMemoryContext.isEmpty {
            prefix.append([
                "role": "system",
                "content": trimmedMemoryContext
            ])
        }

        if shouldInjectFrontendAutoBuildPrompt(
            enabled: frontendAutoBuildEnabled,
            message: message,
            history: history
        ) {
            prefix.append([
                "role": "system",
                "content": frontendAutoBuildSystemPrompt
            ])
        }

        if shouldInjectStrictCodeOnlyPrompt(message: message) {
            prefix.append([
                "role": "system",
                "content": strictCodeOnlySystemPrompt
            ])
        }

        for skill in enabledBuiltinSkills(from: enabledBuiltinSkillIDs) {
            guard shouldInjectBuiltinSkillPrompt(skill: skill, userMessage: message) else {
                continue
            }
            let content = resolvedSkillPrompt(
                for: skill,
                customBuiltinSkillPrompts: customBuiltinSkillPrompts
            )
            prefix.append([
                "role": "system",
                "content": content
            ])
        }

        let compactHistory = compactHistoryForRequest(history)
        return prefix + compactHistory.map(\.apiPayload) + [message.apiPayload]
    }

    private static func enabledBuiltinSkills(from ids: [String]) -> [BuiltinAISkill] {
        let enabled = Set(ids)
        return BuiltinAISkill.allCases.filter { enabled.contains($0.rawValue) }
    }

    private static func shouldInjectBuiltinSkillPrompt(
        skill: BuiltinAISkill,
        userMessage: ChatMessage
    ) -> Bool {
        guard userMessage.role == .user else { return false }

        let text = userMessage.copyableText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .lowercased()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }

        switch skill {
        case .skillCreator:
            let markers = [
                "skill", "sikll", "skil", "skill.md", "skills/", "skill-creator",
                "builtin skill", "built-in skill", "skill creator",
                "内置skill", "内置 skill", "内置技能",
                "技能", "技能创建", "技能模板", "创建 skill", "更新 skill", "创建技能", "更新技能"
            ]
            return markers.contains(where: { text.contains($0) })
        }
    }

    private static func resolvedSkillPrompt(
        for skill: BuiltinAISkill,
        customBuiltinSkillPrompts: [String: String]
    ) -> String {
        if let custom = customBuiltinSkillPrompts[skill.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        return skill.defaultPrompt
    }

    private static func shouldInjectFrontendAutoBuildPrompt(
        enabled: Bool,
        message: ChatMessage,
        history: [ChatMessage]
    ) -> Bool {
        guard enabled else { return false }
        guard message.role == .user else { return false }

        let raw = message.copyableText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !raw.isEmpty else { return false }
        if containsNoFileDirective(raw) { return false }

        let intentMarkers = [
            "生成项目",
            "创建项目",
            "项目结构",
            "工程结构",
            "完整项目",
            "完整工程",
            "搭建项目",
            "初始化项目",
            "初始化工程",
            "脚手架",
            "仓库结构",
            "目录结构",
            "模块划分",
            "多文件",
            "多模块",
            "生成代码文件",
            "输出文件结构",
            "按[[file:",
            "写入latest",
            "自动落盘",
            "服务端项目",
            "后端项目",
            "api项目",
            "命令行工具",
            "cli工具",
            "sdk项目",
            "库项目",
            "project",
            "codebase",
            "scaffold",
            "boilerplate",
            "starter template",
            "multi module",
            "repository structure",
            "directory structure",
            "backend project",
            "api service",
            "cli project",
            "library project",
            "sdk project",
            "generate project",
            "create project",
            "build project",
            "multi-file",
            "repo structure"
        ]
        if intentMarkers.contains(where: { raw.contains($0) }) {
            return true
        }

        if containsLanguageProjectIntent(raw) {
            return true
        }

        if raw.range(
            of: #"(做|写|搭|建|生成|创建|开发|搞|初始化)(一个|个|套)?[^\n]{0,28}(网站|网页|页面|项目|前端|应用|app|demo|登录页|注册页|后台|管理系统|小程序|服务|接口|api|后端|脚手架|命令行|cli|工具|sdk|库|package|模块|机器人|爬虫|微服务)"#,
            options: .regularExpression
        ) != nil {
            return true
        }

        if raw.range(
            of: #"(网站|网页|页面|项目|前端|应用|app|demo|登录页|注册页|后台|管理系统|小程序|服务|接口|api|后端|脚手架|命令行|cli|工具|sdk|库|package|模块|机器人|爬虫|微服务)[^\n]{0,20}(做|写|搭|建|生成|创建|开发|搞|初始化)"#,
            options: .regularExpression
        ) != nil {
            return true
        }

        if recentConversationContainsProjectContext(history: history),
           looksLikeProjectFollowupEdit(raw) {
            return true
        }

        return false
    }

    private static func recentConversationContainsProjectContext(history: [ChatMessage]) -> Bool {
        guard !history.isEmpty else { return false }
        var inspected = 0
        for message in history.reversed() {
            guard message.role == .assistant else { continue }
            inspected += 1
            if FrontendProjectBuilder.canGenerateProject(from: message) {
                return true
            }
            if inspected >= 6 {
                break
            }
        }
        return false
    }

    private static func looksLikeProjectFollowupEdit(_ raw: String) -> Bool {
        let followupMarkers = [
            "继续改", "继续修改", "继续完善", "继续优化", "继续修复",
            "再改", "再修", "再优化", "再调整", "改一下", "修一下",
            "优化一下", "调整一下", "完善一下", "重构一下", "补一下",
            "把这个", "这个排版", "这个样式", "这个报错", "这个问题",
            "continue", "modify", "update", "refine", "improve", "fix",
            "polish", "adjust", "tweak", "iterate", "revise"
        ]
        if followupMarkers.contains(where: { raw.contains($0) }) {
            return true
        }

        if raw.range(
            of: #"(继续|再|然后|接着|顺便|把).{0,12}(改|修改|修复|优化|完善|调整|重构|补充|增加|删除)"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        if raw.range(
            of: #"(fix|update|modify|improve|refactor|adjust|tweak).{0,20}(project|code|layout|style|ui|bug|error|file)"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        return false
    }

    private static func containsLanguageProjectIntent(_ raw: String) -> Bool {
        let cnLanguages = [
            "python", "py", "java", "kotlin", "swift", "go", "golang", "rust",
            "c#", "csharp", "c++", "cpp", "c语言", "node", "nodejs", "typescript",
            "javascript", "js", "php", "ruby", "scala", "dart", "lua", "sql"
        ]
        let cnProjectNouns = [
            "项目", "工程", "脚手架", "模板", "服务", "后端", "接口", "api",
            "命令行", "cli", "工具", "sdk", "库", "模块", "包", "微服务", "机器人", "爬虫"
        ]

        for language in cnLanguages {
            for noun in cnProjectNouns {
                if raw.contains("\(language)\(noun)") || raw.contains("\(noun)\(language)") {
                    return true
                }
            }
        }

        if raw.range(
            of: #"\b(rust|go|golang|java|kotlin|swift|python|php|ruby|scala|dart|lua|typescript|javascript|node|nodejs|csharp|c#|cpp|c\+\+)\b[^\n]{0,24}\b(project|service|backend|api|cli|tool|sdk|library|package|scaffold|template|boilerplate)\b"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        if raw.range(
            of: #"\b(project|service|backend|api|cli|tool|sdk|library|package|scaffold|template|boilerplate)\b[^\n]{0,24}\b(rust|go|golang|java|kotlin|swift|python|php|ruby|scala|dart|lua|typescript|javascript|node|nodejs|csharp|c#|cpp|c\+\+)\b"#,
            options: .regularExpression
        ) != nil {
            return true
        }

        return false
    }

    private static func containsNoFileDirective(_ raw: String) -> Bool {
        let directiveMarkers = [
            "不做成文件",
            "不要做成文件",
            "别做成文件",
            "不要生成文件",
            "别生成文件",
            "不生成文件",
            "不要落盘",
            "别落盘",
            "不落盘",
            "不要写入文件",
            "不要写入latest",
            "只要代码",
            "仅要代码",
            "仅展示代码",
            "只展示代码",
            "不要项目",
            "别做项目",
            "不创建项目",
            "不用项目结构",
            "do not create file",
            "do not create files",
            "don't create file",
            "don't create files",
            "do not write file",
            "do not write files",
            "don't write file",
            "don't write files",
            "inline code only",
            "just show code",
            "code only",
            "single snippet",
            "no files"
        ]

        return directiveMarkers.contains { raw.contains($0) }
    }

    private static func shouldInjectStrictCodeOnlyPrompt(message: ChatMessage) -> Bool {
        guard message.role == .user else { return false }
        let raw = message.copyableText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !raw.isEmpty else { return false }

        let markers = [
            "只输出代码",
            "不要输出任何文字",
            "保持原逻辑不变",
            "自动修复缩进",
            "确保全部内容都在同一个代码块",
            "如果输出了代码块之外",
            "only code",
            "single code block",
            "no explanation",
            "keep logic unchanged",
            "fix indentation",
            "outside code block"
        ]
        let matched = markers.reduce(into: 0) { partial, marker in
            if raw.contains(marker) {
                partial += 1
            }
        }
        return matched >= 2
    }

    private static func compactHistoryForRequest(_ history: [ChatMessage]) -> [ChatMessage] {
        guard !history.isEmpty else { return [] }

        var selected: [ChatMessage] = []
        var budget = 0
        var keptInlineImageMessages = 0

        for original in history.reversed() {
            let allowInlineImageData = keptInlineImageMessages < keepInlineImageHistoryDepth
            let compact = compactHistoryMessage(original, allowInlineImageData: allowInlineImageData)
            let weight = historyWeight(compact)
            let reachesLimit = selected.count >= maxHistoryMessages || (budget + weight > maxHistoryCharacters)
            if !selected.isEmpty && reachesLimit {
                break
            }

            selected.append(compact)
            budget += weight
            if compact.imageAttachments.contains(where: { $0.requestURLString.hasPrefix("data:") }) {
                keptInlineImageMessages += 1
            }
        }

        return Array(selected.reversed())
    }

    private static func compactHistoryMessage(_ message: ChatMessage, allowInlineImageData: Bool) -> ChatMessage {
        var compact = message
        compact.content = compactTextForHistory(compact.content)

        if compact.fileAttachments.count > 2 {
            compact.fileAttachments = Array(compact.fileAttachments.prefix(2))
            compact.content = appendHistoryHint(
                compact.content,
                hint: "[历史附件较多，已仅保留最近 2 个附件内容以提升响应速度。]"
            )
        }
        compact.fileAttachments = compact.fileAttachments.map { file in
            var clipped = file
            if clipped.textContent.count > maxHistoryFilePreviewChars {
                clipped.textContent = String(clipped.textContent.prefix(maxHistoryFilePreviewChars))
                    + "\n\n[历史附件内容已截断]"
            }
            clipped.binaryBase64 = nil
            return clipped
        }

        let inlineDataImages = compact.imageAttachments.filter { $0.requestURLString.hasPrefix("data:") }
        if !allowInlineImageData && !inlineDataImages.isEmpty {
            compact.imageAttachments.removeAll { $0.requestURLString.hasPrefix("data:") }
            compact.content = appendHistoryHint(
                compact.content,
                hint: "[历史消息含 \(inlineDataImages.count) 张本地图片，本轮为提速已省略其二进制内容。]"
            )
        }

        return compact
    }

    private static func compactTextForHistory(_ raw: String) -> String {
        if raw.count <= maxSingleHistoryMessageChars {
            return raw
        }
        return String(raw.prefix(maxSingleHistoryMessageChars)) + "\n\n[历史文本已截断]"
    }

    private static func appendHistoryHint(_ content: String, hint: String) -> String {
        if content.contains(hint) {
            return content
        }
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return hint
        }
        return content + "\n\n" + hint
    }

    private static func historyWeight(_ message: ChatMessage) -> Int {
        let textWeight = min(message.content.count, maxSingleHistoryMessageChars)
        let fileWeight = message.fileAttachments.reduce(0) { partial, file in
            partial + min(file.textContent.count, maxHistoryFilePreviewChars)
        }
        let imageWeight = message.imageAttachments.count * 640
        let videoWeight = message.videoAttachments.count * 760
        return textWeight + fileWeight + imageWeight + videoWeight + 180
    }

    static func makeResponsesRequest(
        config: ChatConfig,
        history: [ChatMessage],
        message: ChatMessage,
        realtimeSystemContext: String? = nil,
        memorySystemContext: String? = nil,
        stream: Bool? = nil
    ) throws -> URLRequest {
        let endpoint = config.responsesURLString
        guard let url = URL(string: endpoint), !endpoint.isEmpty else {
            throw ChatServiceError.invalidURL
        }

        var request = URLRequest(url: url, timeoutInterval: config.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let trimmedAPIKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAPIKey.isEmpty {
            request.setValue("Bearer \(trimmedAPIKey)", forHTTPHeaderField: "Authorization")
        }

        let normalizedMessages = buildMessagesWithIdentity(
            history: history,
            message: message,
            realtimeSystemContext: realtimeSystemContext,
            memorySystemContext: memorySystemContext,
            frontendAutoBuildEnabled: true,
            enabledBuiltinSkillIDs: config.enabledBuiltinSkillIDs,
            customBuiltinSkillPrompts: config.customBuiltinSkillPrompts
        )

        let shouldStream = stream ?? config.streamEnabled
        let payload: [String: Any] = [
            "model": config.model,
            "input": makeResponsesInput(from: normalizedMessages),
            "stream": shouldStream
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    private static func makeResponsesInput(from messages: [[String: Any]]) -> [[String: Any]] {
        var input: [[String: Any]] = []

        for message in messages {
            let rawRole = (message["role"] as? String ?? "user").lowercased()
            // Responses API commonly uses developer/user/assistant roles.
            let role: String = rawRole == "system" ? "developer" : rawRole
            let normalizedContent = makeResponsesContent(from: message["content"])
            guard !normalizedContent.isEmpty else { continue }
            input.append([
                "role": role,
                "content": normalizedContent
            ])
        }

        return input
    }

    private static func makeResponsesContent(from rawContent: Any?) -> [[String: Any]] {
        guard let rawContent else { return [] }

        if let text = rawContent as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            return [[
                "type": "input_text",
                "text": trimmed
            ]]
        }

        guard let rows = rawContent as? [[String: Any]] else { return [] }

        var result: [[String: Any]] = []
        result.reserveCapacity(rows.count)

        for row in rows {
            let type = (row["type"] as? String ?? "").lowercased()
            if type == "text" || type == "input_text" || type == "output_text" {
                if let text = row["text"] as? String,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append([
                        "type": "input_text",
                        "text": text
                    ])
                }
                continue
            }

            if type == "image_url" || type == "input_image" || type == "output_image" {
                let imageURL: String?
                if let value = row["image_url"] as? String {
                    imageURL = value
                } else if let dict = row["image_url"] as? [String: Any] {
                    imageURL = dict["url"] as? String
                } else {
                    imageURL = row["url"] as? String
                }

                if let imageURL,
                   !imageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append([
                        "type": "input_image",
                        "image_url": imageURL
                    ])
                }
            }
        }

        return result
    }

    static func makeModelsRequest(config: ChatConfig) throws -> URLRequest {
        let modelsURL = config.modelsURLString
        guard let url = URL(string: modelsURL), !modelsURL.isEmpty else {
            throw ChatServiceError.invalidURL
        }

        var request = URLRequest(url: url, timeoutInterval: config.timeout)
        request.httpMethod = "GET"

        let trimmedAPIKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAPIKey.isEmpty {
            request.setValue("Bearer \(trimmedAPIKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    static func makeImagesGenerationRequest(
        config: ChatConfig,
        prompt: String,
        forceMinimalPayload: Bool = false
    ) throws -> URLRequest {
        let endpoint = config.imagesGenerationsURLString
        guard let url = URL(string: endpoint), !endpoint.isEmpty else {
            throw ChatServiceError.invalidURL
        }

        var request = URLRequest(url: url, timeoutInterval: config.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let trimmedAPIKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAPIKey.isEmpty {
            request.setValue("Bearer \(trimmedAPIKey)", forHTTPHeaderField: "Authorization")
        }

        let payload = makeImageGenerationPayload(
            config: config,
            prompt: prompt,
            forceMinimalPayload: forceMinimalPayload
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    static func makeVideoGenerationRequest(config: ChatConfig, prompt: String) throws -> URLRequest {
        let endpoint = config.videoGenerationsURLString
        guard let url = URL(string: endpoint), !endpoint.isEmpty else {
            throw ChatServiceError.invalidURL
        }

        var request = URLRequest(url: url, timeoutInterval: max(config.timeout, 120))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let trimmedAPIKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAPIKey.isEmpty {
            request.setValue("Bearer \(trimmedAPIKey)", forHTTPHeaderField: "Authorization")
        }

        let payload = makeVideoGenerationPayload(config: config, prompt: prompt)
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    static func makeEmbeddingsRequest(config: ChatConfig, input: String) throws -> URLRequest {
        let endpoint = config.embeddingsURLString
        guard let url = URL(string: endpoint), !endpoint.isEmpty else {
            throw ChatServiceError.invalidURL
        }

        var request = URLRequest(url: url, timeoutInterval: config.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let trimmedAPIKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAPIKey.isEmpty {
            request.setValue("Bearer \(trimmedAPIKey)", forHTTPHeaderField: "Authorization")
        }

        let payload: [String: Any] = [
            "model": config.model,
            "input": input
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    static func makeAudioTranscriptionsRequest(
        config: ChatConfig,
        fileName: String,
        mimeType: String,
        fileData: Data,
        prompt: String?
    ) throws -> URLRequest {
        let endpoint = config.audioTranscriptionsURLString
        guard let url = URL(string: endpoint), !endpoint.isEmpty else {
            throw ChatServiceError.invalidURL
        }

        let boundary = "----ChatAppBoundary\(UUID().uuidString)"
        var request = URLRequest(url: url, timeoutInterval: max(config.timeout, 120))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let trimmedAPIKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAPIKey.isEmpty {
            request.setValue("Bearer \(trimmedAPIKey)", forHTTPHeaderField: "Authorization")
        }

        var body = Data()

        appendMultipartField(name: "model", value: config.model, boundary: boundary, to: &body)
        if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendMultipartField(name: "prompt", value: prompt, boundary: boundary, to: &body)
        }

        body.append("--\(boundary)\r\n".data(using: .utf8) ?? Data())
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8) ?? Data())
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8) ?? Data())
        body.append(fileData)
        body.append("\r\n".data(using: .utf8) ?? Data())
        body.append("--\(boundary)--\r\n".data(using: .utf8) ?? Data())

        request.httpBody = body
        return request
    }

    private static func appendMultipartField(name: String, value: String, boundary: String, to body: inout Data) {
        body.append("--\(boundary)\r\n".data(using: .utf8) ?? Data())
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8) ?? Data())
        body.append("\(value)\r\n".data(using: .utf8) ?? Data())
    }

    private static func makeImageGenerationPayload(
        config: ChatConfig,
        prompt: String,
        forceMinimalPayload: Bool
    ) -> [String: Any] {
        let size = config.imageGenerationSize.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ChatConfig.default.imageGenerationSize
            : config.imageGenerationSize.trimmingCharacters(in: .whitespacesAndNewlines)
        let loweredModel = config.model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // xAI grok-imagine uses aspect_ratio / resolution and can fail on OpenAI-only `size`.
        let usesXAIShape = loweredModel.contains("grok-imagine") || loweredModel.contains("grok-image")
        if usesXAIShape {
            var payload: [String: Any] = [
                "model": config.model,
                "prompt": prompt,
                "n": 1
            ]
            if let aspectRatio = normalizedAspectRatio(from: size) {
                payload["aspect_ratio"] = aspectRatio
            }
            if let resolution = normalizedResolution(from: size) {
                payload["resolution"] = resolution
            }
            return payload
        }

        if forceMinimalPayload {
            return [
                "model": config.model,
                "prompt": prompt
            ]
        }

        return [
            "model": config.model,
            "prompt": prompt,
            "size": size,
            "n": 1
        ]
    }

    private static func makeVideoGenerationPayload(config: ChatConfig, prompt: String) -> [String: Any] {
        var payload: [String: Any] = [
            "model": config.model,
            "prompt": prompt
        ]

        let loweredModel = config.model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Better compatibility with OpenAI-compatible gateways that expect this hint.
        if loweredModel.contains("qwen") || loweredModel.contains("video") {
            payload["n"] = 1
            payload["response_format"] = "url"
        }
        return payload
    }

    private static func normalizedAspectRatio(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed: Set<String> = ["1:1", "16:9", "9:16", "4:3", "3:4", "3:2", "2:3"]
        if allowed.contains(trimmed) { return trimmed }

        guard let (width, height) = parseWidthHeight(from: trimmed) else { return nil }
        let divisor = greatestCommonDivisor(width, height)
        let reduced = "\(width / divisor):\(height / divisor)"
        return allowed.contains(reduced) ? reduced : nil
    }

    private static func normalizedResolution(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed == "1k" || trimmed == "2k" { return trimmed }
        guard let (width, height) = parseWidthHeight(from: trimmed) else { return nil }
        return max(width, height) > 1024 ? "2k" : "1k"
    }

    private static func parseWidthHeight(from raw: String) -> (Int, Int)? {
        var normalized = raw
            .replacingOccurrences(of: "×", with: "x")
            .replacingOccurrences(of: "*", with: "x")
            .replacingOccurrences(of: " ", with: "")

        if normalized.hasPrefix("size=") {
            normalized = String(normalized.dropFirst("size=".count))
        }

        let parts = normalized.split(separator: "x", omittingEmptySubsequences: true)
        guard parts.count == 2,
              let width = Int(parts[0]),
              let height = Int(parts[1]),
              width > 0,
              height > 0 else {
            return nil
        }
        return (width, height)
    }

    private static func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var x = abs(a)
        var y = abs(b)
        while y != 0 {
            let remainder = x % y
            x = y
            y = remainder
        }
        return max(x, 1)
    }
}

enum ChatServiceError: LocalizedError, Equatable {
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case noData
    case invalidInput(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "API 地址无效，请检查配置。"
        case .invalidResponse:
            return "服务器返回了无法识别的响应。"
        case .httpError(let statusCode):
            return "请求失败，HTTP 状态码：\(statusCode)。"
        case .noData:
            return "服务器没有返回可用数据。"
        case .invalidInput(let reason):
            return reason
        case .unsupported(let reason):
            return reason
        }
    }
}

final class ChatService {
    private let session: URLSession
    private let realtimeContextProvider: RealtimeContextProvider
    private let memoryStore: ConversationMemoryStore

    init(
        session: URLSession? = nil,
        realtimeContextProvider: RealtimeContextProvider = RealtimeContextProvider(),
        memoryStore: ConversationMemoryStore = ConversationMemoryStore()
    ) {
        self.realtimeContextProvider = realtimeContextProvider
        self.memoryStore = memoryStore

        if let session {
            self.session = session
            return
        }

        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.allowsConstrainedNetworkAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    func prewarmRealtimeContext(config: ChatConfig) async {
        await realtimeContextProvider.prewarm(config: config)
    }

    func sendMessage(
        config: ChatConfig,
        history: [ChatMessage],
        message: ChatMessage,
        onEvent: @escaping @Sendable (StreamChunk) -> Void
    ) async throws -> ChatReply {
        switch config.endpointMode {
        case .chatCompletions:
            return try await sendChatCompletions(
                config: config,
                history: history,
                message: message,
                onEvent: onEvent
            )
        case .responses:
            return try await sendResponses(
                config: config,
                history: history,
                message: message,
                onEvent: onEvent
            )
        case .imageGenerations:
            return try await sendImageGeneration(
                config: config,
                message: message,
                onEvent: onEvent
            )
        case .videoGenerations:
            return try await sendVideoGeneration(
                config: config,
                message: message,
                onEvent: onEvent
            )
        case .embeddings:
            return try await sendEmbeddings(
                config: config,
                message: message,
                onEvent: onEvent
            )
        case .models:
            let models = try await fetchModels(config: config)
            let text = modelsText(models)
            onEvent(StreamChunk(rawLine: "", deltaText: text, imageURLs: [], isDone: false))
            return ChatReply(text: text, imageAttachments: [])
        case .audioTranscriptions:
            return try await sendAudioTranscriptions(
                config: config,
                message: message,
                onEvent: onEvent
            )
        }
    }

    private func sendResponses(
        config: ChatConfig,
        history: [ChatMessage],
        message: ChatMessage,
        onEvent: @escaping @Sendable (StreamChunk) -> Void
    ) async throws -> ChatReply {
        let memoryContext: String?
        if config.memoryModeEnabled {
            await memoryStore.remember(message)
            memoryContext = await memoryStore.buildSystemContext()
        } else {
            memoryContext = nil
        }

        let realtimeContext = await realtimeContextProvider.buildSystemContext(
            config: config,
            userPrompt: message.copyableText
        )

        if config.streamEnabled {
            do {
                return try await sendResponsesStreaming(
                    config: config,
                    history: history,
                    message: message,
                    realtimeSystemContext: realtimeContext,
                    memorySystemContext: memoryContext,
                    onEvent: onEvent
                )
            } catch {
                if shouldFallbackResponsesStreamError(error) {
                    return try await sendResponsesNonStreaming(
                        config: config,
                        history: history,
                        message: message,
                        realtimeSystemContext: realtimeContext,
                        memorySystemContext: memoryContext,
                        onEvent: onEvent
                    )
                }
                throw error
            }
        }

        return try await sendResponsesNonStreaming(
            config: config,
            history: history,
            message: message,
            realtimeSystemContext: realtimeContext,
            memorySystemContext: memoryContext,
            onEvent: onEvent
        )
    }

    private func sendResponsesStreaming(
        config: ChatConfig,
        history: [ChatMessage],
        message: ChatMessage,
        realtimeSystemContext: String?,
        memorySystemContext: String?,
        onEvent: @escaping @Sendable (StreamChunk) -> Void
    ) async throws -> ChatReply {
        var request = try ChatRequestBuilder.makeResponsesRequest(
            config: config,
            history: history,
            message: message,
            realtimeSystemContext: realtimeSystemContext,
            memorySystemContext: memorySystemContext,
            stream: true
        )
        request.timeoutInterval = max(config.timeout, 90)

        return try await withRetry(maxRetries: 3) { [self] in
            let (bytes, response) = try await session.bytes(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ChatServiceError.invalidResponse
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                if httpResponse.statusCode == 404 {
                    throw ChatServiceError.invalidInput("当前站点未提供 /v1/responses 接口（404）。请切回聊天模式或确认网关支持 Responses API。")
                }
                throw ChatServiceError.httpError(httpResponse.statusCode)
            }

            var fullReplyParts: [String] = []
            var imageURLs = Set<String>()
            var videoURLStrings = Set<String>()
            var citationURLs = Set<String>()
            var pendingDeltaParts: [String] = []
            var pendingDeltaCharacters = 0
            var pendingImageURLs = Set<String>()
            var thinkTagFilter = ThinkTagStreamFilter()
            var accumulatedResponseText = ""
            var latestUsage: ChatTokenUsage?
            var lastEmitAt = Date.distantPast
            let streamEmitInterval: TimeInterval = 0.030
            let streamForceEmitCharacterThreshold = 96

            func emitPending(force: Bool = false) {
                guard pendingDeltaCharacters > 0 || !pendingImageURLs.isEmpty else { return }
                let now = Date()
                let shouldForceBySize = pendingDeltaCharacters >= streamForceEmitCharacterThreshold
                if !force && !shouldForceBySize && now.timeIntervalSince(lastEmitAt) < streamEmitInterval {
                    return
                }
                let pendingDeltaText = pendingDeltaParts.joined()
                onEvent(
                    StreamChunk(
                        rawLine: "",
                        deltaText: pendingDeltaText,
                        imageURLs: Array(pendingImageURLs),
                        isDone: false
                    )
                )
                pendingDeltaParts.removeAll(keepingCapacity: true)
                pendingDeltaCharacters = 0
                pendingImageURLs.removeAll()
                lastEmitAt = now
            }

            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard let chunk = StreamParser.parse(line: line) else { continue }
                if chunk.isDone { break }

                let parsedCitationURLs = StreamParser.extractCitationURLs(line: line)
                if !parsedCitationURLs.isEmpty {
                    parsedCitationURLs.forEach { citationURLs.insert($0) }
                }

                if !chunk.deltaText.isEmpty {
                    let filtered = thinkTagFilter.filter(chunk.deltaText)
                    let sanitized = sanitizeStreamingAssistantText(filtered)
                    if !sanitized.isEmpty {
                        let incremental = incrementalStreamingTextDelta(
                            existing: accumulatedResponseText,
                            incoming: sanitized
                        )
                        if !incremental.isEmpty {
                            accumulatedResponseText += incremental
                            fullReplyParts.append(incremental)
                            pendingDeltaParts.append(incremental)
                            pendingDeltaCharacters += incremental.count
                        }
                    }
                }

                if !chunk.imageURLs.isEmpty {
                    chunk.imageURLs.forEach { imageURLs.insert($0) }
                    chunk.imageURLs.forEach { pendingImageURLs.insert($0) }
                }

                if let eventObject = parseJSONObjectFromSSELine(line) {
                    if let usage = extractTokenUsage(from: eventObject) {
                        latestUsage = usage
                    }
                    let videos = extractVideoAttachments(from: eventObject, baseURL: config.normalizedBaseURL)
                    if !videos.isEmpty {
                        videos.forEach { videoURLStrings.insert($0.requestURLString) }
                    }
                }

                emitPending()
            }

            let trailingFiltered = thinkTagFilter.finalize()
            let trailingSanitized = sanitizeStreamingAssistantText(trailingFiltered)
            if !trailingSanitized.isEmpty {
                let incremental = incrementalStreamingTextDelta(
                    existing: accumulatedResponseText,
                    incoming: trailingSanitized
                )
                if !incremental.isEmpty {
                    accumulatedResponseText += incremental
                    fullReplyParts.append(incremental)
                    pendingDeltaParts.append(incremental)
                    pendingDeltaCharacters += incremental.count
                }
            }
            emitPending(force: true)

            let fullReply = fullReplyParts.joined()
            let cleanedText = ResponseCleaner.cleanAssistantText(fullReply)
            let mergedText = mergeTextWithCitationURLs(cleanedText, citationURLs: Array(citationURLs))
            let images = deduplicateImages(
                imageURLs.map { ChatImageAttachment(dataURL: $0, mimeType: "image/*", remoteURL: $0) }
            )
            let videos = deduplicateVideos(
                videoURLStrings.map {
                    ChatVideoAttachment(
                        remoteURL: $0,
                        mimeType: normalizedVideoMimeType(urlString: $0, preferred: nil)
                    )
                }
            )

            if mergedText.isEmpty && images.isEmpty && videos.isEmpty {
                throw ChatServiceError.noData
            }

            return ChatReply(text: mergedText, imageAttachments: images, videoAttachments: videos, usage: latestUsage)
        }
    }

    private func sendResponsesNonStreaming(
        config: ChatConfig,
        history: [ChatMessage],
        message: ChatMessage,
        realtimeSystemContext: String?,
        memorySystemContext: String?,
        onEvent: @escaping @Sendable (StreamChunk) -> Void
    ) async throws -> ChatReply {
        let request = try ChatRequestBuilder.makeResponsesRequest(
            config: config,
            history: history,
            message: message,
            realtimeSystemContext: realtimeSystemContext,
            memorySystemContext: memorySystemContext,
            stream: false
        )

        let (data, response) = try await withRetry { [self] in
            try await session.data(for: request)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChatServiceError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 404 {
                throw ChatServiceError.invalidInput("当前站点未提供 /v1/responses 接口（404）。请切回聊天模式或确认网关支持 Responses API。")
            }
            throw ChatServiceError.httpError(httpResponse.statusCode)
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatServiceError.noData
        }

        let parsed = StreamParser.extractPayload(from: object)
        let citationURLs = StreamParser.extractCitationURLs(from: object)
        let cleanedText = ResponseCleaner.cleanAssistantText(parsed.text)
        let mergedText = mergeTextWithCitationURLs(cleanedText, citationURLs: citationURLs)
        let usage = extractTokenUsage(from: object)
        let images = deduplicateImages(
            parsed.imageURLs.map { ChatImageAttachment(dataURL: $0, mimeType: "image/*", remoteURL: $0) }
        )
        let videos = deduplicateVideos(extractVideoAttachments(from: object, baseURL: config.normalizedBaseURL))

        if mergedText.isEmpty && images.isEmpty && videos.isEmpty {
            throw ChatServiceError.noData
        }

        onEvent(StreamChunk(rawLine: "", deltaText: mergedText, imageURLs: images.map(\.requestURLString), isDone: false))
        return ChatReply(text: mergedText, imageAttachments: images, videoAttachments: videos, usage: usage)
    }

    private func shouldFallbackResponsesStreamError(_ error: Error) -> Bool {
        if isStreamingTransportError(error) {
            return true
        }

        guard let serviceError = error as? ChatServiceError else { return false }
        switch serviceError {
        case .httpError(let code):
            return [400, 404, 405, 408, 415, 422, 425, 429, 500, 502, 503, 504].contains(code)
        case .invalidResponse, .noData:
            return true
        case .invalidInput(let reason):
            return reason.contains("/v1/responses")
        case .invalidURL, .unsupported:
            return false
        }
    }

    private func shouldFallbackChatCompletionsStreamError(_ error: Error) -> Bool {
        if isStreamingTransportError(error) {
            return true
        }

        guard let serviceError = error as? ChatServiceError else { return false }
        switch serviceError {
        case .httpError(let code):
            return [408, 425, 429, 500, 502, 503, 504].contains(code)
        case .invalidResponse, .noData:
            return true
        case .invalidURL, .invalidInput, .unsupported:
            return false
        }
    }

    private func isStreamingTransportError(_ error: Error) -> Bool {
        if error is CancellationError {
            return false
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut,
                 .networkConnectionLost,
                 .notConnectedToInternet,
                 .cannotFindHost,
                 .cannotConnectToHost,
                 .dnsLookupFailed,
                 .resourceUnavailable,
                 .internationalRoamingOff:
                return true
            default:
                return false
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            let code = URLError.Code(rawValue: nsError.code)
            switch code {
            case .timedOut,
                 .networkConnectionLost,
                 .notConnectedToInternet,
                 .cannotFindHost,
                 .cannotConnectToHost,
                 .dnsLookupFailed,
                 .resourceUnavailable,
                 .internationalRoamingOff:
                return true
            default:
                break
            }
        }

        return false
    }

    private func sendChatCompletions(
        config: ChatConfig,
        history: [ChatMessage],
        message: ChatMessage,
        onEvent: @escaping @Sendable (StreamChunk) -> Void
    ) async throws -> ChatReply {
        let memoryContext: String?
        if config.memoryModeEnabled {
            await memoryStore.remember(message)
            memoryContext = await memoryStore.buildSystemContext()
        } else {
            memoryContext = nil
        }
        let realtimeContext = await realtimeContextProvider.buildSystemContext(
            config: config,
            userPrompt: message.copyableText
        )
        let request = try ChatRequestBuilder.makeRequest(
            config: config,
            history: history,
            message: message,
            realtimeSystemContext: realtimeContext,
            memorySystemContext: memoryContext
        )

        if config.streamEnabled {
            var streamRequest = request
            streamRequest.timeoutInterval = max(config.timeout, 90)
            do {
                return try await withRetry(maxRetries: 3) { [self] in
                    let (bytes, response) = try await session.bytes(for: streamRequest)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw ChatServiceError.invalidResponse
                }

                guard (200...299).contains(httpResponse.statusCode) else {
                    throw ChatServiceError.httpError(httpResponse.statusCode)
                }

                var fullReplyParts: [String] = []
                var imageURLs = Set<String>()
                var citationURLs = Set<String>()
                var pendingDeltaParts: [String] = []
                var pendingDeltaCharacters = 0
                var pendingImageURLs = Set<String>()
                var thinkTagFilter = ThinkTagStreamFilter()
                var accumulatedResponseText = ""
                var latestUsage: ChatTokenUsage?
                var lastEmitAt = Date.distantPast
                // Emit moderate batched deltas to balance smoothness and main-thread load.
                let streamEmitInterval: TimeInterval = 0.030
                let streamForceEmitCharacterThreshold = 96

                func emitPending(force: Bool = false) {
                    guard pendingDeltaCharacters > 0 || !pendingImageURLs.isEmpty else { return }
                    let now = Date()
                    let shouldForceBySize = pendingDeltaCharacters >= streamForceEmitCharacterThreshold
                    if !force && !shouldForceBySize && now.timeIntervalSince(lastEmitAt) < streamEmitInterval {
                        return
                    }
                    let pendingDeltaText = pendingDeltaParts.joined()
                    onEvent(
                        StreamChunk(
                            rawLine: "",
                            deltaText: pendingDeltaText,
                            imageURLs: Array(pendingImageURLs),
                            isDone: false
                        )
                    )
                    pendingDeltaParts.removeAll(keepingCapacity: true)
                    pendingDeltaCharacters = 0
                    pendingImageURLs.removeAll()
                    lastEmitAt = now
                }

                for try await line in bytes.lines {
                    try Task.checkCancellation()
                    guard let chunk = StreamParser.parse(line: line) else { continue }
                    if chunk.isDone { break }

                    let parsedCitationURLs = StreamParser.extractCitationURLs(line: line)
                    if !parsedCitationURLs.isEmpty {
                        parsedCitationURLs.forEach { citationURLs.insert($0) }
                    }

                    if !chunk.deltaText.isEmpty {
                        let filtered = thinkTagFilter.filter(chunk.deltaText)
                        let sanitized = sanitizeStreamingAssistantText(filtered)
                        if !sanitized.isEmpty {
                            let incremental = incrementalStreamingTextDelta(
                                existing: accumulatedResponseText,
                                incoming: sanitized
                            )
                            if !incremental.isEmpty {
                                accumulatedResponseText += incremental
                                fullReplyParts.append(incremental)
                                pendingDeltaParts.append(incremental)
                                pendingDeltaCharacters += incremental.count
                            }
                        }
                    }
                    if !chunk.imageURLs.isEmpty {
                        chunk.imageURLs.forEach { imageURLs.insert($0) }
                        chunk.imageURLs.forEach { pendingImageURLs.insert($0) }
                    }

                    if let eventObject = parseJSONObjectFromSSELine(line),
                       let usage = extractTokenUsage(from: eventObject) {
                        latestUsage = usage
                    }

                    emitPending()
                }

                let trailingFiltered = thinkTagFilter.finalize()
                let trailingSanitized = sanitizeStreamingAssistantText(trailingFiltered)
                if !trailingSanitized.isEmpty {
                    let incremental = incrementalStreamingTextDelta(
                        existing: accumulatedResponseText,
                        incoming: trailingSanitized
                    )
                    if !incremental.isEmpty {
                        accumulatedResponseText += incremental
                        fullReplyParts.append(incremental)
                        pendingDeltaParts.append(incremental)
                        pendingDeltaCharacters += incremental.count
                    }
                }
                emitPending(force: true)

                let fullReply = fullReplyParts.joined()
                let cleaned = ResponseCleaner.cleanAssistantText(fullReply)
                let mergedText = mergeTextWithCitationURLs(cleaned, citationURLs: Array(citationURLs))
                let images = imageURLs.map { ChatImageAttachment(dataURL: $0, mimeType: "image/*", remoteURL: $0) }
                if mergedText.isEmpty && images.isEmpty {
                    throw ChatServiceError.noData
                }
                return ChatReply(text: mergedText, imageAttachments: images, usage: latestUsage)
                }
            } catch {
                if !shouldFallbackChatCompletionsStreamError(error) {
                    throw error
                }
            }
        }

        var nonStreamingConfig = config
        nonStreamingConfig.streamEnabled = false
        let nonStreamingRequest = try ChatRequestBuilder.makeRequest(
            config: nonStreamingConfig,
            history: history,
            message: message,
            realtimeSystemContext: realtimeContext,
            memorySystemContext: memoryContext
        )

        let (data, response) = try await withRetry { [self] in
            try await session.data(for: nonStreamingRequest)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChatServiceError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw ChatServiceError.httpError(httpResponse.statusCode)
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatServiceError.noData
        }

        let parsed = StreamParser.extractPayload(from: object)
        let citationURLs = StreamParser.extractCitationURLs(from: object)
        let cleanedText = ResponseCleaner.cleanAssistantText(parsed.text)
        let usage = extractTokenUsage(from: object)
        let reply = ChatReply(
            text: mergeTextWithCitationURLs(cleanedText, citationURLs: citationURLs),
            imageAttachments: deduplicateImages(
                parsed.imageURLs.map { ChatImageAttachment(dataURL: $0, mimeType: "image/*", remoteURL: $0) }
            ),
            usage: usage
        )
        if reply.text.isEmpty && reply.imageAttachments.isEmpty {
            throw ChatServiceError.noData
        }

        let snapshotChunk = StreamChunk(rawLine: "", deltaText: reply.text, imageURLs: reply.imageAttachments.map(\.requestURLString), isDone: false)
        onEvent(snapshotChunk)
        return reply
    }

    private func sendImageGeneration(
        config: ChatConfig,
        message: ChatMessage,
        onEvent: @escaping @Sendable (StreamChunk) -> Void
    ) async throws -> ChatReply {
        let prompt = message.copyableText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw ChatServiceError.invalidInput("生图模式需要输入图片描述（prompt）。")
        }

        let attempts = buildImageGenerationAttempts(config: config)
        var lastError: Error = ChatServiceError.noData

        for (index, attempt) in attempts.enumerated() {
            do {
                let request = try ChatRequestBuilder.makeImagesGenerationRequest(
                    config: attempt.config,
                    prompt: prompt,
                    forceMinimalPayload: attempt.forceMinimalPayload
                )
                let (data, response) = try await withRetry { [self] in
                    try await session.data(for: request)
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw ChatServiceError.invalidResponse
                }
                guard (200...299).contains(httpResponse.statusCode) else {
                    throw ChatServiceError.httpError(httpResponse.statusCode)
                }

                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw ChatServiceError.noData
                }

                let parsed = StreamParser.extractPayload(from: object)
                let images = deduplicateImages(
                    parsed.imageURLs.map { ChatImageAttachment(dataURL: $0, mimeType: "image/*", remoteURL: $0) }
                )
                guard !images.isEmpty else {
                    throw ChatServiceError.noData
                }

                let revisedPrompt = object["revised_prompt"] as? String
                let parsedText = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let text: String
                if !parsedText.isEmpty {
                    text = parsedText
                } else if let revisedPrompt, !revisedPrompt.isEmpty {
                    text = "优化提示词：\(revisedPrompt)"
                } else {
                    text = ""
                }

                onEvent(
                    StreamChunk(
                        rawLine: "",
                        deltaText: text,
                        imageURLs: images.map(\.requestURLString),
                        isDone: false
                    )
                )
                return ChatReply(text: text, imageAttachments: images)
            } catch let error as ChatServiceError {
                let hasNext = index + 1 < attempts.count
                if hasNext, shouldRetryImageGenerationAttempt(for: error) {
                    lastError = error
                    continue
                }
                throw error
            } catch {
                let hasNext = index + 1 < attempts.count
                if hasNext {
                    lastError = error
                    continue
                }
                throw error
            }
        }

        throw lastError
    }

    private func buildImageGenerationAttempts(
        config: ChatConfig
    ) -> [(config: ChatConfig, forceMinimalPayload: Bool)] {
        var attempts: [(config: ChatConfig, forceMinimalPayload: Bool)] = []
        var seen: Set<String> = []

        func append(_ candidate: ChatConfig, forceMinimalPayload: Bool) {
            let normalizedPath = ChatConfigStore.normalizeEndpointPath(
                candidate.imagesGenerationsPath,
                fallback: ChatConfig.defaultImagesGenerationsPath
            ).lowercased()
            let key = "\(normalizedPath)|\(candidate.model.lowercased())|\(forceMinimalPayload ? "1" : "0")"
            guard seen.insert(key).inserted else { return }
            attempts.append((candidate, forceMinimalPayload))
        }

        append(config, forceMinimalPayload: false)

        let normalizedPath = ChatConfigStore.normalizeEndpointPath(
            config.imagesGenerationsPath,
            fallback: ChatConfig.defaultImagesGenerationsPath
        )
        let loweredPath = normalizedPath.lowercased()
        if loweredPath.hasPrefix("/v1/") {
            var withoutV1 = config
            let stripped = String(normalizedPath.dropFirst(3))
            withoutV1.imagesGenerationsPath = stripped.hasPrefix("/") ? stripped : "/\(stripped)"
            append(withoutV1, forceMinimalPayload: false)
        } else if loweredPath.hasPrefix("/images/") {
            var withV1 = config
            withV1.imagesGenerationsPath = "/v1" + normalizedPath
            append(withV1, forceMinimalPayload: false)
        }

        if isLikelyNonImageModel(config.model) {
            var imageModel = config
            imageModel.model = "gpt-image-1"
            append(imageModel, forceMinimalPayload: false)

            if loweredPath.hasPrefix("/v1/") {
                var imageModelWithoutV1 = imageModel
                let stripped = String(normalizedPath.dropFirst(3))
                imageModelWithoutV1.imagesGenerationsPath = stripped.hasPrefix("/") ? stripped : "/\(stripped)"
                append(imageModelWithoutV1, forceMinimalPayload: false)
            }
        }

        let standardAttempts = attempts
        for attempt in standardAttempts {
            append(attempt.config, forceMinimalPayload: true)
        }

        return attempts
    }

    private func shouldRetryImageGenerationAttempt(for error: ChatServiceError) -> Bool {
        switch error {
        case .invalidResponse, .noData:
            return true
        case .httpError(let status):
            return [400, 404, 405, 415, 422, 429, 500, 501, 502, 503, 504].contains(status)
        case .invalidInput, .invalidURL, .unsupported:
            return false
        }
    }

    private func isLikelyNonImageModel(_ rawModel: String) -> Bool {
        let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !model.isEmpty else { return false }

        let imageMarkers = [
            "image", "dall", "flux", "stable-diffusion", "sdxl",
            "grok-imagine", "grok-image", "midjourney", "janus", "recraft"
        ]
        if imageMarkers.contains(where: { model.contains($0) }) {
            return false
        }
        if model.contains("video") {
            return false
        }
        return true
    }

    private func sendVideoGeneration(
        config: ChatConfig,
        message: ChatMessage,
        onEvent: @escaping @Sendable (StreamChunk) -> Void
    ) async throws -> ChatReply {
        let prompt = message.copyableText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw ChatServiceError.invalidInput("生视频模式需要输入视频描述（prompt）。")
        }

        let request = try ChatRequestBuilder.makeVideoGenerationRequest(config: config, prompt: prompt)
        let (data, response) = try await withRetry { [self] in
            try await session.data(for: request)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChatServiceError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw ChatServiceError.httpError(httpResponse.statusCode)
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatServiceError.noData
        }

        let immediateVideos = deduplicateVideos(extractVideoAttachments(from: object, baseURL: config.normalizedBaseURL))
        if !immediateVideos.isEmpty {
            let text = videoReplyText(from: object, fallbackCount: immediateVideos.count)
            onEvent(StreamChunk(rawLine: "", deltaText: text, imageURLs: [], isDone: false))
            return ChatReply(text: text, videoAttachments: immediateVideos)
        }

        let taskID = extractVideoTaskID(from: object)
        guard let pollURL = resolveVideoPollURL(from: object, taskID: taskID, config: config) else {
            throw ChatServiceError.noData
        }

        onEvent(
            StreamChunk(
                rawLine: "",
                deltaText: "视频任务已提交，正在生成…",
                imageURLs: [],
                isDone: false
            )
        )

        return try await pollVideoGeneration(
            config: config,
            pollURLString: pollURL,
            taskID: taskID,
            onEvent: onEvent
        )
    }

    private func pollVideoGeneration(
        config: ChatConfig,
        pollURLString: String,
        taskID: String?,
        onEvent: @escaping @Sendable (StreamChunk) -> Void
    ) async throws -> ChatReply {
        let timeout = max(config.timeout, 180)
        let deadline = Date().addingTimeInterval(timeout)
        var statusURL = pollURLString
        var lastStatusLine = ""
        var attempts = 0

        while Date() < deadline {
            try Task.checkCancellation()

            guard let url = URL(string: statusURL), !statusURL.isEmpty else {
                throw ChatServiceError.invalidURL
            }

            var request = URLRequest(url: url, timeoutInterval: max(config.timeout, 60))
            request.httpMethod = "GET"
            let trimmedAPIKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedAPIKey.isEmpty {
                request.setValue("Bearer \(trimmedAPIKey)", forHTTPHeaderField: "Authorization")
            }

            let (data, response) = try await withRetry { [self] in
                try await session.data(for: request)
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ChatServiceError.invalidResponse
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                throw ChatServiceError.httpError(httpResponse.statusCode)
            }

            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ChatServiceError.noData
            }

            let videos = deduplicateVideos(extractVideoAttachments(from: object, baseURL: config.normalizedBaseURL))
            let status = extractVideoTaskStatus(from: object)
            let progress = extractVideoProgress(from: object)
            let statusLine = readableVideoStatusLine(status: status, progress: progress)
            if !statusLine.isEmpty, statusLine != lastStatusLine {
                onEvent(StreamChunk(rawLine: "", deltaText: "\n\(statusLine)", imageURLs: [], isDone: false))
                lastStatusLine = statusLine
            }

            if let status, isVideoTaskFailureStatus(status) {
                let reason = extractVideoFailureReason(from: object)
                if let reason, !reason.isEmpty {
                    throw ChatServiceError.invalidInput("视频生成失败：\(reason)")
                }
                throw ChatServiceError.invalidInput("视频生成失败（状态：\(status)）。")
            }

            if !videos.isEmpty, status == nil || isVideoTaskSuccessStatus(status ?? "") {
                let text = videoReplyText(from: object, fallbackCount: videos.count)
                onEvent(StreamChunk(rawLine: "", deltaText: "\n视频生成完成。", imageURLs: [], isDone: false))
                return ChatReply(text: text, videoAttachments: videos)
            }

            if let status, isVideoTaskSuccessStatus(status), videos.isEmpty {
                if attempts >= 1 {
                    throw ChatServiceError.noData
                }
            }

            if let nextURL = resolveVideoPollURL(from: object, taskID: taskID, config: config) {
                statusURL = nextURL
            }

            attempts += 1
            let sleepSeconds = min(2.6, 1.4 + (Double(attempts) * 0.06))
            try await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
        }

        throw ChatServiceError.invalidInput("视频生成超时，请稍后重试。")
    }

    private func extractVideoAttachments(from object: [String: Any], baseURL: String) -> [ChatVideoAttachment] {
        var collected: [(url: String, mimeType: String?)] = []
        collectVideoCandidates(in: object, keyPath: [], collected: &collected)

        let parsedText = StreamParser.extractPayload(from: object).text
        let inlineURLs = extractWebURLs(from: parsedText)
        for url in inlineURLs where isLikelyVideoURL(url) {
            collected.append((url, nil))
        }

        var result: [ChatVideoAttachment] = []
        var seen = Set<String>()
        for item in collected {
            guard let normalized = normalizeVideoURL(item.url, baseURL: baseURL),
                  !normalized.isEmpty,
                  seen.insert(normalized).inserted else {
                continue
            }
            let mime = normalizedVideoMimeType(urlString: normalized, preferred: item.mimeType)
            result.append(ChatVideoAttachment(remoteURL: normalized, mimeType: mime))
        }
        return result
    }

    private func collectVideoCandidates(
        in node: Any,
        keyPath: [String],
        collected: inout [(url: String, mimeType: String?)]
    ) {
        if let dict = node as? [String: Any] {
            for (rawKey, value) in dict {
                let key = rawKey.lowercased()
                let nextPath = keyPath + [key]

                if let stringValue = value as? String {
                    let mimeHint = (dict["mime_type"] as? String)
                        ?? (dict["mime"] as? String)
                        ?? (dict["content_type"] as? String)
                    if shouldTreatAsVideoURL(
                        stringValue,
                        key: key,
                        path: nextPath
                    ) {
                        collected.append((stringValue, mimeHint))
                    }
                } else if let nested = value as? [String: Any] {
                    collectVideoCandidates(in: nested, keyPath: nextPath, collected: &collected)
                } else if let array = value as? [Any] {
                    collectVideoCandidates(in: array, keyPath: nextPath, collected: &collected)
                }
            }
            return
        }

        if let array = node as? [Any] {
            for item in array {
                collectVideoCandidates(in: item, keyPath: keyPath, collected: &collected)
            }
        }
    }

    private func shouldTreatAsVideoURL(_ raw: String, key: String, path: [String]) -> Bool {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }
        let looksLikeURL = cleaned.hasPrefix("http://")
            || cleaned.hasPrefix("https://")
            || cleaned.hasPrefix("//")
            || cleaned.hasPrefix("/")
        guard looksLikeURL else { return false }

        let lowerPath = path.joined(separator: ".")
        if key.contains("status") || key.contains("poll") || key.contains("operation") {
            return false
        }
        if lowerPath.contains("status_url")
            || lowerPath.contains("poll_url")
            || lowerPath.contains("operation_url")
            || lowerPath.contains("task_url") {
            return false
        }

        if isLikelyVideoURL(cleaned) {
            return true
        }

        if key.contains("video") {
            return true
        }

        return lowerPath.contains("video")
    }

    private func isLikelyVideoURL(_ raw: String) -> Bool {
        let lowered = raw.lowercased()
        let videoSuffixes = [".mp4", ".mov", ".m4v", ".webm", ".mkv", ".avi", ".wmv", ".flv", ".m3u8"]
        if videoSuffixes.contains(where: { lowered.contains($0) }) {
            return true
        }
        if lowered.contains("mime=video/") || lowered.contains("content-type=video/") {
            return true
        }
        return false
    }

    private func normalizeVideoURL(_ raw: String, baseURL: String) -> String? {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'"))
        cleaned = cleaned.replacingOccurrences(of: "\\/", with: "/")
        cleaned = cleaned.replacingOccurrences(of: "&amp;", with: "&")

        if cleaned.hasPrefix("//") {
            return "https:\(cleaned)"
        }

        if cleaned.hasPrefix("/") {
            let base = baseURL
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !base.isEmpty else { return nil }
            return "\(base)\(cleaned)"
        }

        if cleaned.hasPrefix("http://") || cleaned.hasPrefix("https://") {
            return cleaned
        }

        if cleaned.contains("/"), !cleaned.contains(" ") {
            let base = baseURL
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !base.isEmpty else { return nil }
            return "\(base)/\(cleaned)"
        }
        return nil
    }

    private func normalizedVideoMimeType(urlString: String, preferred: String?) -> String {
        if let preferred, preferred.lowercased().hasPrefix("video/") {
            return preferred
        }

        let lowered = urlString.lowercased()
        if lowered.contains(".webm") { return "video/webm" }
        if lowered.contains(".mov") { return "video/quicktime" }
        if lowered.contains(".m3u8") { return "application/x-mpegURL" }
        return "video/mp4"
    }

    private func extractVideoTaskID(from object: [String: Any]) -> String? {
        let keys = ["task_id", "id", "job_id", "generation_id", "request_id"]
        return firstStringValue(for: keys, in: object)
    }

    private func extractVideoTaskStatus(from object: [String: Any]) -> String? {
        let keys = ["status", "state", "task_status", "job_status"]
        return firstStringValue(for: keys, in: object)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func extractVideoProgress(from object: [String: Any]) -> Int? {
        let keyCandidates = ["progress", "percent", "percentage"]
        if let number = firstNumberValue(for: keyCandidates, in: object) {
            if number <= 1 {
                return max(0, min(100, Int(number * 100)))
            }
            return max(0, min(100, Int(number)))
        }
        return nil
    }

    private func resolveVideoPollURL(from object: [String: Any], taskID: String?, config: ChatConfig) -> String? {
        let keys = ["status_url", "poll_url", "operation_url", "task_url"]
        if let direct = firstStringValue(for: keys, in: object),
           let normalized = normalizeVideoURL(direct, baseURL: config.normalizedBaseURL) {
            return normalized
        }

        guard let taskID, !taskID.isEmpty else { return nil }
        let endpoint = config.videoGenerationsURLString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !endpoint.isEmpty else { return nil }

        let encodedID = taskID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? taskID
        return "\(endpoint)/\(encodedID)"
    }

    private func readableVideoStatusLine(status: String?, progress: Int?) -> String {
        let normalized = status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if normalized.isEmpty {
            if let progress {
                return "视频生成中（\(progress)%）…"
            }
            return "视频生成中…"
        }

        if isVideoTaskSuccessStatus(normalized) {
            return "视频已生成，正在整理结果…"
        }
        if isVideoTaskFailureStatus(normalized) {
            return "视频生成失败（\(normalized)）"
        }

        if let progress {
            return "视频生成中（\(progress)%）…"
        }
        return "视频生成状态：\(normalized)"
    }

    private func isVideoTaskSuccessStatus(_ status: String) -> Bool {
        let normalized = status.lowercased()
        return normalized == "succeeded"
            || normalized == "success"
            || normalized == "completed"
            || normalized == "done"
            || normalized == "finished"
    }

    private func isVideoTaskFailureStatus(_ status: String) -> Bool {
        let normalized = status.lowercased()
        return normalized == "failed"
            || normalized == "error"
            || normalized == "cancelled"
            || normalized == "canceled"
            || normalized == "rejected"
            || normalized == "expired"
    }

    private func extractVideoFailureReason(from object: [String: Any]) -> String? {
        if let errorNode = object["error"] {
            if let text = errorNode as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let dict = errorNode as? [String: Any] {
                let keys = ["message", "detail", "reason", "error_message"]
                if let text = firstStringValue(for: keys, in: dict),
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        let keys = ["message", "detail", "reason", "error_message"]
        if let text = firstStringValue(for: keys, in: object),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func videoReplyText(from object: [String: Any], fallbackCount: Int) -> String {
        let payloadText = StreamParser.extractPayload(from: object).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !payloadText.isEmpty {
            return payloadText
        }

        if let revisedPrompt = firstStringValue(for: ["revised_prompt"], in: object),
           !revisedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "优化提示词：\(revisedPrompt)"
        }
        return "视频生成完成（\(fallbackCount) 个）"
    }

    private func firstStringValue(for keys: [String], in node: Any) -> String? {
        let normalizedKeys = Set(keys.map { $0.lowercased() })

        if let dict = node as? [String: Any] {
            for (rawKey, value) in dict {
                let loweredKey = rawKey.lowercased()
                if normalizedKeys.contains(loweredKey),
                   let text = value as? String,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text
                }
            }
            for value in dict.values {
                if let found = firstStringValue(for: keys, in: value) {
                    return found
                }
            }
            return nil
        }

        if let array = node as? [Any] {
            for item in array {
                if let found = firstStringValue(for: keys, in: item) {
                    return found
                }
            }
            return nil
        }

        return nil
    }

    private func firstNumberValue(for keys: [String], in node: Any) -> Double? {
        let normalizedKeys = Set(keys.map { $0.lowercased() })

        if let dict = node as? [String: Any] {
            for (rawKey, value) in dict where normalizedKeys.contains(rawKey.lowercased()) {
                if let number = value as? NSNumber {
                    return number.doubleValue
                }
                if let string = value as? String, let double = Double(string) {
                    return double
                }
            }
            for value in dict.values {
                if let found = firstNumberValue(for: keys, in: value) {
                    return found
                }
            }
            return nil
        }

        if let array = node as? [Any] {
            for item in array {
                if let found = firstNumberValue(for: keys, in: item) {
                    return found
                }
            }
        }

        return nil
    }

    private func parseJSONObjectFromSSELine(_ line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        let payload: String
        if trimmed.hasPrefix("data:") {
            payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if trimmed.hasPrefix("event:") || trimmed.hasPrefix(":") {
            return nil
        } else {
            payload = trimmed
        }

        if payload == "[DONE]" { return nil }

        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private func extractWebURLs(from text: String) -> [String] {
        guard !text.isEmpty,
              let regex = try? NSRegularExpression(pattern: #"https?://[^\s\"<>)\]]+"#) else {
            return []
        }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: nsRange)
        guard !matches.isEmpty else { return [] }

        var urls: [String] = []
        urls.reserveCapacity(matches.count)
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            urls.append(String(text[range]))
        }
        return urls
    }

    private func sendEmbeddings(
        config: ChatConfig,
        message: ChatMessage,
        onEvent: @escaping @Sendable (StreamChunk) -> Void
    ) async throws -> ChatReply {
        let input = message.copyableText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            throw ChatServiceError.invalidInput("向量模式需要输入文本内容。")
        }

        let request = try ChatRequestBuilder.makeEmbeddingsRequest(config: config, input: input)
        let (data, response) = try await withRetry { [self] in
            try await session.data(for: request)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChatServiceError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw ChatServiceError.httpError(httpResponse.statusCode)
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[String: Any]],
              let first = rows.first,
              let vectorRaw = first["embedding"] as? [Any] else {
            throw ChatServiceError.noData
        }

        let vector = vectorRaw.compactMap { value -> Double? in
            if let number = value as? NSNumber { return number.doubleValue }
            if let string = value as? String { return Double(string) }
            return nil
        }
        guard !vector.isEmpty else {
            throw ChatServiceError.noData
        }

        let preview = vector.prefix(8).map { String(format: "%.6f", $0) }.joined(separator: ", ")
        let text = """
        向量生成成功
        维度：\(vector.count)
        前 8 维：\(preview)
        """

        onEvent(StreamChunk(rawLine: "", deltaText: text, imageURLs: [], isDone: false))
        return ChatReply(text: text, imageAttachments: [])
    }

    private func sendAudioTranscriptions(
        config: ChatConfig,
        message: ChatMessage,
        onEvent: @escaping @Sendable (StreamChunk) -> Void
    ) async throws -> ChatReply {
        guard let file = extractAudioFile(from: message) else {
            throw ChatServiceError.invalidInput("语音转文字模式需要先附加音频文件（如 mp3/m4a/wav）。")
        }

        let request = try ChatRequestBuilder.makeAudioTranscriptionsRequest(
            config: config,
            fileName: file.fileName,
            mimeType: file.mimeType,
            fileData: file.data,
            prompt: message.content
        )

        let (data, response) = try await withRetry { [self] in
            try await session.data(for: request)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChatServiceError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw ChatServiceError.httpError(httpResponse.statusCode)
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatServiceError.noData
        }

        let text: String
        if let direct = object["text"] as? String, !direct.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = direct
        } else if let transcript = object["transcript"] as? String, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = transcript
        } else if let segments = object["segments"] as? [[String: Any]], !segments.isEmpty {
            let joined = segments.compactMap { $0["text"] as? String }.joined(separator: "")
            text = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            throw ChatServiceError.noData
        }

        onEvent(StreamChunk(rawLine: "", deltaText: text, imageURLs: [], isDone: false))
        return ChatReply(text: text, imageAttachments: [])
    }

    func testConnection(config: ChatConfig) async -> String {
        do {
            let ping = ChatMessage(role: .user, content: "ping")
            let request = try ChatRequestBuilder.makeRequest(config: config, history: [], message: ping)
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                return "接口联通成功，状态码：\(httpResponse.statusCode)"
            }
            return "接口已响应，但返回类型异常。"
        } catch {
            return "接口测试失败：\(error.localizedDescription)"
        }
    }

    func fetchModels(config: ChatConfig) async throws -> [String] {
        let request = try ChatRequestBuilder.makeModelsRequest(config: config)
        let (data, response) = try await withRetry { [self] in
            try await session.data(for: request)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChatServiceError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw ChatServiceError.httpError(httpResponse.statusCode)
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[String: Any]] else {
            throw ChatServiceError.noData
        }

        let models = rows.compactMap { $0["id"] as? String }.sorted()
        if models.isEmpty {
            throw ChatServiceError.noData
        }
        return models
    }

    func loadMemoryEntries() async -> [ConversationMemoryItem] {
        await memoryStore.listEntries()
    }

    func clearAllMemoryEntries() async {
        await memoryStore.reset()
    }

    func removeMemoryEntry(id: UUID) async {
        await memoryStore.removeEntry(id: id)
    }

    func removeMemoryEntries(ids: [UUID]) async {
        await memoryStore.removeEntries(ids: ids)
    }

    private func modelsText(_ models: [String]) -> String {
        guard !models.isEmpty else {
            return "当前接口没有返回可用模型。"
        }
        let lines = models.prefix(120).map { "• \($0)" }
        return "模型列表（\(models.count) 个）\n" + lines.joined(separator: "\n")
    }

    private func extractAudioFile(from message: ChatMessage) -> (fileName: String, mimeType: String, data: Data)? {
        for file in message.fileAttachments {
            let mime = file.mimeType.trimmingCharacters(in: .whitespacesAndNewlines)
            let loweredMime = mime.lowercased()
            let loweredName = file.fileName.lowercased()
            let audioLike = loweredMime.hasPrefix("audio/")
                || loweredName.hasSuffix(".mp3")
                || loweredName.hasSuffix(".wav")
                || loweredName.hasSuffix(".m4a")
                || loweredName.hasSuffix(".aac")
                || loweredName.hasSuffix(".ogg")
                || loweredName.hasSuffix(".flac")

            if let b64 = file.binaryBase64, audioLike,
               let data = Data(base64Encoded: b64),
               !data.isEmpty {
                return (file.fileName, mime.isEmpty ? "audio/mpeg" : mime, data)
            }

            if let decoded = decodeAudioDataURL(file.textContent), audioLike {
                return (file.fileName, decoded.mimeType, decoded.data)
            }
        }
        return nil
    }

    private func decodeAudioDataURL(_ input: String) -> (mimeType: String, data: Data)? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:audio/") else { return nil }
        let parts = trimmed.split(separator: ",", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let header = parts[0].lowercased()
        let payload = parts[1]

        let mimeType = header
            .replacingOccurrences(of: "data:", with: "")
            .components(separatedBy: ";")
            .first ?? "audio/mpeg"

        if header.contains(";base64"), let data = Data(base64Encoded: payload), !data.isEmpty {
            return (mimeType, data)
        }
        return nil
    }

    private func deduplicateImages(_ attachments: [ChatImageAttachment]) -> [ChatImageAttachment] {
        var seen = Set<String>()
        var result: [ChatImageAttachment] = []
        for item in attachments {
            let key = item.requestURLString
            if key.isEmpty || seen.contains(key) { continue }
            seen.insert(key)
            result.append(item)
        }
        return result
    }

    private func deduplicateVideos(_ attachments: [ChatVideoAttachment]) -> [ChatVideoAttachment] {
        var seen = Set<String>()
        var result: [ChatVideoAttachment] = []
        for item in attachments {
            let key = item.requestURLString
            if key.isEmpty || seen.contains(key) { continue }
            seen.insert(key)
            result.append(item)
        }
        return result
    }

    private func incrementalStreamingTextDelta(existing: String, incoming: String) -> String {
        guard !incoming.isEmpty else { return "" }
        guard !existing.isEmpty else { return incoming }

        if incoming.hasPrefix(existing) {
            return String(incoming.dropFirst(existing.count))
        }

        if existing.hasSuffix(incoming) {
            return ""
        }

        let existingChars = Array(existing)
        let incomingChars = Array(incoming)
        let maxOverlap = min(existingChars.count, incomingChars.count)
        if maxOverlap > 0 {
            for overlap in stride(from: maxOverlap, through: 1, by: -1) {
                if existingChars.suffix(overlap).elementsEqual(incomingChars.prefix(overlap)) {
                    return String(incomingChars.dropFirst(overlap))
                }
            }
        }

        return incoming
    }

    private func sanitizeStreamingAssistantText(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }

        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\u{0000}", with: "")
        let lowered = normalized.lowercased()

        let likelyProtocolLeak =
            lowered.contains("to=shell")
            || lowered.contains("to=functions.")
            || lowered.contains("to=multi_tool_use.")
            || lowered.contains("\"recipient_name\"")
            || lowered.contains("functions.shell_command")
            || lowered.contains("multi_tool_use.parallel")
            || lowered.contains("{\"command\":[\"bash\"")
            || lowered.contains("{\"command\":[\"powershell\"")

        guard likelyProtocolLeak else { return normalized }

        let filteredLines = normalized
            .components(separatedBy: "\n")
            .filter { line in
                let trimmedLower = line
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                guard !trimmedLower.isEmpty else { return true }

                if trimmedLower.hasPrefix("to=shell")
                    || trimmedLower.hasPrefix("to=functions.")
                    || trimmedLower.hasPrefix("to=multi_tool_use.") {
                    return false
                }

                if trimmedLower.contains("functions.shell_command")
                    || trimmedLower.contains("multi_tool_use.parallel")
                    || trimmedLower.contains("\"recipient_name\"") {
                    return false
                }

                if trimmedLower.hasPrefix("{\"command\":[\"bash\"")
                    || trimmedLower.hasPrefix("{\"command\":[\"powershell\"") {
                    return false
                }

                return true
            }

        return filteredLines.joined(separator: "\n")
    }

    private func extractTokenUsage(from object: [String: Any]) -> ChatTokenUsage? {
        if let usage = object["usage"] as? [String: Any],
           let parsed = parseTokenUsage(usage) {
            return parsed
        }

        if let response = object["response"] as? [String: Any],
           let usage = response["usage"] as? [String: Any],
           let parsed = parseTokenUsage(usage) {
            return parsed
        }

        return nil
    }

    private func parseTokenUsage(_ usage: [String: Any]) -> ChatTokenUsage? {
        let inputTokens = extractInt(for: ["input_tokens", "prompt_tokens"], in: usage)
        let outputTokens = extractInt(for: ["output_tokens", "completion_tokens"], in: usage)
        let totalTokens = extractInt(for: ["total_tokens"], in: usage)

        let cachedTokens =
            extractInt(for: ["cached_tokens", "input_cached_tokens", "cache_read_input_tokens"], in: usage)
            ?? extractInt(for: ["cached_tokens", "cache_read_tokens"], in: usage["input_tokens_details"])
            ?? extractInt(for: ["cached_tokens", "cache_read_tokens"], in: usage["prompt_tokens_details"])
            ?? extractInt(for: ["cached_tokens", "cache_read_tokens"], in: usage["input_token_details"])
            ?? extractInt(for: ["cached_tokens", "cache_read_tokens"], in: usage["prompt_token_details"])
            ?? sumIntValues(
                for: [
                    "cache_read_input_tokens",
                    "input_cached_tokens",
                    "prompt_cache_hit_tokens",
                    "cache_read_tokens"
                ],
                in: usage
            )
            ?? extractIntRecursively(
                for: [
                    "cached_tokens",
                    "cache_read_input_tokens",
                    "input_cached_tokens",
                    "prompt_cache_hit_tokens",
                    "cache_read_tokens"
                ],
                in: usage
            )

        guard inputTokens != nil || outputTokens != nil || totalTokens != nil || cachedTokens != nil else {
            return nil
        }

        var resolvedInput = inputTokens ?? 0
        var resolvedOutput = outputTokens ?? 0

        if totalTokens != nil, inputTokens == nil, outputTokens != nil {
            resolvedInput = max(0, (totalTokens ?? 0) - resolvedOutput)
        } else if totalTokens != nil, outputTokens == nil, inputTokens != nil {
            resolvedOutput = max(0, (totalTokens ?? 0) - resolvedInput)
        }

        return ChatTokenUsage(
            inputTokens: max(0, resolvedInput),
            outputTokens: max(0, resolvedOutput),
            cachedTokens: max(0, cachedTokens ?? 0)
        )
    }

    private func extractInt(for keys: [String], in node: Any?) -> Int? {
        guard let dict = node as? [String: Any] else { return nil }
        for key in keys {
            if let value = dict[key] {
                if let parsed = parseInt(value) {
                    return parsed
                }
            }
        }
        return nil
    }

    private func sumIntValues(for keys: [String], in node: Any?) -> Int? {
        guard let dict = node as? [String: Any] else { return nil }
        var total = 0
        var hit = false
        for key in keys {
            guard let raw = dict[key], let parsed = parseInt(raw) else { continue }
            total += parsed
            hit = true
        }
        return hit ? total : nil
    }

    private func extractIntRecursively(for keys: [String], in node: Any?) -> Int? {
        let wanted = Set(keys.map { $0.lowercased() })
        return extractIntRecursively(in: node, wantedKeys: wanted)
    }

    private func extractIntRecursively(in node: Any?, wantedKeys: Set<String>) -> Int? {
        if let dict = node as? [String: Any] {
            for (key, value) in dict {
                if wantedKeys.contains(key.lowercased()), let parsed = parseInt(value) {
                    return parsed
                }
                if let nested = extractIntRecursively(in: value, wantedKeys: wantedKeys) {
                    return nested
                }
            }
            return nil
        }

        if let array = node as? [Any] {
            for value in array {
                if let nested = extractIntRecursively(in: value, wantedKeys: wantedKeys) {
                    return nested
                }
            }
        }
        return nil
    }

    private func parseInt(_ value: Any) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let intValue = value as? Int {
            return intValue
        }
        if let stringValue = value as? String {
            let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let parsed = Int(trimmed) {
                return parsed
            }
            if let parsedDouble = Double(trimmed) {
                return Int(parsedDouble.rounded())
            }
        }
        return nil
    }

    private func mergeTextWithCitationURLs(_ text: String, citationURLs: [String]) -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if citationURLs.isEmpty {
            return trimmedText
        }

        var orderedURLs: [String] = []
        var seen = Set<String>()
        for raw in citationURLs {
            let normalized = normalizeCitationURL(raw)
            guard !normalized.isEmpty else { continue }
            if seen.insert(normalized).inserted {
                orderedURLs.append(normalized)
            }
        }
        if orderedURLs.isEmpty {
            return trimmedText
        }

        let existingLower = trimmedText.lowercased()
        let freshURLs = orderedURLs.filter { !existingLower.contains($0.lowercased()) }
        if freshURLs.isEmpty {
            return trimmedText
        }

        let sourceLines = freshURLs.prefix(3).map { url in
            "- [\(citationLabel(for: url))](\(url))"
        }
        let sourceBlock = "来源：\n" + sourceLines.joined(separator: "\n")

        if trimmedText.isEmpty {
            return sourceBlock
        }
        return trimmedText + "\n\n" + sourceBlock
    }

    private func normalizeCitationURL(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'<>[](){}.,;:"))
        if value.hasPrefix("http://") || value.hasPrefix("https://") {
            return value
        }
        return ""
    }

    private func citationLabel(for urlString: String) -> String {
        guard let url = URL(string: urlString),
              let host = url.host?.lowercased(),
              !host.isEmpty else {
            return "source"
        }

        var label = host
        if label.hasPrefix("www.") {
            label.removeFirst(4)
        }

        let pathComponents = url.pathComponents
            .filter { $0 != "/" && !$0.isEmpty }
        if let firstComponent = pathComponents.first,
           firstComponent.count <= 18 {
            label += "/\(firstComponent)"
        }

        return label
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
    }

    private func withRetry<T>(maxRetries: Int = 2, operation: @escaping () async throws -> T) async throws -> T {
        var attempt = 0

        while true {
            do {
                return try await operation()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if !shouldRetry(error: error) || attempt >= maxRetries {
                    throw error
                }
                attempt += 1
                let delayNanoseconds = UInt64(350_000_000 * attempt)
                try await Task.sleep(nanoseconds: delayNanoseconds)
            }
        }
    }

    private func shouldRetry(error: Error) -> Bool {
        if let serviceError = error as? ChatServiceError {
            if case .httpError(let code) = serviceError {
                return [408, 409, 425, 429, 500, 502, 503, 504].contains(code)
            }
            return false
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut,
                 .networkConnectionLost,
                 .notConnectedToInternet,
                 .cannotFindHost,
                 .cannotConnectToHost,
                 .dnsLookupFailed,
                 .resourceUnavailable,
                 .internationalRoamingOff:
                return true
            default:
                return false
            }
        }

        return false
    }
}

private struct ThinkTagStreamFilter {
    private static let openTag = "<think>"
    private static let closeTag = "</think>"
    private static let maxCarryCharacters = max(openTag.count, closeTag.count) - 1

    private var insideThinkBlock = false
    private var carry = ""

    mutating func filter(_ chunk: String) -> String {
        guard !chunk.isEmpty else { return "" }

        let input = carry + chunk
        carry.removeAll(keepingCapacity: true)
        var output = ""
        var cursor = input.startIndex

        while cursor < input.endIndex {
            if insideThinkBlock {
                if let closeRange = input.range(
                    of: Self.closeTag,
                    options: [.caseInsensitive],
                    range: cursor..<input.endIndex
                ) {
                    cursor = closeRange.upperBound
                    insideThinkBlock = false
                    continue
                }

                carry = trailingPartialPrefix(in: String(input[cursor...]), tag: Self.closeTag)
                return output
            }

            let openRange = input.range(
                of: Self.openTag,
                options: [.caseInsensitive],
                range: cursor..<input.endIndex
            )
            let closeRange = input.range(
                of: Self.closeTag,
                options: [.caseInsensitive],
                range: cursor..<input.endIndex
            )

            guard openRange != nil || closeRange != nil else {
                let tail = String(input[cursor...])
                let partial = trailingPartialTagPrefix(in: tail)
                if partial.isEmpty {
                    output += tail
                } else {
                    output += String(tail.dropLast(partial.count))
                    carry = partial
                }
                return output
            }

            let nextRange: Range<String.Index>
            let nextIsOpenTag: Bool
            switch (openRange, closeRange) {
            case let (.some(open), .some(close)):
                if open.lowerBound <= close.lowerBound {
                    nextRange = open
                    nextIsOpenTag = true
                } else {
                    nextRange = close
                    nextIsOpenTag = false
                }
            case let (.some(open), .none):
                nextRange = open
                nextIsOpenTag = true
            case let (.none, .some(close)):
                nextRange = close
                nextIsOpenTag = false
            case (.none, .none):
                return output
            }

            output += String(input[cursor..<nextRange.lowerBound])
            if nextIsOpenTag {
                insideThinkBlock = true
            }
            // If a stray close tag appears outside think block, drop it directly.
            cursor = nextRange.upperBound
        }

        carry.removeAll(keepingCapacity: true)
        return output
    }

    mutating func finalize() -> String {
        guard !carry.isEmpty else {
            if insideThinkBlock {
                insideThinkBlock = false
            }
            return ""
        }

        defer {
            carry.removeAll(keepingCapacity: false)
            insideThinkBlock = false
        }

        if insideThinkBlock || looksLikeTagPrefix(carry) {
            return ""
        }
        return carry
    }

    private func trailingPartialTagPrefix(in text: String) -> String {
        let openPartial = trailingPartialPrefix(in: text, tag: Self.openTag)
        let closePartial = trailingPartialPrefix(in: text, tag: Self.closeTag)
        return openPartial.count >= closePartial.count ? openPartial : closePartial
    }

    private func trailingPartialPrefix(in text: String, tag: String) -> String {
        guard !text.isEmpty else { return "" }
        let maxCheck = min(Self.maxCarryCharacters, text.count)
        guard maxCheck > 0 else { return "" }

        for length in stride(from: maxCheck, through: 1, by: -1) {
            let suffix = String(text.suffix(length))
            if tag.lowercased().hasPrefix(suffix.lowercased()) {
                return suffix
            }
        }
        return ""
    }

    private func looksLikeTagPrefix(_ text: String) -> Bool {
        let lower = text.lowercased()
        return Self.openTag.hasPrefix(lower) || Self.closeTag.hasPrefix(lower)
    }
}

enum ResponseCleaner {
    static func cleanAssistantText(_ raw: String) -> String {
        var text = raw
        let preservedCodeBlocks = preserveCodeBlocks(in: &text)

        text = stripAgentProtocolLeakage(in: text)

        text = text.replacingOccurrences(
            of: "(?is)<think>.*?</think>",
            with: "",
            options: .regularExpression
        )

        text = text.replacingOccurrences(
            of: #"!\[[^\]]*\]\(([^)]+)\)"#,
            with: "",
            options: .regularExpression
        )

        text = text.replacingOccurrences(
            of: #"https?://[^\s\"]+?(?:\.png|\.jpe?g|\.gif|\.webp|\.bmp|\.heic|\.heif|\.svg)(?:\?[^\s\"]*)?(?:#[^\s\"]*)?"#,
            with: "",
            options: .regularExpression
        )

        text = text.replacingOccurrences(
            of: #"\[([^\]]+)\]\(([^)]+)\)"#,
            with: "$1 $2",
            options: .regularExpression
        )

        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        text = restoreCodeBlocks(in: text, preserved: preservedCodeBlocks)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func preserveCodeBlocks(in text: inout String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?s)```.*?```"#) else {
            return []
        }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: nsRange)
        guard !matches.isEmpty else { return [] }

        var preserved: [String] = []
        for (index, match) in matches.enumerated().reversed() {
            guard let range = Range(match.range, in: text) else { continue }
            preserved.insert(String(text[range]), at: 0)
            text.replaceSubrange(range, with: "CODEBLOCKTOKEN\(index)")
        }
        return preserved
    }

    private static func restoreCodeBlocks(in text: String, preserved: [String]) -> String {
        guard !preserved.isEmpty else { return text }

        var restored = text
        for (index, block) in preserved.enumerated() {
            restored = restored.replacingOccurrences(of: "CODEBLOCKTOKEN\(index)", with: block)
        }
        return restored
    }

    private static func stripAgentProtocolLeakage(in text: String) -> String {
        guard !text.isEmpty else { return text }
        return text
            .components(separatedBy: "\n")
            .filter { line in
                let trimmedLower = line
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()

                if trimmedLower.hasPrefix("to=shell")
                    || trimmedLower.hasPrefix("to=functions.")
                    || trimmedLower.hasPrefix("to=multi_tool_use.") {
                    return false
                }

                if trimmedLower.contains("functions.shell_command")
                    || trimmedLower.contains("multi_tool_use.parallel")
                    || trimmedLower.contains("\"recipient_name\"") {
                    return false
                }

                if trimmedLower.hasPrefix("{\"command\":[\"bash\"")
                    || trimmedLower.hasPrefix("{\"command\":[\"powershell\"") {
                    return false
                }

                return true
            }
            .joined(separator: "\n")
    }
}

