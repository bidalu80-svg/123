import XCTest
@testable import ChatApp

final class FrontendProjectBuilderTests: XCTestCase {
    override func tearDownWithError() throws {
        try? FrontendProjectBuilder.clearLatestProject()
        try super.tearDownWithError()
    }

    func testBuildProjectFromHtmlCssJsLanguageBlocksWritesConnectedThreeFiles() throws {
        let message = ChatMessage(
            role: .assistant,
            content: """
            ```html
            <!doctype html>
            <html lang="en">
            <head>
              <meta charset="utf-8">
              <meta name="viewport" content="width=device-width, initial-scale=1">
              <link rel="stylesheet" href="styles.css">
            </head>
            <body>
              <h1 id="title">Hello</h1>
              <script src="script.js"></script>
            </body>
            </html>
            ```
            ```css
            body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; }
            h1 { color: #2563eb; }
            ```
            ```javascript
            document.getElementById('title').textContent = 'Ready';
            ```
            """
        )

        let result = try FrontendProjectBuilder.buildProject(from: message, mode: .createNewProject)

        XCTAssertEqual(result.entryFileURL.lastPathComponent.lowercased(), "index.html")
        XCTAssertTrue(result.writtenRelativePaths.contains("index.html"))
        XCTAssertTrue(result.writtenRelativePaths.contains("styles.css"))
        XCTAssertTrue(result.writtenRelativePaths.contains("script.js"))
        XCTAssertFalse(result.writtenRelativePaths.contains(where: { $0.contains("<") || $0.contains(">") }))

        let projectURL = result.projectDirectoryURL
        let indexURL = projectURL.appendingPathComponent("index.html")
        let stylesURL = projectURL.appendingPathComponent("styles.css")
        let scriptURL = projectURL.appendingPathComponent("script.js")

        XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stylesURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: scriptURL.path))

        let indexHTML = try String(contentsOf: indexURL, encoding: .utf8)
        XCTAssertTrue(indexHTML.contains("styles.css"))
        XCTAssertTrue(indexHTML.contains("script.js"))
    }

    func testBuildProjectFromPHPBlockCreatesIndexPHPEntry() throws {
        let message = ChatMessage(
            role: .assistant,
            content: """
            ```php
            <?php
            $db = new PDO('sqlite:/persist/project/data/app.db');
            echo "<!doctype html><html><body><h1>PHP OK</h1></body></html>";
            ```
            """
        )

        let result = try FrontendProjectBuilder.buildProject(from: message, mode: .createNewProject)

        XCTAssertEqual(result.entryFileURL.lastPathComponent.lowercased(), "index.php")
        XCTAssertTrue(result.writtenRelativePaths.contains("index.php"))

        let entryText = try String(contentsOf: result.entryFileURL, encoding: .utf8)
        XCTAssertTrue(entryText.contains("sqlite:"))
    }

    func testLatestEntryFileURLPrefersIndexHTMLWhenPresent() throws {
        try FrontendProjectBuilder.clearLatestProject()
        let latest = try XCTUnwrap(FrontendProjectBuilder.latestProjectURL())
        let indexURL = latest.appendingPathComponent("index.html")
        let otherURL = latest.appendingPathComponent("landing.html")

        try "<!doctype html><html><body>OK</body></html>".write(to: indexURL, atomically: true, encoding: .utf8)
        try """
            <!doctype html>
            <html>
            <body>
            \(String(repeating: "content", count: 500))
            </body>
            </html>
            """.write(to: otherURL, atomically: true, encoding: .utf8)

        let selected = try XCTUnwrap(FrontendProjectBuilder.latestEntryFileURL())
        XCTAssertEqual(selected.lastPathComponent.lowercased(), "index.html")
    }

    func testLatestEntryFileURLUsesPersistedEntryFromAutoBuild() throws {
        try FrontendProjectBuilder.clearLatestProject()

        let message = ChatMessage(
            role: .assistant,
            content: "",
            fileAttachments: [
                ChatFileAttachment(
                    fileName: "web/index.html",
                    mimeType: "text/html",
                    textContent: """
                    <!doctype html>
                    <html>
                    <head>
                      <meta charset="utf-8">
                      <meta name="viewport" content="width=device-width, initial-scale=1">
                    </head>
                    <body>
                      <h1>web entry</h1>
                    </body>
                    </html>
                    """
                ),
                ChatFileAttachment(
                    fileName: "index.html",
                    mimeType: "text/html",
                    textContent: """
                    <!doctype html>
                    <html>
                    <body></body>
                    </html>
                    """
                )
            ]
        )

        let result = try FrontendProjectBuilder.buildProject(from: message, mode: .overwriteLatestProject)
        XCTAssertTrue(result.entryFileURL.path.lowercased().hasSuffix("web/index.html"))

        let selected = try XCTUnwrap(FrontendProjectBuilder.latestEntryFileURL())
        XCTAssertEqual(selected.standardizedFileURL, result.entryFileURL.standardizedFileURL)
    }

    func testLatestEntryFileURLReturnsIndexPHPForPHPOnlyProject() throws {
        try FrontendProjectBuilder.clearLatestProject()
        let latest = try XCTUnwrap(FrontendProjectBuilder.latestProjectURL())
        let indexPHP = latest.appendingPathComponent("index.php")
        let otherPHP = latest.appendingPathComponent("api/home.php")

        try FileManager.default.createDirectory(at: otherPHP.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "<?php echo 'index';".write(to: indexPHP, atomically: true, encoding: .utf8)
        try "<?php echo 'api';".write(to: otherPHP, atomically: true, encoding: .utf8)

        let selected = try XCTUnwrap(FrontendProjectBuilder.latestEntryFileURL())
        XCTAssertEqual(selected.lastPathComponent.lowercased(), "index.php")
    }

    func testBuildProjectFromPythonBlockWritesMainPyAndDisablesAutoPreview() throws {
        let message = ChatMessage(
            role: .assistant,
            content: """
            ```python
            print("hello from python")
            ```
            """
        )

        let result = try FrontendProjectBuilder.buildProject(from: message, mode: .createNewProject)
        XCTAssertTrue(result.writtenRelativePaths.contains("main.py"))
        XCTAssertTrue(result.writtenRelativePaths.contains("index.html"))
        XCTAssertFalse(result.hadNaturalPreviewEntry)
        XCTAssertFalse(result.shouldAutoOpenPreview)

        let mainPy = result.projectDirectoryURL.appendingPathComponent("main.py")
        let code = try String(contentsOf: mainPy, encoding: .utf8)
        XCTAssertTrue(code.contains("hello from python"))
    }

    func testBuildProjectUsesDescriptorPathTokenForNonWebLanguage() throws {
        let message = ChatMessage(
            role: .assistant,
            content: """
            ```go cmd/server/main.go
            package main
            import "fmt"

            func main() {
                fmt.Println("ok")
            }
            ```
            """
        )

        let result = try FrontendProjectBuilder.buildProject(from: message, mode: .createNewProject)
        XCTAssertTrue(result.writtenRelativePaths.contains("cmd/server/main.go"))
        XCTAssertFalse(result.shouldAutoOpenPreview)
    }

    func testCanGenerateProjectFromTaggedNonWebFileOutput() throws {
        let message = ChatMessage(
            role: .assistant,
            content: """
            [[file:pyproject.toml]]
            [project]
            name = "demo"
            version = "0.1.0"
            [[endfile]]
            """
        )

        XCTAssertTrue(FrontendProjectBuilder.canGenerateProject(from: message))
        let result = try FrontendProjectBuilder.buildProject(from: message, mode: .createNewProject)
        XCTAssertTrue(result.writtenRelativePaths.contains("pyproject.toml"))
    }

    func testBuildProjectUnwrapsFencedTaggedHtmlFile() throws {
        let message = ChatMessage(
            role: .assistant,
            content: """
            [[file:index.html]]
            ```html
            <!doctype html>
            <html>
            <body>Hello</body>
            </html>
            ```
            [[endfile]]
            """
        )

        let result = try FrontendProjectBuilder.buildProject(from: message, mode: .overwriteLatestProject)
        let entryText = try String(contentsOf: result.entryFileURL, encoding: .utf8)

        XCTAssertEqual(result.entryFileURL.lastPathComponent.lowercased(), "index.html")
        XCTAssertFalse(entryText.contains("```html"))
        XCTAssertFalse(entryText.contains("```"))
        XCTAssertTrue(entryText.contains("<body>Hello</body>"))
    }

    func testClearLatestProjectRemovesPersistedEntryPointerAndFiles() throws {
        let message = ChatMessage(
            role: .assistant,
            content: """
            [[file:web/index.html]]
            <!doctype html>
            <html><body>OK</body></html>
            [[endfile]]
            """
        )

        _ = try FrontendProjectBuilder.buildProject(from: message, mode: .overwriteLatestProject)
        XCTAssertNotNil(FrontendProjectBuilder.latestEntryFileURL())

        try FrontendProjectBuilder.clearLatestProject()

        XCTAssertNil(FrontendProjectBuilder.latestEntryFileURL())
        let latest = try XCTUnwrap(FrontendProjectBuilder.latestProjectURL())
        let contents = try FileManager.default.contentsOfDirectory(atPath: latest.path)
        XCTAssertTrue(contents.isEmpty)
    }

    func testBuildProjectUnwrapsFencedFileAttachmentContent() throws {
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

        let result = try FrontendProjectBuilder.buildProject(from: message, mode: .overwriteLatestProject)
        let entryText = try String(contentsOf: result.entryFileURL, encoding: .utf8)

        XCTAssertEqual(result.entryFileURL.lastPathComponent.lowercased(), "index.html")
        XCTAssertFalse(entryText.contains("```html"))
        XCTAssertFalse(entryText.contains("```"))
        XCTAssertTrue(entryText.contains("<body>Hello</body>"))
    }

    func testBuildProjectAutoWiresStylesheetAndScriptForNaturalHtmlEntry() throws {
        let message = ChatMessage(
            role: .assistant,
            content: "",
            fileAttachments: [
                ChatFileAttachment(
                    fileName: "index.html",
                    mimeType: "text/html",
                    textContent: """
                    <!doctype html>
                    <html>
                    <head>
                      <meta charset="utf-8">
                    </head>
                    <body>
                      <h1>Hello</h1>
                    </body>
                    </html>
                    """
                ),
                ChatFileAttachment(
                    fileName: "styles.css",
                    mimeType: "text/css",
                    textContent: "body { color: #111; }"
                ),
                ChatFileAttachment(
                    fileName: "script.js",
                    mimeType: "application/javascript",
                    textContent: "console.log('ready');"
                )
            ]
        )

        let result = try FrontendProjectBuilder.buildProject(from: message, mode: .overwriteLatestProject)
        let entryText = try String(contentsOf: result.entryFileURL, encoding: .utf8)

        XCTAssertEqual(result.entryFileURL.lastPathComponent.lowercased(), "index.html")
        XCTAssertTrue(entryText.contains("<link rel=\"stylesheet\" href=\"styles.css\">"))
        XCTAssertTrue(entryText.contains("<script src=\"script.js\"></script>"))
    }

    func testBuildProjectAutoWiresRelativeAssetPathsForNestedEntry() throws {
        let message = ChatMessage(
            role: .assistant,
            content: "",
            fileAttachments: [
                ChatFileAttachment(
                    fileName: "web/index.html",
                    mimeType: "text/html",
                    textContent: """
                    <!doctype html>
                    <html>
                    <head><meta charset="utf-8"></head>
                    <body><div id="app"></div></body>
                    </html>
                    """
                ),
                ChatFileAttachment(
                    fileName: "assets/main.css",
                    mimeType: "text/css",
                    textContent: "body { margin: 0; }"
                ),
                ChatFileAttachment(
                    fileName: "scripts/app.js",
                    mimeType: "application/javascript",
                    textContent: "document.getElementById('app').textContent = 'ok';"
                )
            ]
        )

        let result = try FrontendProjectBuilder.buildProject(from: message, mode: .overwriteLatestProject)
        let entryText = try String(contentsOf: result.entryFileURL, encoding: .utf8)

        XCTAssertTrue(result.entryFileURL.path.lowercased().hasSuffix("web/index.html"))
        XCTAssertTrue(entryText.contains("<link rel=\"stylesheet\" href=\"../assets/main.css\">"))
        XCTAssertTrue(entryText.contains("<script src=\"../scripts/app.js\"></script>"))
    }

    func testBuildProjectRepairsEmptyIndexHtmlAndLinksAssets() throws {
        let message = ChatMessage(
            role: .assistant,
            content: "",
            fileAttachments: [
                ChatFileAttachment(
                    fileName: "index.html",
                    mimeType: "text/html",
                    textContent: "   "
                ),
                ChatFileAttachment(
                    fileName: "styles.css",
                    mimeType: "text/css",
                    textContent: "body { background: #fafafa; }"
                ),
                ChatFileAttachment(
                    fileName: "script.js",
                    mimeType: "application/javascript",
                    textContent: "console.log('ui ok');"
                )
            ]
        )

        let result = try FrontendProjectBuilder.buildProject(from: message, mode: .overwriteLatestProject)
        let entryText = try String(contentsOf: result.entryFileURL, encoding: .utf8).lowercased()

        XCTAssertTrue(entryText.contains("<!doctype html>"))
        XCTAssertTrue(entryText.contains("<link rel=\"stylesheet\" href=\"styles.css\">"))
        XCTAssertTrue(entryText.contains("<script src=\"script.js\"></script>"))
    }

    func testCanGenerateProjectIgnoresTerminalOnlyBashFenceWithoutPath() {
        let message = ChatMessage(
            role: .assistant,
            content: """
            终端运行
            ```bash
            npm install
            npm run dev
            ```
            """
        )

        XCTAssertFalse(FrontendProjectBuilder.canGenerateProject(from: message))
    }

    func testHasExplicitProjectPayloadRejectsPlainMarkdownFence() {
        let message = ChatMessage(
            role: .assistant,
            content: """
            下面是自我介绍：

            ```markdown
            # IEXA
            我是一个偏代码与终端任务的助手。
            ```
            """
        )

        XCTAssertFalse(FrontendProjectBuilder.hasExplicitProjectPayload(from: message))
        XCTAssertNil(FrontendProjectBuilder.explicitPayloadProgressSnapshot(from: message))
    }

    func testHasExplicitProjectPayloadAcceptsTaggedFileOutput() {
        let message = ChatMessage(
            role: .assistant,
            content: """
            [[file:README.md]]
            # IEXA
            这是一个测试文件。
            [[endfile]]
            """
        )

        XCTAssertTrue(FrontendProjectBuilder.hasExplicitProjectPayload(from: message))
        let snapshot = FrontendProjectBuilder.explicitPayloadProgressSnapshot(from: message)
        XCTAssertEqual(snapshot?.detectedFileCount, 1)
    }
}
