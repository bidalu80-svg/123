import XCTest
@testable import ChatApp

final class ChatServiceTests: XCTestCase {
    func testBuildRequestIncludesModelMessagesAndStreamFlag() throws {
        let config = ChatConfig(apiURL: "https://example.com", apiKey: "token-123", model: "gpt-test", timeout: 30, streamEnabled: true)
        let history = [ChatMessage(role: .assistant, content: "history")]
        let requestMessage = ChatMessage(role: .user, content: "hello")

        let request = try ChatRequestBuilder.makeRequest(config: config, history: history, message: requestMessage)
        let payload = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let first = try XCTUnwrap(messages.first)
        let last = try XCTUnwrap(messages.last)

        XCTAssertEqual(request.url?.absoluteString, "https://example.com/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-123")
        XCTAssertEqual(json["model"] as? String, "gpt-test")
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(first["role"] as? String, "system")
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(last["content"] as? String, "hello")
    }

    func testBuildRequestDoesNotDuplicateSystemIdentityWhenHistoryAlreadyHasSystemMessage() throws {
        let config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: true)
        let history = [
            ChatMessage(role: .system, content: "你是 IEXA"),
            ChatMessage(role: .assistant, content: "history")
        ]
        let requestMessage = ChatMessage(role: .user, content: "你是谁")

        let request = try ChatRequestBuilder.makeRequest(config: config, history: history, message: requestMessage)
        let payload = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let systemCount = messages.filter { ($0["role"] as? String) == "system" }.count

