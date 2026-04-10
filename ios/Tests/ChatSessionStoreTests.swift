import XCTest
@testable import ChatApp

final class ChatSessionStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ChatSessionStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        if let defaults {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testSaveAndLoadMessages() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let source = [
            ChatMessage(role: .user, content: "hello", createdAt: now),
            ChatMessage(role: .assistant, content: "world", createdAt: now, isStreaming: false)
        ]

        ChatSessionStore.save(source, to: defaults)
        let loaded = ChatSessionStore.load(from: defaults)

        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.map(\.role), [.user, .assistant])
        XCTAssertEqual(loaded.map(\.content), ["hello", "world"])
    }

    func testResetClearsMessages() {
        ChatSessionStore.save([ChatMessage(role: .user, content: "x")], to: defaults)
        ChatSessionStore.reset(from: defaults)

        XCTAssertTrue(ChatSessionStore.load(from: defaults).isEmpty)
    }
}
