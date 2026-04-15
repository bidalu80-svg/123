import XCTest

final class ChatAppUITests: XCTestCase {
    func testAppLaunchesIntoAuthOrChat() {
        let app = XCUIApplication()
        app.launch()

        if app.textFields["账号（可填手机号）"].waitForExistence(timeout: 5) {
            XCTAssertTrue(app.secureTextFields["密码（至少 6 位）"].exists)
            XCTAssertTrue(app.buttons["登录使用"].exists)
            XCTAssertTrue(app.buttons["注册使用"].exists)
        } else {
            XCTAssertTrue(app.staticTexts["IEXA"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.textFields["有问题，尽管问"].exists)
        }
    }
}
