import XCTest

@MainActor
final class ProjectLedgerUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunchShowsOfflineFirstEntry() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-authenticated"]
        app.launch()
        let addExists = app.tabBars.buttons["Add"].waitForExistence(timeout: 5)
        XCTAssertTrue(addExists)
        app.tabBars.buttons["Add"].tap()
        let amountExists = app.textFields["Transaction amount"].waitForExistence(timeout: 5)
        let saveExists = app.buttons["Save on this iPhone"].exists
        XCTAssertTrue(amountExists)
        XCTAssertTrue(saveExists)
    }

    func testQuickAddAppearsImmediatelyInLocalTransactionList() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-authenticated"]
        app.launch()
        let addExists = app.tabBars.buttons["Add"].waitForExistence(timeout: 5)
        XCTAssertTrue(addExists)
        app.tabBars.buttons["Add"].tap()

        let amount = app.textFields["Transaction amount"]
        let amountExists = amount.waitForExistence(timeout: 5)
        XCTAssertTrue(amountExists)
        amount.tap()
        amount.typeText("12.50")

        let amountDone = app.buttons["Done"].firstMatch
        XCTAssertTrue(amountDone.waitForExistence(timeout: 3))
        amountDone.tap()

        let merchant = app.textFields["Merchant or payee"]
        XCTAssertTrue(merchant.waitForExistence(timeout: 3))
        expectation(
            for: NSPredicate(format: "hittable == true"),
            evaluatedWith: merchant
        )
        waitForExpectations(timeout: 3)

        merchant.tap()
        merchant.typeText("Offline UI test")

        let merchantDone = app.buttons["Done"].firstMatch
        XCTAssertTrue(merchantDone.waitForExistence(timeout: 3))
        merchantDone.tap()

        let save = app.buttons["Save on this iPhone"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: save)
        waitForExpectations(timeout: 5)
        save.tap()
        let savedConfirmationExists = app.staticTexts["Saved on this iPhone"]
            .waitForExistence(timeout: 5)
        XCTAssertTrue(savedConfirmationExists)

        app.tabBars.buttons["Transactions"].tap()
        let transactionExists = app.staticTexts["Offline UI test"].waitForExistence(timeout: 5)
        XCTAssertTrue(transactionExists)
    }

    func testFirstLaunchOnboardingExplainsLocalFirstBehavior() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-reset-onboarding"]
        app.launch()
        let onboardingExists = app.staticTexts["Your ledger, under your control"]
            .waitForExistence(timeout: 5)
        XCTAssertTrue(onboardingExists)
    }
}
