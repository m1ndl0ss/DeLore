@testable import DeLore
import XCTest

final class ReviewerGestureTests: XCTestCase {
    private func gesture() -> ReviewerGesture {
        ReviewerGesture(longPressSeconds: 3, tapWindowSeconds: 5, requiredTaps: 5)
    }

    func testFiveTapsWithinWindowAfterLongPressUnlocks() {
        let g = gesture()
        g.onLongPressCompleted(now: 0)
        XCTAssertFalse(g.onConnectTap(now: 0.1))
        XCTAssertFalse(g.onConnectTap(now: 0.2))
        XCTAssertFalse(g.onConnectTap(now: 0.3))
        XCTAssertFalse(g.onConnectTap(now: 0.4))
        XCTAssertTrue(g.onConnectTap(now: 0.5), "fifth tap in window unlocks")
    }

    func testTapsBeforeLongPressDoNothing() {
        let g = gesture()
        for i in 0..<5 { XCTAssertFalse(g.onConnectTap(now: Double(i) * 0.1)) }
        XCTAssertFalse(g.isArmed)
    }

    func testTapAfterWindowExpiresResetsAndFails() {
        let g = gesture()
        g.onLongPressCompleted(now: 0)
        XCTAssertFalse(g.onConnectTap(now: 0.1))
        XCTAssertFalse(g.onConnectTap(now: 0.2))
        XCTAssertFalse(g.onConnectTap(now: 5.001)) // window closed
        XCTAssertFalse(g.isArmed)
        for i in 0..<5 { XCTAssertFalse(g.onConnectTap(now: 5.1 + Double(i) * 0.01)) }
    }

    func testFifthTapExactlyAtWindowEdgeStillUnlocks() {
        let g = gesture()
        g.onLongPressCompleted(now: 1)
        for i in 0..<4 { XCTAssertFalse(g.onConnectTap(now: 1 + Double(i) * 0.01)) }
        XCTAssertTrue(g.onConnectTap(now: 6), "exactly armedAt + 5s still inside window")
    }

    func testReLongPressRestartsTapCount() {
        let g = gesture()
        g.onLongPressCompleted(now: 0)
        _ = g.onConnectTap(now: 0.1)
        _ = g.onConnectTap(now: 0.2)
        _ = g.onConnectTap(now: 0.3)
        g.onLongPressCompleted(now: 0.4) // re-arm resets count
        XCTAssertFalse(g.onConnectTap(now: 0.5))
        XCTAssertFalse(g.onConnectTap(now: 0.6))
        XCTAssertFalse(g.onConnectTap(now: 0.7))
        XCTAssertFalse(g.onConnectTap(now: 0.8))
        XCTAssertTrue(g.onConnectTap(now: 0.9), "needs 5 fresh taps after re-arm")
    }

    func testUnlockingOnceDoesNotUnlockAgainWithoutRearm() {
        let g = gesture()
        g.onLongPressCompleted(now: 0)
        for i in 0..<4 { _ = g.onConnectTap(now: 0.1 + Double(i) * 0.01) }
        XCTAssertTrue(g.onConnectTap(now: 0.5))
        XCTAssertFalse(g.isArmed)
        XCTAssertFalse(g.onConnectTap(now: 0.6))
    }
}
