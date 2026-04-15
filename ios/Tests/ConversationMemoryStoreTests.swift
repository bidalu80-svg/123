import XCTest
@testable import ChatApp

final class ConversationMemoryStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ConversationMemoryStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testListAndRemoveMemoryEntries() async {
        let store = ConversationMemoryStore(defaults: defaults, maxEntries: 20, maxEntryLength: 180, maxContextItems: 10)
        await store.remember(ChatMessage(role: .user, content: "请记住我喜欢简洁回答"))
        await store.remember(ChatMessage(role: .user, content: "请记住我住在上海"))

        let items = await store.listEntries()
        XCTAssertEqual(items.count, 2)

        if let first = items.first {
            await store.removeEntry(id: first.id)
        }

        let remaining = await store.listEntries()
        XCTAssertEqual(remaining.count, 1)
    }

    func testResetClearsAllMemoryEntries() async {
        let store = ConversationMemoryStore(defaults: defaults)
        await store.remember(ChatMessage(role: .user, content: "请记住我喜欢 Swift"))
        XCTAssertFalse(await store.listEntries().isEmpty)

        await store.reset()

        let items = await store.listEntries()
        XCTAssertTrue(items.isEmpty)
        XCTAssertNil(await store.buildSystemContext())
    }
}
