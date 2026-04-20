import XCTest
@testable import ChatApp

final class PPTGenerationServiceTests: XCTestCase {
    func testExtractOutlineFromMarkdownSections() throws {
        let text = """
        # 产品发布计划
        ## 目标
        - 提升转化率
        - 降低流失率

        ## 路线图
        1. MVP 验证
        2. Beta 内测
        3. 全量上线
        """

        let outline = try XCTUnwrap(PPTGenerationService.extractOutline(from: text))
        XCTAssertEqual(outline.title, "产品发布计划")
        XCTAssertEqual(outline.slides.count, 2)
        XCTAssertEqual(outline.slides[0].title, "目标")
        XCTAssertTrue(outline.slides[0].bullets.contains("提升转化率"))
    }

    func testExtractOutlineFallbackForPlainText() throws {
        let text = """
        我们计划在第二季度完成新版本发布，核心目标是提升留存并降低获客成本。
        关键工作包括改版首页、优化注册流程、完善消息触达和会员转化链路。
        同时需要建立监控看板，追踪转化、留存和回访数据。
        """

        let outline = try XCTUnwrap(PPTGenerationService.extractOutline(from: text))
        XCTAssertFalse(outline.title.isEmpty)
        XCTAssertGreaterThanOrEqual(outline.slides.count, 1)
        XCTAssertFalse(outline.slides[0].title.isEmpty)
    }

    func testCanGenerateFromAssistantMessage() {
        let message = ChatMessage(
            role: .assistant,
            content: """
            ## 项目目标
            - 完成 MVP
            - 上线灰度版本
            """
        )
        XCTAssertTrue(PPTGenerationService.canGenerate(from: message))
    }

    func testCanGenerateReturnsFalseForPlainSingleLineReply() {
        let message = ChatMessage(
            role: .assistant,
            content: "好的，已处理完成。"
        )
        XCTAssertFalse(PPTGenerationService.canGenerate(from: message))
    }
}
