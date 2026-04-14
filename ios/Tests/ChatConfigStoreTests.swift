import XCTest
@testable import ChatApp

final class ChatConfigStoreTests: XCTestCase {
    func testNormalizeBaseURLAddsSchemeAndRemovesCompletionPath() {
        XCTAssertEqual(
            ChatConfigStore.normalizedBaseURL("example.com/v1/chat/completions"),
            "https://example.com"
        )
    }

    func testNormalizeBaseURLRemovesImagesPath() {
        XCTAssertEqual(
            ChatConfigStore.normalizedBaseURL("https://example.com/v1/images/generations"),
            "https://example.com"
        )
    }

    func testCompletionsURLBuildsEndpointFromBase() {
        XCTAssertEqual(
            ChatConfigStore.completionsURL("https://api.example.com"),
            "https://api.example.com/v1/chat/completions"
        )
    }

    func testDecodeLegacyConfigDefaultsRealtimeFields() throws {
        let legacyJSON = """
        {
          "apiURL": "https://example.com",
          "apiKey": "",
          "model": "gpt-test",
          "timeout": 30,
          "streamEnabled": true,
          "themeMode": "system",
          "codeThemeMode": "followApp"
        }
        """

        let data = try XCTUnwrap(legacyJSON.data(using: .utf8))
        let config = try JSONDecoder().decode(ChatConfig.self, from: data)

        XCTAssertTrue(config.realtimeContextEnabled)
        XCTAssertTrue(config.weatherContextEnabled)
        XCTAssertEqual(config.weatherLocation, "Shanghai")
        XCTAssertTrue(config.marketContextEnabled)
        XCTAssertTrue(config.hotNewsContextEnabled)
        XCTAssertEqual(config.hotNewsCount, 6)
        XCTAssertEqual(config.endpointMode, .chatCompletions)
        XCTAssertEqual(config.imagesGenerationsPath, "/v1/images/generations")
    }
}
