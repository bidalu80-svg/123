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

    func testSaveAndLoadSessions() {
        let session = ChatSession(
            title: "测试",
            messages: [
                ChatMessage(role: .user, content: "hello"),
                ChatMessage(role: .assistant, content: "world")
            ]
        )

        ChatSessionStore.saveSessions([session], currentSessionID: session.id, to: defaults)
        let loaded = ChatSessionStore.loadSessions(from: defaults)
        let currentID = ChatSessionStore.loadCurrentSessionID(from: defaults)

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.messages.count, 2)
        XCTAssertEqual(currentID, session.id)
    }

    func testResetClearsSessions() {
        let session = ChatSession(title: "x")
        ChatSessionStore.saveSessions([session], currentSessionID: session.id, to: defaults)
        ChatSessionStore.reset(from: defaults)

        XCTAssertTrue(ChatSessionStore.loadSessions(from: defaults).isEmpty)
        XCTAssertNil(ChatSessionStore.loadCurrentSessionID(from: defaults))
    }
}
