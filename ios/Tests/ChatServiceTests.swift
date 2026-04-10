import XCTest
@testable import ChatApp

final class ChatServiceTests: XCTestCase {
    func testBuildRequestIncludesModelMessagesAndStreamFlag() throws {
        let config = ChatConfig(apiURL: "https://example.com/v1/chat/completions", apiKey: "token-123", model: "gpt-test", timeout: 30, streamEnabled: true)
        let history = [ChatMessage(role: .assistant, content: "history")]

        let request = try ChatRequestBuilder.makeRequest(config: config, history: history, message: "hello")
        let payload = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])

        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-123")
        XCTAssertEqual(json["model"] as? String, "gpt-test")
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.last?["content"], "hello")
    }
}
