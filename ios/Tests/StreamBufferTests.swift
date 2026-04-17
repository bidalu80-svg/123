import XCTest
@testable import ChatApp

final class StreamBufferTests: XCTestCase {
    func testAppendConsumePreservesOrder() {
        let buffer = StreamBuffer(maxBufferedCharacters: 10_000)
        buffer.append("abc")
        buffer.append("def")
        buffer.append("ghi")

        let consumed = buffer.consume()
        XCTAssertEqual(consumed.joined(), "abcdefghi")
        XCTAssertTrue(buffer.isEmpty)
    }

    func testConsumeWithCharacterLimitSplitsChunk() {
        let buffer = StreamBuffer(maxBufferedCharacters: 10_000)
        buffer.append("hello")
        buffer.append("world")

        let first = buffer.consume(maxCharacters: 7).joined()
        let second = buffer.consume().joined()

        XCTAssertEqual(first, "hellowo")
        XCTAssertEqual(second, "rld")
    }

    func testBufferDropsOldestWhenOverflow() {
        let buffer = StreamBuffer(maxBufferedCharacters: 10)
        buffer.append("12345")
        buffer.append("67890")
        buffer.append("abcde") // overflow, oldest chunk should be dropped

        let snapshot = buffer.snapshot()
        XCTAssertGreaterThan(snapshot.droppedCharacters, 0)

        let remaining = buffer.consume().joined()
        XCTAssertEqual(remaining, "67890abcde")
    }
}