        XCTAssertEqual(systemCount, 1)
        XCTAssertEqual(messages.count, 3)
    }

    func testBuildRequestSupportsMultipleImageAttachments() throws {
        let config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: false)
        let attachments = [
            ChatImageAttachment(dataURL: "data:image/png;base64,abcd", mimeType: "image/png"),
            ChatImageAttachment(dataURL: "data:image/jpeg;base64,efgh", mimeType: "image/jpeg")
        ]
        let requestMessage = ChatMessage(role: .user, content: "describe these", imageAttachments: attachments)

        let request = try ChatRequestBuilder.makeRequest(config: config, history: [], message: requestMessage)
        let payload = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let first = try XCTUnwrap(messages.first)
        let content = try XCTUnwrap(first["content"] as? [[String: Any]])

        XCTAssertEqual(content.count, 3)
        XCTAssertEqual(content[0]["type"] as? String, "text")
        XCTAssertEqual(content[0]["text"] as? String, "describe these")
        XCTAssertEqual(content[1]["type"] as? String, "image_url")
        XCTAssertEqual((content[1]["image_url"] as? [String: String])?["url"], attachments[0].requestURLString)
        XCTAssertEqual(content[2]["type"] as? String, "image_url")
        XCTAssertEqual((content[2]["image_url"] as? [String: String])?["url"], attachments[1].requestURLString)
    }

    func testBuildRequestTrimsLongHistoryToKeepPayloadResponsive() throws {
        let config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: true)
        let longText = String(repeating: "历史上下文内容。", count: 1200)
        let history: [ChatMessage] = (0..<40).map { index in
            ChatMessage(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: "\(index):\(longText)"
            )
        }
        let requestMessage = ChatMessage(role: .user, content: "继续")

        let request = try ChatRequestBuilder.makeRequest(config: config, history: history, message: requestMessage)
        let payload = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])

        // system + trimmed history + latest message
        XCTAssertLessThanOrEqual(messages.count, 24)
    }

    func testBuildRequestDropsOlderInlineImageDataFromHistoryForSpeed() throws {
        let config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: true)
        let older = ChatMessage(
            role: .user,
            content: "旧图片",
            imageAttachments: [ChatImageAttachment(dataURL: "data:image/png;base64,old111", mimeType: "image/png")]
        )
        let latestWithImage = ChatMessage(
            role: .user,
            content: "新图片",
            imageAttachments: [ChatImageAttachment(dataURL: "data:image/png;base64,new222", mimeType: "image/png")]
        )
        let history = [older, ChatMessage(role: .assistant, content: "收到"), latestWithImage]
        let requestMessage = ChatMessage(role: .user, content: "继续分析")

        let request = try ChatRequestBuilder.makeRequest(config: config, history: history, message: requestMessage)
        let payload = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])

        var inlineImageCount = 0
        for message in messages {
            guard let content = message["content"] as? [[String: Any]] else { continue }
            for item in content where (item["type"] as? String) == "image_url" {
                let image = item["image_url"] as? [String: Any]
                let url = image?["url"] as? String
                if let url, url.hasPrefix("data:image") {
                    inlineImageCount += 1
                }
            }
        }

        XCTAssertEqual(inlineImageCount, 1)
        let plainTextMessages = messages.compactMap { $0["content"] as? String }.joined(separator: "\n")
        XCTAssertTrue(plainTextMessages.contains("本轮为提速已省略其二进制内容"))
    }

    func testChatImageAttachmentDecodeSupportsURLSafeBase64WithoutPadding() {
        let original = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFE, 0x2F, 0x10])
        let compact = original.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let brokenLines = "\(compact.prefix(5))\n\(compact.dropFirst(5))"

        let attachment = ChatImageAttachment(
            dataURL: "data:image/png;base64,\(brokenLines)",
            mimeType: "image/png"
        )

        XCTAssertEqual(attachment.decodedImageData, original)
    }

    func testBuildRequestIncludesRealtimeSystemContext() throws {
        let config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: true)
        let requestMessage = ChatMessage(role: .user, content: "现在几点")

        let request = try ChatRequestBuilder.makeRequest(
            config: config,
            history: [],
            message: requestMessage,
            realtimeSystemContext: "当前日期时间：2026-04-13 18:20:00"
        )

        let payload = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])

        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[1]["role"] as? String, "system")
        XCTAssertEqual(messages[1]["content"] as? String, "当前日期时间：2026-04-13 18:20:00")
    }

    func testBuildRequestIncludesCrossSessionMemoryContext() throws {
        let config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: true)
        let requestMessage = ChatMessage(role: .user, content: "你好")

        let request = try ChatRequestBuilder.makeRequest(
            config: config,
            history: [],
            message: requestMessage,
            realtimeSystemContext: nil,
            memorySystemContext: "以下是用户跨会话记忆：\n• 我喜欢简洁回答"
        )

        let payload = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])

        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[1]["role"] as? String, "system")
        XCTAssertEqual(messages[1]["content"] as? String, "以下是用户跨会话记忆：\n• 我喜欢简洁回答")
    }

    func testBuildImagesGenerationRequestUsesConfiguredEndpoint() throws {
        var config = ChatConfig(apiURL: "https://example.com", apiKey: "token-123", model: "gpt-image", timeout: 30, streamEnabled: false)
        config.imagesGenerationsPath = "/v1/images/generations"
        config.imageGenerationSize = "1024x1024"

        let request = try ChatRequestBuilder.makeImagesGenerationRequest(config: config, prompt: "a cat")
        let payload = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])

        XCTAssertEqual(request.url?.absoluteString, "https://example.com/v1/images/generations")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-123")
        XCTAssertEqual(json["model"] as? String, "gpt-image")
        XCTAssertEqual(json["prompt"] as? String, "a cat")
        XCTAssertEqual(json["size"] as? String, "1024x1024")
    }

    func testBuildImagesGenerationRequestUsesXAIShapeForGrokImagine() throws {
        var config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "grok-imagine-1", timeout: 30, streamEnabled: false)
        config.imagesGenerationsPath = "/v1/images/generations"
        config.imageGenerationSize = "1024x1024"

        let request = try ChatRequestBuilder.makeImagesGenerationRequest(config: config, prompt: "a cat")
        let payload = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])

        XCTAssertEqual(json["model"] as? String, "grok-imagine-1")
        XCTAssertEqual(json["prompt"] as? String, "a cat")
        XCTAssertEqual(json["aspect_ratio"] as? String, "1:1")
        XCTAssertEqual(json["resolution"] as? String, "1k")
        XCTAssertNil(json["size"])
    }

    func testBuildEmbeddingsRequestUsesConfiguredEndpoint() throws {
        var config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "text-embedding", timeout: 30, streamEnabled: false)
        config.embeddingsPath = "/v1/embeddings"

        let request = try ChatRequestBuilder.makeEmbeddingsRequest(config: config, input: "hello world")
        let payload = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])

        XCTAssertEqual(request.url?.absoluteString, "https://example.com/v1/embeddings")
        XCTAssertEqual(json["model"] as? String, "text-embedding")
        XCTAssertEqual(json["input"] as? String, "hello world")
    }

    func testResponseCleanerRemovesBareImageLinks() {
        let raw = "结论如下\nhttps://example.com/generated-image.png\n请查看"

        let cleaned = ResponseCleaner.cleanAssistantText(raw)

        XCTAssertFalse(cleaned.contains("generated-image.png"))
        XCTAssertTrue(cleaned.contains("结论如下"))
        XCTAssertTrue(cleaned.contains("请查看"))
    }

    func testResponseCleanerPreservesCodeBlocksWhileRemovingMarkdownArtifacts() {
        let raw = """
        # 标题

        **先说结论**
        - 第一条
        - 第二条

        [查看链接](https://example.com)
        ![图](https://example.com/a.png)

        ```swift
        let value = 1
        ```

        ---
        > 引用
        """

        let cleaned = ResponseCleaner.cleanAssistantText(raw)

        XCTAssertFalse(cleaned.contains("# 标题"))
        XCTAssertFalse(cleaned.contains("**"))
        XCTAssertFalse(cleaned.contains("---"))
        XCTAssertFalse(cleaned.contains("!["))
        XCTAssertFalse(cleaned.contains("[查看链接]"))
        XCTAssertFalse(cleaned.contains("> 引用"))
        XCTAssertTrue(cleaned.contains("查看链接"))
        XCTAssertTrue(cleaned.contains("https://example.com"))
        XCTAssertTrue(cleaned.contains("第一条"))
        XCTAssertTrue(cleaned.contains("第二条"))
        XCTAssertTrue(cleaned.contains("```swift"))
        XCTAssertTrue(cleaned.contains("let value = 1"))
    }

    func testMessageContentParserSplitsAssistantCodeBlockIntoDedicatedSegment() {
        let message = ChatMessage(
            role: .assistant,
            content: "分析如下\n```python\nprint(\"hi\")\n```\n执行完成"
        )

        let segments = MessageContentParser.parse(message)

        XCTAssertEqual(
            segments,
            [
                .text("分析如下\n"),
                .code(language: "python", content: "print(\"hi\")"),
                .text("\n执行完成")
            ]
        )
    }

    func testMessageContentParserAfterCleanerStillProducesCodeSegment() {
        let raw = """
        **示例**

        ```swift
        let total = 3
        ```
        """
        let cleaned = ResponseCleaner.cleanAssistantText(raw)
        let message = ChatMessage(role: .assistant, content: cleaned)

        let segments = MessageContentParser.parse(message)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0], .text("示例\n\n"))
        XCTAssertEqual(segments[1], .code(language: "swift", content: "let total = 3"))
    }

    func testMessageContentParserShowsUnclosedCodeFenceAsCodeImmediately() {
        let message = ChatMessage(
            role: .assistant,
            content: "先看代码\n```swift\nprint(\"streaming\")"
        )

        let segments = MessageContentParser.parse(message)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0], .text("先看代码\n"))
        XCTAssertEqual(segments[1], .code(language: "swift", content: "print(\"streaming\")"))
    }

    func testMessageContentParserStripsMarkdownSymbolsInDisplayText() {
        let message = ChatMessage(
            role: .assistant,
            content: "# 标题\n**加粗**\n- 列表项\n> 引用"
        )

        let segments = MessageContentParser.parse(message)
        let text = segments.compactMap { segment -> String? in
            if case .text(let value) = segment { return value }
            return nil
        }.joined()

        XCTAssertFalse(text.contains("#"))
        XCTAssertFalse(text.contains("**"))
        XCTAssertFalse(text.contains("- "))
        XCTAssertFalse(text.contains("> "))
        XCTAssertTrue(text.contains("标题"))
        XCTAssertTrue(text.contains("加粗"))
        XCTAssertTrue(text.contains("列表项"))
        XCTAssertTrue(text.contains("引用"))
    }

    func testMessageContentParserKeepsInlineNonImageURLAsText() {
        let message = ChatMessage(
            role: .assistant,
            content: "百度官网是：https://www.baidu.com"
        )

        let segments = MessageContentParser.parse(message)

        XCTAssertEqual(segments.count, 1)
        guard case .text(let text) = segments[0] else {
            XCTFail("Expected text segment")
            return
        }
        XCTAssertEqual(text, "百度官网是：https://www.baidu.com")
    }

    func testMessageContentParserAfterCleanerKeepsMarkdownLinkURLAsText() {
        let raw = "[百度官网](https://www.baidu.com)"
        let cleaned = ResponseCleaner.cleanAssistantText(raw)
        let message = ChatMessage(role: .assistant, content: cleaned)

        let segments = MessageContentParser.parse(message)

        XCTAssertEqual(segments.count, 1)
        guard case .text(let text) = segments[0] else {
            XCTFail("Expected text segment")
            return
        }
        XCTAssertEqual(text, "百度官网 https://www.baidu.com")
    }

    func testMessageContentParserConvertsNumberedListToBulletList() {
        let message = ChatMessage(
            role: .assistant,
            content: "1) 安装依赖\n2. 最小示例\n3、运行程序"
        )

        let segments = MessageContentParser.parse(message)
        let text = segments.compactMap { segment -> String? in
            if case .text(let value) = segment { return value }
            return nil
        }.joined()

        XCTAssertFalse(text.contains("1)"))
        XCTAssertFalse(text.contains("2."))
        XCTAssertFalse(text.contains("3、"))
        XCTAssertTrue(text.contains("• 安装依赖"))
        XCTAssertTrue(text.contains("• 最小示例"))
        XCTAssertTrue(text.contains("• 运行程序"))
    }

    func testMessageContentParserExpandsGitHubRepositoryRefWithURL() {
        let message = ChatMessage(
            role: .assistant,
            content: "LangChain (langchain-ai/langchain)"
        )

        let segments = MessageContentParser.parse(message)
        let text = segments.compactMap { segment -> String? in
            if case .text(let value) = segment { return value }
            return nil
        }.joined()

        XCTAssertTrue(text.contains("langchain-ai/langchain"))
        XCTAssertTrue(text.contains("https://github.com/langchain-ai/langchain"))
    }

    func testMessageContentParserParsesMarkdownTableIntoDedicatedSegment() {
        let message = ChatMessage(
            role: .assistant,
            content: """
            | 关卡区域 | 主题 | 核心 |
            | --- | --- | --- |
            | 森林区 | 顺序执行 | 语句顺序 |
            | 河流区 | 循环 | for/while |
            """
        )

        let segments = MessageContentParser.parse(message)
        XCTAssertEqual(segments.count, 1)

        guard case .table(let headers, let rows) = segments[0] else {
            XCTFail("Expected table segment")
            return
        }

        XCTAssertEqual(headers, ["关卡区域", "主题", "核心"])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0], ["森林区", "顺序执行", "语句顺序"])
        XCTAssertEqual(rows[1], ["河流区", "循环", "for/while"])
    }

    func testMessageContentParserDoesNotTreatPipeTextWithoutSeparatorAsTable() {
        let message = ChatMessage(
            role: .assistant,
            content: "这里有竖线 A|B|C，但并不是 Markdown 表格。"
        )

        let segments = MessageContentParser.parse(message)
        XCTAssertEqual(segments.count, 1)

        guard case .text(let text) = segments[0] else {
            XCTFail("Expected plain text segment")
            return
        }
        XCTAssertTrue(text.contains("A|B|C"))
    }

    func testMessageContentParserSectionsLongAssistantTextWithDividers() {
        let message = ChatMessage(
            role: .assistant,
            content: """
            第一部分：目标与边界

            我们先把目标说清楚：做一个轻量可玩、当天能跑通核心循环的小项目，不要一开始就把联网、账号、排行榜全部加上。

            第二部分：最小可用玩法

            屏幕出现目标，玩家在限定时间内点击；命中加分，未命中结束。这个循环先做稳定，再加速度曲线和特效。

            第三部分：技术拆分

            先做输入与碰撞，再做状态机和结算页面，最后加资源管理与音效。每一步都单独可验证，避免一次改太多。
            """
        )

        let segments = MessageContentParser.parse(message)
        let dividerCount = segments.reduce(0) { partial, segment in
            if case .divider = segment { return partial + 1 }
            return partial
        }

        XCTAssertGreaterThanOrEqual(dividerCount, 1)
        XCTAssertTrue(segments.contains { segment in
            if case .text(let value) = segment {
                return value.contains("第一部分")
            }
            return false
        })
    }

    func testMessageContentParserTurnsTSVCodeBlockIntoTableSegment() {
        let message = ChatMessage(
            role: .assistant,
            content: """
            ```tsv
            产品\t一月\t二月
            A\t100\t120
            B\t80\t90
            ```
            """
        )

        let segments = MessageContentParser.parse(message)
        XCTAssertEqual(segments.count, 1)
        guard case .table(let headers, let rows) = segments[0] else {
            XCTFail("Expected table segment from tsv code block")
            return
        }
        XCTAssertEqual(headers, ["产品", "一月", "二月"])
        XCTAssertEqual(rows, [["A", "100", "120"], ["B", "80", "90"]])
    }

    func testMessageContentParserInfersPythonLanguageForCodeBlockWithoutLabel() {
        let message = ChatMessage(
            role: .assistant,
            content: """
            ```
            def add(a, b):
                return a + b
            ```
            """
        )

        let segments = MessageContentParser.parse(message)
        XCTAssertEqual(segments.count, 1)
        guard case .code(let language, let content) = segments[0] else {
            XCTFail("Expected code segment")
            return
        }
        XCTAssertEqual(language?.lowercased(), "python")
        XCTAssertTrue(content.contains("def add"))
    }
}

