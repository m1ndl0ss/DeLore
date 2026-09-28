import XCTest

@MainActor
final class CleanupFlowUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitesting"]
        app.launch()
        return app
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func tap(_ element: XCUIElement, timeout: TimeInterval = 10) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(element) not found")
        element.tap()
    }

    func testOnboardingToCompletedCleanupWithSampleData() throws {
        let app = launch()

        XCTAssertTrue(app.buttons["getStarted"].waitForExistence(timeout: 10))
        sleep(1)
        snapshot("1-welcome")
        tap(app.buttons["getStarted"])

        XCTAssertTrue(app.buttons["connectInstagram"].waitForExistence(timeout: 5))
        snapshot("2-connect")
        tap(app.buttons["sampleData"])

        XCTAssertTrue(app.buttons["cleanUp"].waitForExistence(timeout: 10))
        snapshot("3-home")
        tap(app.buttons["cleanUp"])

        XCTAssertTrue(app.buttons["review"].waitForExistence(timeout: 5))
        snapshot("4-setup")
        tap(app.buttons["review"])

        XCTAssertTrue(app.staticTexts["confirmHeadline"].waitForExistence(timeout: 10))
        snapshot("5-confirm-free-limit")

        // Free tier: clean the free allowance.
        tap(app.buttons["cleanFree"])
        XCTAssertTrue(app.buttons["startCleaning"].waitForExistence(timeout: 10))
        snapshot("6-confirm-ready")
        tap(app.buttons["startCleaning"])

        let done = app.buttons["done"]
        XCTAssertTrue(done.waitForExistence(timeout: 60))
        snapshot("8-done")
        done.tap()

        XCTAssertTrue(app.buttons["cleanUp"].waitForExistence(timeout: 10))
    }

    func testPauseAndResume() throws {
        let app = launch()

        tap(app.buttons["getStarted"])
        tap(app.buttons["sampleData"], timeout: 5)
        tap(app.buttons["cleanUp"])
        tap(app.buttons["review"], timeout: 5)
        tap(app.buttons["cleanFree"])
        tap(app.buttons["startCleaning"])

        let pause = app.buttons["pause"]
        if pause.waitForExistence(timeout: 5) {
            snapshot("7-running")
            pause.tap()
            let resume = app.buttons["resume"]
            if resume.waitForExistence(timeout: 5) {
                snapshot("7b-paused")
                resume.tap()
            }
        }
        XCTAssertTrue(app.buttons["done"].waitForExistence(timeout: 60))
    }

    func testPaywallAndSettings() throws {
        let app = launch()

        tap(app.buttons["getStarted"])
        tap(app.buttons["sampleData"], timeout: 5)
        tap(app.buttons["cleanUp"])
        tap(app.buttons["review"], timeout: 5)
        tap(app.buttons["unlockEverything"])
        XCTAssertTrue(app.buttons["purchase"].waitForExistence(timeout: 10))
        sleep(1)
        snapshot("9-paywall")
    }
}
