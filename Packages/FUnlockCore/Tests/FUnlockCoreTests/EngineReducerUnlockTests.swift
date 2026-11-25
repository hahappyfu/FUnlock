import XCTest
import FUnlockCore

final class EngineReducerUnlockTests: XCTestCase {
    func testPhoneLeftOnDeskAfter15MinIdleLatchesWakeUntilDepartureOrInput() {
        var state = EngineState()
        let config = EngineConfig.defaultForTesting(wakeOnProximity: true, keepAliveWhilePresent: true)
        var now = Date(timeIntervalSince1970: 1_700_000_000)

        _ = EngineReducer.reduce(state: &state, event: .bindDevice(uuid: UUID(), name: "iPhone"), config: config, now: now)
        let rssiEffects = EngineReducer.reduce(state: &state, event: .bleSample(rssi: -50, source: .connected, idleSeconds: 10), config: config, now: now)
        XCTAssertTrue(state.keepAliveActive)
        XCTAssertTrue(rssiEffects.contains(.setKeepAlive(true)))

        // At 900s idle, keep-alive renew releases assertion
        now.addTimeInterval(900)
        guard let renewAt = state.deadlines[.keepAliveRenew] else {
            return XCTFail("Missing keepAliveRenew")
        }
        let capEffects = EngineReducer.reduce(
            state: &state,
            event: .deadlineFired(.keepAliveRenew, scheduledAt: renewAt, idleSeconds: 900, currentSSID: nil, sessionLocked: false),
            config: config,
            now: now
        )
        XCTAssertFalse(state.keepAliveActive)
        XCTAssertTrue(capEffects.contains(.setKeepAlive(false)))

        // Display goes to sleep with phone still present and idle >= 900 -> latches wakeOnProximity
        _ = EngineReducer.reduce(state: &state, event: .displayDidSleep(idleSeconds: 905), config: config, now: now.addingTimeInterval(5))
        XCTAssertTrue(state.idleSleepLatched)

        // Strong BLE packet arrives while phone sits on desk -> must NOT wake display
        let suppressed = EngineReducer.reduce(state: &state, event: .bleSample(rssi: -48, source: .connected, idleSeconds: 910), config: config, now: now.addingTimeInterval(10))
        XCTAssertFalse(suppressed.contains(.wakeDisplay))

        // Real HID input (< 2.0s) clears latch and restores wake capability
        let woken = EngineReducer.reduce(state: &state, event: .bleSample(rssi: -48, source: .connected, idleSeconds: 0.5), config: config, now: now.addingTimeInterval(15))
        XCTAssertFalse(state.idleSleepLatched)
        XCTAssertTrue(woken.contains(.wakeDisplay))
    }

    func testManualWakeTouchIDNeverTriggersWatchSelfLearning() {
        var state = EngineState()
        let config = EngineConfig.defaultForTesting(isKnownIPhone: false)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        state.presence = true
        state.effectiveRSSI = -50
        state.screen = .displaySleeping
        // User opens lid / manual wake (selfWakeStartedAt == nil) + unlocks via Touch ID (idleSeconds == 10)
        _ = EngineReducer.reduce(state: &state, event: .displayDidWake(systemLocked: true), config: config, now: now)
        _ = EngineReducer.reduce(state: &state, event: .sessionUnlockedConfirmed(idleSeconds: 10), config: config, now: now.addingTimeInterval(0.8))
        XCTAssertFalse(state.watchAutoUnlockObserved)
    }