final class ChatViewModelTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    @MainActor
    func testRefreshAvailableModelsMarksCurrentModelAvailableOnlyAfterSuccessfulValidation() async throws {
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/models")
            let body = "{\"data\":[{\"id\":\"gpt-test\"},{\"id\":\"other\"}]}"
            let data = try XCTUnwrap(body.data(using: .utf8))
            let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil))
            return (response, data)
        }

        let viewModel = ChatViewModel(service: makeStubbedService())
        viewModel.config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: true)

        XCTAssertFalse(viewModel.hasValidatedModelList)
        XCTAssertFalse(viewModel.isCurrentModelAvailable)

        await viewModel.refreshAvailableModels()

        XCTAssertTrue(viewModel.hasValidatedModelList)
        XCTAssertEqual(viewModel.availableModels, ["gpt-test", "other"])
        XCTAssertTrue(viewModel.isCurrentModelAvailable)
    }

    @MainActor
    func testRefreshAvailableModelsFailureKeepsModelUnavailable() async {
        URLProtocolStub.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 500, httpVersion: nil, headerFields: nil))
            return (response, Data())
        }

        let viewModel = ChatViewModel(service: makeStubbedService())
        viewModel.config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: true)

        await viewModel.refreshAvailableModels()

        XCTAssertFalse(viewModel.hasValidatedModelList)
        XCTAssertTrue(viewModel.availableModels.isEmpty)
        XCTAssertFalse(viewModel.isCurrentModelAvailable)
    }

    @MainActor
    func testRefreshAvailableModelsDoesNotAutoSwitchCurrentModel() async throws {
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/models")
            let body = "{\"data\":[{\"id\":\"gpt-test\"},{\"id\":\"other\"}]}"
            let data = try XCTUnwrap(body.data(using: .utf8))
            let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil))
            return (response, data)
        }

        let viewModel = ChatViewModel(service: makeStubbedService())
        viewModel.config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "custom-model", timeout: 30, streamEnabled: true)

        await viewModel.refreshAvailableModels()

        XCTAssertEqual(viewModel.config.model, "custom-model")
        XCTAssertEqual(viewModel.availableModels, ["gpt-test", "other"])
        XCTAssertFalse(viewModel.isCurrentModelAvailable)
        XCTAssertTrue(viewModel.hasValidatedModelList)
    }

    private func makeStubbedService() -> ChatService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        return ChatService(session: session)
    }
}

private final class URLProtocolStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
