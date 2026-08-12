// FUnlockTests/DiagnosticsViewTests.swift
import XCTest
@testable import FUnlock

final class DiagnosticsViewTests: XCTestCase {
    func testScreenLabelMapsKnownStates() {
        XCTAssertEqual(DecisionEvent.screenLabel("locked(away)"), "screen_locked_away")
        XCTAssertEqual(DecisionEvent.screenLabel("locked(manual)"), "screen_locked_manual")
        XCTAssertEqual(DecisionEvent.screenLabel("unlocked"), "screen_unlocked")
        XCTAssertEqual(DecisionEvent.screenLabel("displaySleeping"), "screen_display_sleeping")
    }

    func testScreenLabelFallsBackToRaw() {
        XCTAssertEqual(DecisionEvent.screenLabel("unknown"), "unknown")
        XCTAssertNil(DecisionEvent.screenLabel(nil))
    }

    func testTimeStringContainsOnlyTime() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(DiagnosticsView.timeString(date),
                       date.formatted(.dateTime.hour().minute()),
                       "timeString 应只显示 HH:mm")
    }
}
