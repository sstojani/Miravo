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
        let addExists = app.buttons["tab.add"].waitForExistence(timeout: 5)
        XCTAssertTrue(addExists)
        app.buttons["tab.add"].tap()
        let amountExists = app.textFields["Transaction amount"].waitForExistence(timeout: 5)
        let saveExists = app.buttons["Save"].exists
        XCTAssertTrue(amountExists)
        XCTAssertFalse(saveExists)
    }

    func testQuickAddAppearsImmediatelyInLocalTransactionList() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-authenticated"]
        app.launch()
        let addExists = app.buttons["tab.add"].waitForExistence(timeout: 5)
        XCTAssertTrue(addExists)
        app.buttons["tab.add"].tap()

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

        let save = app.buttons["Save"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: save)
        waitForExpectations(timeout: 5)
        save.tap()
        let savedConfirmationExists = app.buttons["Undo saved transaction"]
            .waitForExistence(timeout: 5)
        XCTAssertTrue(savedConfirmationExists)

        app.buttons["tab.transactions"].tap()
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

    func testShortcutSettingsAndDefaultsRemainNavigableWithoutNetwork() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-authenticated", "-ui-testing-server-session"]
        app.launch()
        XCTAssertTrue(app.buttons["tab.more"].waitForExistence(timeout: 5))
        app.buttons["tab.more"].tap()
        app.buttons["more.settings"].tap()
        let shortcut = app.buttons["settings.shortcut"]
        XCTAssertTrue(shortcut.waitForExistence(timeout: 5))
        shortcut.tap()
        let defaults = app.buttons["shortcut.editDefaults"]
        XCTAssertTrue(defaults.waitForExistence(timeout: 5))
        defaults.tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(defaults.waitForExistence(timeout: 5))
        defaults.tap()
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 5))
        app.buttons["Save"].tap()
        XCTAssertTrue(defaults.waitForExistence(timeout: 5))
        app.buttons["tab.overview"].tap()
        XCTAssertTrue(app.buttons["tab.overview"].waitForExistence(timeout: 5))
    }

    func testMoreAndSettingsDestinationsRemainNavigable() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-authenticated", "-ui-testing-server-session"]
        app.launch()

        XCTAssertTrue(app.buttons["tab.more"].waitForExistence(timeout: 5))
        app.buttons["tab.more"].tap()

        let insights = app.buttons["more.insights"]
        XCTAssertTrue(insights.waitForExistence(timeout: 5))
        insights.tap()
        XCTAssertTrue(app.navigationBars["Insights"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["More"].tap()

        let settings = app.buttons["more.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))

        let destinations: [(identifier: String, title: String)] = [
            ("settings.localData", "Local data"),
            ("settings.collaboration", "Collaboration"),
            ("settings.shortcut", "Wallet Shortcut"),
            ("settings.exports", "Exports"),
            ("settings.failedOperations", "Failed operations"),
            ("settings.diagnostics", "Sync diagnostics")
        ]

        for destination in destinations {
            let row = app.buttons[destination.identifier]
            XCTAssertTrue(row.waitForExistence(timeout: 5), destination.identifier)
            for _ in 0 ..< 6 where !row.isHittable {
                app.swipeUp()
            }
            XCTAssertTrue(row.isHittable, destination.identifier)
            row.tap()
            XCTAssertTrue(
                app.navigationBars[destination.title].waitForExistence(timeout: 5),
                destination.title
            )
            app.navigationBars.buttons["Settings"].tap()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        }
    }

    func testSignOutImmediatelyReturnsToSignInAndStaysSignedOutOnRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-authenticated", "-ui-testing-server-session"]
        app.launch()
        XCTAssertTrue(app.buttons["tab.more"].waitForExistence(timeout: 5))
        app.buttons["tab.more"].tap()
        app.staticTexts["ui-test@example.test"].tap()
        let signOut = app.buttons["account.signOut"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 5))
        signOut.tap()
        XCTAssertTrue(app.staticTexts["Sign in to Miravo"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["tab.more"].exists)
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.staticTexts["Sign in to Miravo"].waitForExistence(timeout: 5))
    }
}
