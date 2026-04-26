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

    func testParseNonSSEJsonLine() {
        let line = "{\"choices\":[{\"message\":{\"content\":[{\"type\":\"image_url\",\"image_url\":{\"url\":\"https://cdn.example.com/pic.png\"}}]}}]}"
        let chunk = StreamParser.parse(line: line)

        XCTAssertEqual(chunk?.isDone, false)
        XCTAssertEqual(chunk?.imageURLs, ["https://cdn.example.com/pic.png"])
    }

    func testParseTextContentExtractsBareImageURL() {
        let line = #"{"choices":[{"message":{"content":"这是图片\nhttps://cdn.example.com/pic.webp"}}]}"#
        let chunk = StreamParser.parse(line: line)

        XCTAssertEqual(chunk?.isDone, false)
        XCTAssertEqual(chunk?.imageURLs, ["https://cdn.example.com/pic.webp"])
    }

    func testParseMarkdownImageWithoutExtension() {
        let line = #"{"choices":[{"message":{"content":"![img](https://cdn.example.com/generate/abc123?token=1)"}}]}"#
        let chunk = StreamParser.parse(line: line)

        XCTAssertEqual(chunk?.isDone, false)
        XCTAssertEqual(chunk?.imageURLs, ["https://cdn.example.com/generate/abc123?token=1"])
    }

    func testParseStandaloneBareURLWithoutImageSuffix() {
        let line = #"{"choices":[{"message":{"content":"https://cdn.example.com/generated/abc123?token=1"}}]}"#
        let chunk = StreamParser.parse(line: line)

        XCTAssertEqual(chunk?.isDone, false)
        XCTAssertEqual(chunk?.imageURLs, ["https://cdn.example.com/generated/abc123?token=1"])
    }

    func testParseDataImageURL() {
        let line = #"{"choices":[{"message":{"content":"data:image/png;base64,abc123=="}}]}"#
        let chunk = StreamParser.parse(line: line)

        XCTAssertEqual(chunk?.isDone, false)
        XCTAssertEqual(chunk?.imageURLs, ["data:image/png;base64,abc123=="])
    }

    func testParseTextContentExtractsAVIFBareImageURL() {
        let line = #"{"choices":[{"message":{"content":"请看图：\nhttps://cdn.example.com/out/final.avif"}}]}"#
        let chunk = StreamParser.parse(line: line)

        XCTAssertEqual(chunk?.isDone, false)
        XCTAssertEqual(chunk?.imageURLs, ["https://cdn.example.com/out/final.avif"])
    }

    func testParseTextContentExtractsUnsplashBareImageURLWithoutSuffix() {
        let line = #"{"choices":[{"message":{"content":"Ferrari 488:\nhttps://images.unsplash.com/photo-1542362567-b07e54358753"}}]}"#
        let chunk = StreamParser.parse(line: line)

        XCTAssertEqual(chunk?.isDone, false)
        XCTAssertEqual(chunk?.imageURLs, ["https://images.unsplash.com/photo-1542362567-b07e54358753"])
    }

    func testParseTextContentDoesNotTreatUnsplashSourcePageAsImage() {
        let line = #"{"choices":[{"message":{"content":"来源：\nhttps://unsplash.com/s/photos/sports-car"}}]}"#
        let chunk = StreamParser.parse(line: line)

        XCTAssertEqual(chunk?.isDone, false)
        XCTAssertEqual(chunk?.imageURLs, [])
    }

    func testParseMarkdownImageTrimsTrailingSourceURLNoise() {
        let line = #"{"choices":[{"message":{"content":"![car](https://images.unsplash.com/photo-1546331-e26879cd4d9b?q=80&w=120&auto=format&fit=crop https://unsplash.com/s/photos/sports-car)"}}]}"#
        let chunk = StreamParser.parse(line: line)

        XCTAssertEqual(chunk?.isDone, false)
        XCTAssertEqual(
            chunk?.imageURLs,
            ["https://images.unsplash.com/photo-1546331-e26879cd4d9b?q=80&w=120&auto=format&fit=crop"]
        )
    }

    func testExtractPayloadSupportsImageDataArray() {
        let payload: [String: Any] = [
            "data": [
                ["url": "https://cdn.example.com/gen-image"]
            ]
        ]

        let extracted = StreamParser.extractPayload(from: payload)
        XCTAssertEqual(extracted.text, "")
        XCTAssertEqual(extracted.imageURLs, ["https://cdn.example.com/gen-image"])
    }

    func testExtractPayloadSupportsNestedImageURLB64() {
        let payload: [String: Any] = [
            "data": [
                ["image_url": ["b64_json": "abc123"]]
            ]
        ]

        let extracted = StreamParser.extractPayload(from: payload)
        XCTAssertEqual(extracted.text, "")
        XCTAssertEqual(extracted.imageURLs, ["data:image/png;base64,abc123"])
    }
}
