import XCTest
@testable import ChatApp

final class ExcelGenerationServiceTests: XCTestCase {
    func testCanGenerateFromMarkdownTable() {
        let message = ChatMessage(
            role: .assistant,
            content: """
            | 指标 | 数值 |
            | --- | --- |
            | DAU | 12000 |
            | 转化率 | 18% |
            """
        )

        XCTAssertTrue(ExcelGenerationService.canGenerate(from: message))
        let sheets = ExcelGenerationService.extractSheets(from: message)
        XCTAssertEqual(sheets.count, 1)
        XCTAssertEqual(sheets[0].headers.count, 2)
        XCTAssertGreaterThanOrEqual(sheets[0].rows.count, 1)
    }

    func testExtractSheetsFromCSVAttachment() {
        let csv = """
        name,score
        alice,92
        bob,88
        """
        let message = ChatMessage(
            role: .assistant,
            content: "请看附件数据。",
            fileAttachments: [
                ChatFileAttachment(
                    fileName: "report.csv",
                    mimeType: "text/csv",
                    textContent: csv
                )
            ]
        )

        let sheets = ExcelGenerationService.extractSheets(from: message)
        XCTAssertEqual(sheets.count, 1)
        XCTAssertEqual(sheets[0].headers, ["name", "score"])
        XCTAssertEqual(sheets[0].rows.count, 2)
    }

    func testCanGenerateReturnsFalseWithoutTable() {
        let message = ChatMessage(role: .assistant, content: "今天进展顺利。")
        XCTAssertFalse(ExcelGenerationService.canGenerate(from: message))
    }

    func testCanGenerateFromSpreadsheetLikeFileBlock() {
        let message = ChatMessage(
            role: .assistant,
            content: """
            [[file:项目预算表.xlsx]]
            这是项目预算数据：

            | 项目 | 金额 |
            | --- | --- |
            | 设计 | 2000 |
            | 开发 | 8000 |
            [[endfile]]
            """
        )

        let sheets = ExcelGenerationService.extractSheets(from: message)
        XCTAssertEqual(sheets.count, 1)
        XCTAssertEqual(sheets[0].headers, ["项目", "金额"])
        XCTAssertEqual(sheets[0].rows.count, 2)
        XCTAssertTrue(ExcelGenerationService.canGenerate(from: message))
    }

    func testCanGenerateDoesNotTreatHtmlAsSpreadsheet() {
        let html = """
        <!doctype html>
        <html lang="zh-CN">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>demo</title>
        </head>
        <body>
          <h1>Hello</h1>
        </body>
        </html>
        """
        let message = ChatMessage(
            role: .assistant,
            content: "",
            fileAttachments: [
                ChatFileAttachment(
                    fileName: "index.html",
                    mimeType: "text/html",
                    textContent: html
                )
            ]
        )

        XCTAssertFalse(ExcelGenerationService.canGenerate(from: message))
        XCTAssertTrue(ExcelGenerationService.extractSheets(from: message).isEmpty)
    }
}
