import XCTest
@testable import ChatApp

final class StreamParserTests: XCTestCase {
    func testParseDeltaChunk() {
        let line = "data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}"
        let chunk = StreamParser.parse(line: line)

        XCTAssertEqual(chunk?.delta, "Hi")
        XCTAssertEqual(chunk?.isDone, false)
    }

    func testParseDoneChunk() {
        let chunk = StreamParser.parse(line: "data: [DONE]")
        XCTAssertEqual(chunk?.isDone, true)
        XCTAssertNil(chunk?.delta)
    }
}
