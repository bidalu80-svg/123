import XCTest
@testable import ChatApp

final class WordGenerationServiceTests: XCTestCase {
    func testExtractBlocksFromStructuredOutline() {
        let text = """
        # 项目计划
        ## 背景
        - 当前转化率偏低
        - 需要提升留存

        ## 方案
        1. 重构注册流程
        2. 增加新手引导
        """

        let blocks = WordGenerationService.extractBlocks(from: text)
        XCTAssertFalse(blocks.isEmpty)
        XCTAssertTrue(blocks.contains(where: { $0.kind == .heading1 }))
        XCTAssertTrue(blocks.contains(where: { $0.kind == .bullet }))
    }

    func testCanGenerateReturnsFalseForShortPlainText() {
        let message = ChatMessage(role: .assistant, content: "好的，处理完成。")
        XCTAssertFalse(WordGenerationService.canGenerate(from: message))
    }

    func testCanGenerateReturnsTrueForAssistantOutline() {
        let message = ChatMessage(
            role: .assistant,
            content: """
            # 汇报大纲
            - 目标
            - 里程碑
            """
        )
        XCTAssertTrue(WordGenerationService.canGenerate(from: message))
    }
}
