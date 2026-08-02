// FUnlockTests/ReasonActionMappingTests.swift
import XCTest
@testable import FUnlock

final class ReasonActionMappingTests: XCTestCase {
    func testEveryReasonHasNonEmptyTitleKey() {
        for reason in DecisionReason.allCases {
            XCTAssertFalse(reason.titleKey.isEmpty, "\(reason.rawValue) 缺少 titleKey")
        }
    }

    func testSpecificActionMappings() {
        XCTAssertEqual(DecisionReason.signalBelowThreshold.action, .lowerUnlockThreshold)
        XCTAssertEqual(DecisionReason.axRevoked.action, .openAccessibilitySettings)
        XCTAssertEqual(DecisionReason.unlockFailed.action, .reEnterPassword)
        XCTAssertEqual(DecisionReason.noPassword.action, .reEnterPassword)
        XCTAssertEqual(DecisionReason.stateMachineBlocked.action, .resetStateMachine)
        XCTAssertEqual(DecisionReason.manualLockActive.action, .goToTab("lock"))
        XCTAssertEqual(DecisionReason.wifiPaused.action, .goToTab("network"))
        XCTAssertEqual(DecisionReason.unlockDisabled.action, .goToTab("unlock"))
        XCTAssertNil(DecisionReason.noPresence.action)
        XCTAssertNil(DecisionReason.unlockSuccess.action)
    }

    func testActionHintLabelKeys() {
        let hints: [ActionHint] = [.lowerUnlockThreshold, .openAccessibilitySettings,
                                   .reEnterPassword, .goToTab("lock"), .resetStateMachine]
        for hint in hints {
            XCTAssertFalse(hint.labelKey.isEmpty, "\(hint) 缺少 labelKey")
        }
    }
}
