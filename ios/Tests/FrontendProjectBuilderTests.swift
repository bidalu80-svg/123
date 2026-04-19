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
}