    func testSelfWakeNativeUnlockLearnsAndThreeTimeoutsDecayBackToDirectL2() {
        var state = EngineState()
        let config = EngineConfig.defaultForTesting(wakeOnProximity: true, isKnownIPhone: false)
        var now = Date(timeIntervalSince1970: 1_700_000_000)

        state.screen = .displaySleeping
        _ = EngineReducer.reduce(state: &state, event: .bindDevice(uuid: UUID(), name: "Apple Watch"), config: config, now: now)
        _ = EngineReducer.reduce(state: &state, event: .bleSample(rssi: -52, source: .scanning, idleSeconds: 30), config: config, now: now)
        XCTAssertNotNil(state.selfWakeStartedAt)

        // Native Watch unlock completes 0.9s after FUnlock self-wake without L2 injection
        now.addTimeInterval(0.9)
        let effects = EngineReducer.reduce(state: &state, event: .sessionUnlockedConfirmed(idleSeconds: 30), config: config, now: now)
        XCTAssertTrue(state.watchAutoUnlockObserved)
        XCTAssertTrue(effects.contains(.persistWatchAutoUnlockObserved(true)))

        // Simulate 3 consecutive L1 1.2s timeouts -> auto-resets watchAutoUnlockObserved to false
        for _ in 0..<3 {
            now.addTimeInterval(10)
            state.screen = .locked(reason: .away)
            state.unlockPhase = .waitingNativeUnlock(startedAt: now, reason: .watchObserved)
            let checkAt = now.addingTimeInterval(1.2)
            state.deadlines.set(.l1NativeCheck, at: checkAt)
            _ = EngineReducer.reduce(
                state: &state,
                event: .deadlineFired(.l1NativeCheck, scheduledAt: checkAt, idleSeconds: 30, currentSSID: nil, sessionLocked: true),
                config: config,
                now: checkAt
            )
            state.unlockPhase = .idle
        }
        XCTAssertFalse(state.watchAutoUnlockObserved)
    }

    func testUnbindMidUnlockCancelsPhaseReleasesKeepAliveAndClearsDeadlines() {
        var state = EngineState()
        let config = EngineConfig.defaultForTesting()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        state.presence = true
        state.keepAliveActive = true
        state.unlockPhase = .waitingNativeUnlock(startedAt: now, reason: .watchObserved)
        state.deadlines.set(.l1NativeCheck, at: now.addingTimeInterval(0.15))
        state.deadlines.set(.lockConfirm, at: now.addingTimeInterval(3.0))

        let effects = EngineReducer.reduce(state: &state, event: .unbindDevice, config: config, now: now)
        XCTAssertFalse(state.presence)
        XCTAssertFalse(state.keepAliveActive)
        XCTAssertEqual(state.unlockPhase, .idle)
        XCTAssertNil(state.deadlines[.l1NativeCheck])
        XCTAssertNil(state.deadlines[.lockConfirm])
        XCTAssertTrue(effects.contains(.setKeepAlive(false)))
    }

    func testNegativeHintForcesFastPollAndImmediateProbe() {
        var state = EngineState()
        let config = EngineConfig.defaultForTesting()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        state.monitoredUUID = UUID()
        state.presence = true
        state.peripheralConnected = true
        state.activePollInterval = 8.0

        let effects = EngineReducer.reduce(state: &state, event: .negativeHintReceived(.audioOutputDisconnected), config: config, now: now)
        XCTAssertEqual(state.activePollInterval, 0.5)
        XCTAssertGreaterThan(state.negativeBoostSamplesRemaining, 0)
        XCTAssertTrue(effects.contains(.probeRSSIImmediately))
    }

    func testThreeConsecutiveInjectionFailuresEnterDegradedAndSendNotification() {
        var state = EngineState()
        let config = EngineConfig.defaultForTesting()
        var now = Date(timeIntervalSince1970: 1_700_000_000)

        state.monitoredUUID = UUID()
        state.presence = true
        state.effectiveRSSI = -50
        state.screen = .locked(reason: .away)

        for attempt in 1...3 {
            state.unlockPhase = .injecting
            let effects = EngineReducer.reduce(
                state: &state,
                event: .injectionFinished(succeeded: true, verifiedUnlocked: false, displayPoweredOn: true, axTrusted: true, sessionStillLocked: true),
                config: config,
                now: now
            )
            XCTAssertEqual(state.consecutiveFailures, attempt)
            if attempt < 3 {
                XCTAssertEqual(state.unlockPhase, .cooldown(until: now.addingTimeInterval(EngineReducer.failureCooldownDuration)))
            } else {
                XCTAssertEqual(state.unlockPhase, .degraded)
                XCTAssertTrue(effects.contains(.sendDegradedNotification))
                XCTAssertTrue(effects.contains(.showPasswordMismatchAlert))
            }
            now.addTimeInterval(15)
        }
    }
}
