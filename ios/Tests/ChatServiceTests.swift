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
        let last = try XCTUnwrap(messages.last)

        XCTAssertEqual(request.url?.absoluteString, "https://example.com/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-123")
        XCTAssertEqual(json["model"] as? String, "gpt-test")
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(last["content"] as? String, "hello")
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
