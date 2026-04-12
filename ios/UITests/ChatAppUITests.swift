import XCTest

final class ChatAppUITests: XCTestCase {
    func testMainChatScreenLoads() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["IEXA"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["有问题，尽管问"].exists)
        XCTAssertTrue(app.buttons.firstMatch.exists)
    }
}
