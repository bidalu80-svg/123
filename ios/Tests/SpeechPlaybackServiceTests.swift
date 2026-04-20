import XCTest
@testable import ChatApp

@MainActor
final class SpeechPlaybackServiceTests: XCTestCase {
    func testSpeakableTextReplacesTaggedFilesWithCodeMarker() {
        let message = ChatMessage(
            role: .assistant,
            content: """
            这是页面说明。

            [[file:index.html]]
            <!doctype html>
            <html><body>Hello</body></html>
            [[endfile]]

            完成后可以直接预览。
            """
        )

        let text = SpeechPlaybackService.speakableText(from: message)

        XCTAssertTrue(text.contains("这是页面说明"))
        XCTAssertTrue(text.contains("代码片段"))
        XCTAssertTrue(text.contains("完成后可以直接预览"))
        XCTAssertFalse(text.contains("<html>"))
    }

    func testNormalizedSpeechTextReplacesLinksAndCodeFences() {
        let raw = """
        查看这个链接：https://example.com

        ```python
        print("hello")
        ```
        """

        let text = SpeechPlaybackService.normalizedSpeechText(from: raw)

        XCTAssertTrue(text.contains("链接"))
        XCTAssertTrue(text.contains("代码片段"))
        XCTAssertFalse(text.contains("https://example.com"))
        XCTAssertFalse(text.contains("print(\"hello\")"))
    }
}
