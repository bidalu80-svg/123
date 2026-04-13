import Foundation

struct ChatReply: Equatable {
    var text: String
    var imageAttachments: [ChatImageAttachment]
}

struct ChatRequestBuilder {
    private static let iexaIdentitySystemPrompt = """
    你是 IEXA，一款智能助手。用户问你“你是谁/你叫什么”时，请明确回答你叫 IEXA。
    """

    static func makeRequest(
        config: ChatConfig,
        history: [ChatMessage],
        message: ChatMessage,
        realtimeSystemContext: String? = nil
    ) throws -> URLRequest {
        let completionURL = config.completionURLString
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
            realtimeSystemContext: realtimeSystemContext
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
        realtimeSystemContext: String?
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

        return prefix + history.map(\.apiPayload) + [message.apiPayload]
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
}

enum ChatServiceError: LocalizedError, Equatable {
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case noData

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
        }
    }
}

final class ChatService {
    private let session: URLSession
    private let realtimeContextProvider: RealtimeContextProvider

    init(
        session: URLSession? = nil,
        realtimeContextProvider: RealtimeContextProvider = RealtimeContextProvider()
    ) {
        self.realtimeContextProvider = realtimeContextProvider

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

    func sendMessage(
        config: ChatConfig,
        history: [ChatMessage],
        message: ChatMessage,
        onEvent: @escaping @Sendable (StreamChunk) -> Void
    ) async throws -> ChatReply {
        let realtimeContext = await realtimeContextProvider.buildSystemContext(config: config)
        let request = try ChatRequestBuilder.makeRequest(
            config: config,
            history: history,
            message: message,
            realtimeSystemContext: realtimeContext
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

                for try await line in bytes.lines {
                    try Task.checkCancellation()
                    guard let chunk = StreamParser.parse(line: line) else { continue }
                    if chunk.isDone { break }

                    if !chunk.deltaText.isEmpty {
                        fullReply += chunk.deltaText
                    }
                    if !chunk.imageURLs.isEmpty {
                        chunk.imageURLs.forEach { imageURLs.insert($0) }
                    }

                    if !chunk.deltaText.isEmpty || !chunk.imageURLs.isEmpty {
                        onEvent(chunk)
                    }
                }

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

