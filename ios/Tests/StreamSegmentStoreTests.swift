import XCTest
@testable import ChatApp

final class StreamSegmentStoreTests: XCTestCase {
    func testSegmentAppendAndRecentText() {
        let store = StreamSegmentStore(segmentCharacterLimit: 5, maxArchivedCharacters: 100)
        store.append("hello")
        store.append("world")
        store.append("swift")

        let snapshot = store.snapshot()
        XCTAssertGreaterThanOrEqual(snapshot.segmentCount, 3)
        XCTAssertEqual(store.recentText(maxCharacters: 6, includeDropNotice: false), "swift")
    }

    func testStoreTrimsOverflow() {
        let store = StreamSegmentStore(segmentCharacterLimit: 5, maxArchivedCharacters: 12)
        store.append("12345")
        store.append("67890")
        store.append("abcde")

        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.totalArchivedCharacters, 12)
        XCTAssertEqual(snapshot.droppedCharacters, 3)

        let all = store.allText(includeDropNotice: false)
        XCTAssertEqual(all, "4567890abcde")
    }
}

