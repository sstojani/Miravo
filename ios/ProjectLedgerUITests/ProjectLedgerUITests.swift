import XCTest

final class ProjectLedgerUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunchShowsOfflineFirstEntry() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-authenticated"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Add"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Add"].tap()
        XCTAssertTrue(app.textFields["Transaction amount"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Save on this iPhone"].exists)
    }

    func testQuickAddAppearsImmediatelyInLocalTransactionList() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-authenticated"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Add"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Add"].tap()

        let amount = app.textFields["Transaction amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.tap()
        amount.typeText("12.50")
        let merchant = app.textFields["Merchant or payee"]
        merchant.tap()
        merchant.typeText("Offline UI test")
        app.swipeUp()

        let save = app.buttons["Save on this iPhone"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: save)
        waitForExpectations(timeout: 5)
        save.tap()
        XCTAssertTrue(app.alerts["Saved on this iPhone"].waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()

        app.tabBars.buttons["Transactions"].tap()
        XCTAssertTrue(app.staticTexts["Offline UI test"].waitForExistence(timeout: 5))
    }

    func testFirstLaunchOnboardingExplainsLocalFirstBehavior() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-reset-onboarding"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Your ledger, under your control"].waitForExistence(timeout: 5))
    }
}
