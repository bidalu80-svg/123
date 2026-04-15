import XCTest

final class ChatAppUITests: XCTestCase {
    func testAppLaunchesIntoAuthOrChat() {
        let app = XCUIApplication()
        app.launch()

        if app.navigationBars["欢迎使用 IEXA"].waitForExistence(timeout: 5) {
            XCTAssertTrue(app.textFields["手机号（支持 +86 / 国际号码）"].exists)
            XCTAssertTrue(app.secureTextFields["密码（至少 8 位，含字母和数字）"].exists)
        } else {
            XCTAssertTrue(app.staticTexts["IEXA"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.textFields["有问题，尽管问"].exists)
        }
    }
}
