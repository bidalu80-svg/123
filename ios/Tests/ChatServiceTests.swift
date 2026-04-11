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

    func testBuildRequestSupportsImageAttachment() throws {
        let config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: false)
        let attachment = ChatImageAttachment(dataURL: "data:image/png;base64,abcd", mimeType: "image/png")
        let requestMessage = ChatMessage(role: .user, content: "describe this", imageAttachments: [attachment])

        let request = try ChatRequestBuilder.makeRequest(config: config, history: [], message: requestMessage)
        let payload = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let first = try XCTUnwrap(messages.first)
        let content = try XCTUnwrap(first["content"] as? [[String: Any]])

        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["type"] as? String, "text")
        XCTAssertEqual(content[1]["type"] as? String, "image_url")
    }
}
