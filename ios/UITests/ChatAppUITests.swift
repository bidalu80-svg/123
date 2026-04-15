import XCTest

final class ChatAppUITests: XCTestCase {
    func testAppLaunchesIntoAuthOrChat() {
        let app = XCUIApplication()
        app.launch()

        if app.buttons["Apple ID 登录"].waitForExistence(timeout: 5) {
            XCTAssertTrue(app.buttons["Apple ID 登录"].exists)
        } else {
            XCTAssertTrue(app.staticTexts["IEXA"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.textFields["有问题，尽管问"].exists)
        }
    }
}
