import XCTest
@testable import ChatApp

final class StreamParserTests: XCTestCase {
    func testParseDeltaChunk() {
        let line = "data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}"
        let chunk = StreamParser.parse(line: line)

        XCTAssertEqual(chunk?.deltaText, "Hi")
        XCTAssertEqual(chunk?.isDone, false)
    }

    func testParseDoneChunk() {
        let chunk = StreamParser.parse(line: "data: [DONE]")
        XCTAssertEqual(chunk?.isDone, true)
        XCTAssertEqual(chunk?.deltaText, "")
    }
}
