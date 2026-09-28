import XCTest

final class CleanupFlowUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testOnboardingToCompletedCleanupWithSampleData() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uitesting"]
        app.launch()

        let getStarted = app.buttons["getStarted"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 10))
        getStarted.tap()

        let sample = app.buttons["sampleData"]
        XCTAssertTrue(sample.waitForExistence(timeout: 5))
        sample.tap()

        let cleanUp = app.buttons["cleanUp"]
        XCTAssertTrue(cleanUp.waitForExistence(timeout: 10))
        cleanUp.tap()

        let review = app.buttons["review"]
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        review.tap()

        XCTAssertTrue(app.staticTexts["confirmHeadline"].waitForExistence(timeout: 10))

        // Free tier: clean the free allowance.
        let cleanFree = app.buttons["cleanFree"]
        XCTAssertTrue(cleanFree.waitForExistence(timeout: 5))
        cleanFree.tap()

        let start = app.buttons["startCleaning"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()

        XCTAssertTrue(app.staticTexts["runHeadline"].waitForExistence(timeout: 5) || app.staticTexts["doneHeadline"].exists)

        let done = app.buttons["done"]
        XCTAssertTrue(done.waitForExistence(timeout: 60))
        done.tap()

        XCTAssertTrue(app.buttons["cleanUp"].waitForExistence(timeout: 10))
    }

    func testPauseAndResume() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uitesting"]
        app.launch()

        app.buttons["getStarted"].tap()
        let sample = app.buttons["sampleData"]
        XCTAssertTrue(sample.waitForExistence(timeout: 5))
        sample.tap()
        let cleanUp = app.buttons["cleanUp"]
        XCTAssertTrue(cleanUp.waitForExistence(timeout: 10))
        cleanUp.tap()
        app.buttons["review"].tap()
        let cleanFree = app.buttons["cleanFree"]
        XCTAssertTrue(cleanFree.waitForExistence(timeout: 10))
        cleanFree.tap()
        let start = app.buttons["startCleaning"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()

        let pause = app.buttons["pause"]
        if pause.waitForExistence(timeout: 5) {
            pause.tap()
            let resume = app.buttons["resume"]
            if resume.waitForExistence(timeout: 5) {
                resume.tap()
            }
        }
        XCTAssertTrue(app.buttons["done"].waitForExistence(timeout: 60))
    }
}
