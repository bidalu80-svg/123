import XCTest
@testable import ChatApp

final class ChatConfigStoreTests: XCTestCase {
    func testNormalizeURLAddsScheme() {
        XCTAssertEqual(
            ChatConfigStore.normalizedURL("example.com/v1/chat/completions"),
            "https://example.com/v1/chat/completions"
        )
    }
}
