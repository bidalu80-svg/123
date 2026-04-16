import Foundation

struct ChatReply: Equatable {
    var text: String
    var imageAttachments: [ChatImageAttachment]
}

struct ChatRequestBuilder {
    private static let iexaIdentitySystemPrompt = """
    你是 IEXA，一款智能助手。用户问你“你是谁/你叫什么”时，请明确回答你叫 IEXA。
    默认回答风格请尽量清晰、有层次、易读：
    1) 先给一句简短结论或总览。
    2) 后续用项目符号组织要点，优先使用“• ”开头，必要时可搭配少量表意 emoji（如 💬、🛠️、📌）。
    3) 避免把很多短句直接逐行堆叠成“无指示文本块”。
    4) 用户明确要求纯文本或其他格式时，以用户要求为准。
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
            memorySystemContext: memorySystemContext
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
        memorySystemContext: String?
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

        let compactHistory = compactHistoryForRequest(history)
        return prefix + compactHistory.map(\.apiPayload) + [message.apiPayload]
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
        return textWeight + fileWeight + imageWeight + 180
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

    static func makeImagesGenerationRequest(config: ChatConfig, prompt: String) throws -> URLRequest {
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

        let payload = makeImageGenerationPayload(config: config, prompt: prompt)
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

    private static func makeImageGenerationPayload(config: ChatConfig, prompt: String) -> [String: Any] {
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

        return [
            "model": config.model,
            "prompt": prompt,
            "size": size,
            "n": 1
        ]
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
        case .imageGenerations:
            return try await sendImageGeneration(
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
            return try await withRetry { [self] in
                let (bytes, response) = try await session.bytes(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw ChatServiceError.invalidResponse
                }

                guard (200...299).contains(httpResponse.statusCode) else {
                    throw ChatServiceError.httpError(httpResponse.statusCode)
                }

                var fullReply = ""
                var imageURLs = Set<String>()
                var pendingDeltaText = ""
                var pendingImageURLs = Set<String>()
                var lastEmitAt = Date.distantPast
                let streamEmitInterval: TimeInterval = 0.02

                func emitPending(force: Bool = false) {
                    guard !pendingDeltaText.isEmpty || !pendingImageURLs.isEmpty else { return }
                    let now = Date()
                    if !force && now.timeIntervalSince(lastEmitAt) < streamEmitInterval {
                        return
                    }
                    onEvent(
                        StreamChunk(
                            rawLine: "",
                            deltaText: pendingDeltaText,
                            imageURLs: Array(pendingImageURLs),
                            isDone: false
                        )
                    )
                    pendingDeltaText = ""
                    pendingImageURLs.removeAll()
                    lastEmitAt = now
                }

                for try await line in bytes.lines {
                    try Task.checkCancellation()
                    guard let chunk = StreamParser.parse(line: line) else { continue }
                    if chunk.isDone { break }

                    if !chunk.deltaText.isEmpty {
                        fullReply += chunk.deltaText
                        pendingDeltaText += chunk.deltaText
                    }
                    if !chunk.imageURLs.isEmpty {
                        chunk.imageURLs.forEach { imageURLs.insert($0) }
                        chunk.imageURLs.forEach { pendingImageURLs.insert($0) }
                    }

                    emitPending()
                }
                emitPending(force: true)

                let cleaned = ResponseCleaner.cleanAssistantText(fullReply)
                let images = imageURLs.map { ChatImageAttachment(dataURL: $0, mimeType: "image/*", remoteURL: $0) }
                if cleaned.isEmpty && images.isEmpty {
                    throw ChatServiceError.noData
                }
                return ChatReply(text: cleaned, imageAttachments: images)
            }
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

        let parsed = StreamParser.extractPayload(from: object)
        let reply = ChatReply(
            text: ResponseCleaner.cleanAssistantText(parsed.text),
            imageAttachments: deduplicateImages(
                parsed.imageURLs.map { ChatImageAttachment(dataURL: $0, mimeType: "image/*", remoteURL: $0) }
            )
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

        let request = try ChatRequestBuilder.makeImagesGenerationRequest(config: config, prompt: prompt)
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
        let text: String
        if let revisedPrompt, !revisedPrompt.isEmpty {
            text = "生图完成（\(images.count) 张）\n优化提示词：\(revisedPrompt)"
        } else if !parsed.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = parsed.text
        } else {
            text = "生图完成（\(images.count) 张）"
        }

        onEvent(StreamChunk(rawLine: "", deltaText: text, imageURLs: images.map(\.requestURLString), isDone: false))
        return ChatReply(text: text, imageAttachments: images)
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

enum ResponseCleaner {
    static func cleanAssistantText(_ raw: String) -> String {
        var text = raw
        let preservedCodeBlocks = preserveCodeBlocks(in: &text)

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
}

