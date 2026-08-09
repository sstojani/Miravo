import XCTest

final class ProjectLedgerUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunchShowsOfflineFirstEntry() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Add"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Add"].tap()
        XCTAssertTrue(app.textFields["Expense amount"].exists)
        XCTAssertTrue(app.buttons["Save offline"].exists)
    }
}

