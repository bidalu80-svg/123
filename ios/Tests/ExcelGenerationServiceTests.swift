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
}
