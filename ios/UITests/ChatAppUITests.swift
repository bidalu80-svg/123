import XCTest

final class ChatAppUITests: XCTestCase {
    func testExampleNavigation() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["聊天"].exists)
        XCTAssertTrue(app.tabBars.buttons["配置"].exists)
        XCTAssertTrue(app.tabBars.buttons["测试"].exists)
    }
}
