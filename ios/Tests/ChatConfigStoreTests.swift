import XCTest
@testable import ChatApp

final class ChatConfigStoreTests: XCTestCase {
    override func tearDown() {
        ChatConfigStore.reset()
        super.tearDown()
    }

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

    func testShellExecutionURLBuildsEndpointFromConfiguredPath() {
        var config = ChatConfig(apiURL: "https://chat.example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: true)
        config.shellExecutionPath = "http://192.168.1.20:8787/v1/mcp/call_tool"

        XCTAssertEqual(
            config.shellExecutionURLString,
            "http://192.168.1.20:8787/v1/mcp/call_tool"
        )
    }

    func testShellExecutionURLUsesDefaultMCPBridgePathWhenNotOverridden() {
        let config = ChatConfig(apiURL: "https://chat.example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: true)

        XCTAssertEqual(
            config.shellExecutionURLString,
            "https://chat.example.com/v1/mcp/call_tool"
        )
    }

    func testResolvedShellExecutionAPIKeyFallsBackToMainAPIKey() {
        var config = ChatConfig(apiURL: "https://example.com", apiKey: "chat-token", model: "gpt-test", timeout: 30, streamEnabled: true)
        XCTAssertEqual(config.resolvedShellExecutionAPIKey, "chat-token")

        config.shellExecutionAPIKey = "shell-token"
        XCTAssertEqual(config.resolvedShellExecutionAPIKey, "shell-token")
    }

    func testRemotePythonExecutionURLUsesExplicitFullURLWhenConfigured() {
        var config = ChatConfig(apiURL: "https://chat.example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: true)
        config.remotePythonExecutionEnabled = true
        config.remotePythonExecutionPath = "https://runner.example.com/v1/python/execute"

        XCTAssertEqual(
            config.remotePythonExecutionURLString,
            "https://runner.example.com/v1/python/execute"
        )
    }

    func testRemotePythonExecutionURLIsEmptyWhenNotConfigured() {
        let config = ChatConfig(apiURL: "https://chat.example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: true)

        XCTAssertEqual(config.remotePythonExecutionURLString, "")
    }

    func testEffectiveRemotePythonExecutionURLFallsBackToBuiltInShellRunner() {
        let config = ChatConfig(apiURL: "https://chat.example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: true)

        XCTAssertEqual(
            config.effectiveRemotePythonExecutionURLString,
            ChatConfig.defaultBuiltInRemotePythonShellExecuteURL
        )
    }

    func testResolvedRemotePythonExecutionAPIKeyPrefersDedicatedKey() {
        var config = ChatConfig(apiURL: "https://example.com", apiKey: "chat-token", model: "gpt-test", timeout: 30, streamEnabled: true)
        XCTAssertEqual(config.resolvedRemotePythonExecutionAPIKey, "")

        config.remotePythonExecutionPath = "https://runner.example.com/v1/python/execute"
        XCTAssertEqual(config.resolvedRemotePythonExecutionAPIKey, "chat-token")
        config.remotePythonExecutionAPIKey = "remote-token"
        XCTAssertEqual(config.resolvedRemotePythonExecutionAPIKey, "remote-token")
    }

    func testNormalizeConfigDisablesLegacyAutoRemotePythonPathOnCustomChatHost() {
        let legacy = ChatConfig(
            apiURL: "https://cdn.mynav.website",
            apiKey: "chat-token",
            model: "gpt-test",
            timeout: 30,
            streamEnabled: true,
            remotePythonExecutionEnabled: true,
            remotePythonExecutionPath: ChatConfig.legacyAutoRemotePythonExecutionPath
        )

        ChatConfigStore.save(legacy)
        let normalized = ChatConfigStore.load()

        XCTAssertTrue(normalized.remotePythonExecutionEnabled)
        XCTAssertEqual(normalized.remotePythonExecutionPath, "")
        XCTAssertEqual(normalized.remotePythonExecutionURLString, "")
        XCTAssertEqual(
            normalized.effectiveRemotePythonExecutionURLString,
            ChatConfig.defaultBuiltInRemotePythonShellExecuteURL
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
        XCTAssertTrue(config.remotePythonExecutionEnabled)
        XCTAssertEqual(config.endpointMode, .chatCompletions)
        XCTAssertEqual(config.imagesGenerationsPath, "/v1/images/generations")
    }
}
