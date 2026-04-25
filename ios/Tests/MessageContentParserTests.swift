import XCTest
@testable import ChatApp

final class MessageContentParserTests: XCTestCase {
    func testParseRendersTaggedFileBlockAsFileSegment() {
        let message = ChatMessage(
            role: .assistant,
            content: """
            下面是项目文件：

            [[file:index.html]]
            <!doctype html>
            <html>
            <body>Hello</body>
            </html>
            [[endfile]]
            """
        )

        let segments = MessageContentParser.parse(message)
        XCTAssertTrue(segments.contains(where: {
            if case let .text(text) = $0 {
                return text.contains("下面是项目文件：")
            }
            return false
        }))

        guard case let .file(name, language, content)? = segments.first(where: {
            if case .file = $0 { return true }
            return false
        }) else {
            return XCTFail("Expected tagged file block to render as file segment")
        }

        XCTAssertEqual(name, "index.html")
        XCTAssertEqual(language, "html")
        XCTAssertTrue(content.contains("<body>Hello</body>"))
    }

    func testParseKeepsTrailingTextAfterTaggedFileBlock() {
        let message = ChatMessage(
            role: .assistant,
            content: """
            [[file:main.py]]
            print("ok")
            [[endfile]]

            运行后会输出 ok。
            """
        )

        let segments = MessageContentParser.parse(message)
        XCTAssertTrue(segments.contains(where: {
            if case let .file(name, language, content) = $0 {
                return name == "main.py" && language == "python" && content.contains("print(\"ok\")")
            }
            return false
        }))
        XCTAssertTrue(segments.contains(where: {
            if case let .text(text) = $0 {
                return text.contains("运行后会输出 ok。")
            }
            return false
        }))
    }

    func testParseUnwrapsSingleFencedCodeInsideTaggedFile() {
        let message = ChatMessage(
            role: .assistant,
            content: """
            [[file:index.html]]
            ```html
            <!doctype html>
            <html><body>Hello</body></html>
            ```
            [[endfile]]
            """
        )

        let segments = MessageContentParser.parse(message)
        guard case let .file(name, language, content)? = segments.first(where: {
            if case .file = $0 { return true }
            return false
        }) else {
            return XCTFail("Expected tagged file block to render as file segment")
        }

        XCTAssertEqual(name, "index.html")
        XCTAssertEqual(language, "html")
        XCTAssertFalse(content.contains("```html"))
        XCTAssertFalse(content.contains("```"))
        XCTAssertTrue(content.contains("<body>Hello</body>"))
    }

    func testParseUnwrapsSingleFencedCodeInsideFileAttachment() {
        let message = ChatMessage(
            role: .assistant,
            content: "",
            fileAttachments: [
                ChatFileAttachment(
                    fileName: "index.html",
                    mimeType: "text/html",
                    textContent: """
                    ```html
                    <!doctype html>
                    <html><body>Hello</body></html>
                    ```
                    """
                )
            ]
        )

        let segments = MessageContentParser.parse(message)
        guard case let .file(name, language, content)? = segments.first(where: {
            if case .file = $0 { return true }
            return false
        }) else {
            return XCTFail("Expected file attachment to render as file segment")
        }

        XCTAssertEqual(name, "index.html")
        XCTAssertEqual(language, "html")
        XCTAssertFalse(content.contains("```html"))
        XCTAssertFalse(content.contains("```"))
        XCTAssertTrue(content.contains("<body>Hello</body>"))
    }

    func testParseSplitsNarrationOutOfMixedFencedCodeBlock() {
        let message = ChatMessage(
            role: .assistant,
            content: """
            ```python
            x = 10
            x = "hello"
            x = [1, 2, 3]

            这都是允许的。

            本质上，变量名只是一个“引用”，指向某个对象。
            ```
            """
        )

        let segments = MessageContentParser.parse(message)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(
            segments[0],
            .code(
                language: "python",
                content: """
                x = 10
                x = "hello"
                x = [1, 2, 3]
                """
            )
        )

        guard case let .text(text) = segments[1] else {
            return XCTFail("Expected trailing narration to render as text")
        }
        XCTAssertTrue(text.contains("这都是允许的。"))
        XCTAssertTrue(text.contains("变量名只是一个“引用”"))
    }
}
