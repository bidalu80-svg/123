import XCTest
@testable import ChatApp

final class MessageContentParserTests: XCTestCase {
    func testParsePreservesLeadingIndentationInsideFencedPythonCodeBlock() {
        let message = ChatMessage(
            role: .assistant,
            content: """
            ```python
                result = do_work()
                print(result)
            ```
            """
        )

        let segments = MessageContentParser.parse(message)
        guard case let .code(language, content)? = segments.first else {
            return XCTFail("Expected code segment")
        }

        XCTAssertEqual(language, "python")
        XCTAssertTrue(content.hasPrefix("    result = do_work()"))
        XCTAssertTrue(content.contains("\n    print(result)"))
    }

    func testParsePreservesLeadingIndentationInsideTaggedYamlFile() {
        let message = ChatMessage(
            role: .assistant,
            content: """
            [[file:config.yaml]]
              service:
                port: 8080
                host: localhost
            [[endfile]]
            """
        )

        let segments = MessageContentParser.parse(message)
        guard case let .file(name, language, content)? = segments.first(where: {
            if case .file = $0 { return true }
            return false
        }) else {
            return XCTFail("Expected file segment")
        }

        XCTAssertEqual(name, "config.yaml")
        XCTAssertEqual(language, "yaml")
        XCTAssertTrue(content.hasPrefix("  service:"))
        XCTAssertTrue(content.contains("\n    port: 8080"))
    }

    func testFileAttachmentPreviewTextPreservesLeadingIndentationInsideFencedCode() {
        let attachment = ChatFileAttachment(
            fileName: "script.py",
            mimeType: "text/x-python",
            textContent: """
            ```python
                if True:
                    print("ok")
            ```
            """
        )

        XCTAssertTrue(attachment.previewText.hasPrefix("    if True:"))
        XCTAssertTrue(attachment.previewText.contains("\n        print(\"ok\")"))
    }

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

    func testParseKeepsInlineCommentedCodeInsideFencedCodeBlock() {
        let message = ChatMessage(
            role: .assistant,
            content: """
            ```python
            import sys

            a = [1, 2, 3]  # 创建列表对象，引用计数为 1
            print(sys.getrefcount(a))  # 注意：getrefcount 本身会临时增加一次引用

            b = a  # b 指向同一对象，引用计数 +1
            print(sys.getrefcount(a))

            这说明两个变量都指向同一个对象。
            真正的数据在对象本身上。
            ```
            """
        )

        let segments = MessageContentParser.parse(message)

        XCTAssertEqual(segments.count, 2)
        guard case let .code(language, content) = segments[0] else {
            return XCTFail("Expected first segment to remain a code block")
        }
        XCTAssertEqual(language, "python")
        XCTAssertTrue(content.contains("a = [1, 2, 3]  # 创建列表对象"))
        XCTAssertTrue(content.contains("print(sys.getrefcount(a))  # 注意"))
        XCTAssertTrue(content.contains("b = a  # b 指向同一对象"))

        guard case let .text(text) = segments[1] else {
            return XCTFail("Expected trailing explanation to render as text")
        }
        XCTAssertTrue(text.contains("这说明两个变量都指向同一个对象。"))
        XCTAssertTrue(text.contains("真正的数据在对象本身上。"))
    }

    func testParseSplitsInlineNarrationSuffixOutOfCodeLine() {
        let message = ChatMessage(
            role: .assistant,
            content: """
            ```python
            b = a
            print(b)。动态类型（鸭子类型）
            变量不需要声明类型，可以随时指向不同类型的对象。
            ```
            """
        )

        let segments = MessageContentParser.parse(message)

        XCTAssertEqual(segments.count, 2)
        guard case let .code(language, content) = segments[0] else {
            return XCTFail("Expected code segment first")
        }
        XCTAssertEqual(language, "python")
        XCTAssertTrue(content.contains("b = a"))
        XCTAssertTrue(content.contains("print(b)"))
        XCTAssertFalse(content.contains("动态类型"))

        guard case let .text(text) = segments[1] else {
            return XCTFail("Expected narration segment second")
        }
        XCTAssertTrue(text.contains("动态类型（鸭子类型）"))
        XCTAssertTrue(text.contains("变量不需要声明类型"))
    }

    func testParseKeepsExampleHeadingOutsideCodeAndMergesImplicitExampleRun() {
        let message = ChatMessage(
            role: .assistant,
            content: """
            Python 代码：

            ```python
            for right, ch in enumerate(s):
                if ch in last and last[ch] >= left:
                    left = last[ch] + 1
                last[ch] = right
                ans = max(ans, right - left + 1)

            return ans

            **例子：**
            ```

            python
            s = "abcbb"
            print(lengthOfLongestSubstring(s)) # 3
            """
        )

        let segments = MessageContentParser.parse(message)

        XCTAssertTrue(segments.contains {
            if case let .text(text) = $0 {
                return text.contains("Python 代码：")
            }
            return false
        })

        XCTAssertTrue(segments.contains {
            if case let .text(text) = $0 {
                return text.contains("例子：")
            }
            return false
        })

        let codeSegments = segments.compactMap { segment -> (String?, String)? in
            if case let .code(language, content) = segment {
                return (language, content)
            }
            return nil
        }

        XCTAssertEqual(codeSegments.count, 2)
        XCTAssertEqual(codeSegments.first?.0, "python")
        XCTAssertTrue(codeSegments.first?.1.contains("for right, ch in enumerate(s):") == true)
        XCTAssertFalse(codeSegments.first?.1.contains("例子：") == true)

        XCTAssertEqual(codeSegments.last?.0, "python")
        XCTAssertTrue(codeSegments.last?.1.contains(#"s = "abcbb""#) == true)
        XCTAssertTrue(codeSegments.last?.1.contains("print(lengthOfLongestSubstring(s)) # 3") == true)
    }
}
