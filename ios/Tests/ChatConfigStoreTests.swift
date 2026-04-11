import XCTest
@testable import ChatApp

final class ChatConfigStoreTests: XCTestCase {
    func testNormalizeBaseURLAddsSchemeAndRemovesCompletionPath() {
        XCTAssertEqual(
            ChatConfigStore.normalizedBaseURL("example.com/v1/chat/completions"),
            "https://example.com"
        )
    }

    func testCompletionsURLBuildsEndpointFromBase() {
        XCTAssertEqual(
            ChatConfigStore.completionsURL("https://api.example.com"),
            "https://api.example.com/v1/chat/completions"
        )
    }
}
