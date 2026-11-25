import XCTest
import FUnlockCore

final class EngineReducerLockAndSessionTests: XCTestCase {
    func testSingleSampleDropExtendsOnceBeforeLocking() {
        var state = EngineState()
        let config = EngineConfig.defaultForTesting(unlockRSSI: -60, lockRSSI: -80)
        var now = Date(timeIntervalSince1970: 1_700_000_000)

        _ = EngineReducer.reduce(state: &state, event: .bindDevice(uuid: UUID(), name: "Watch"), config: config, now: now)
        _ = EngineReducer.reduce(state: &state, event: .bleSample(rssi: -52, source: .connected, idleSeconds: 30), config: config, now: now)
        XCTAssertTrue(state.presence)

        // Advance past proximityGracePeriod (5s) and settle Kalman near lock edge (-79 >= -80)
        for _ in 0..<14 {
            now.addTimeInterval(1.0)
            _ = EngineReducer.reduce(state: &state, event: .bleSample(rssi: -79, source: .connected, idleSeconds: 30), config: config, now: now)
        }
        XCTAssertTrue(state.presence)
        XCTAssertGreaterThanOrEqual(state.effectiveRSSI, -80.0)
        XCTAssertNil(state.deadlines[.lockConfirm])

        // Sharp single-sample drop with 8s prior poll interval -> crosses < -80, starts lockConfirm, probes RSSI
        state.activePollInterval = 8.0
        now.addTimeInterval(8.0)
        let dropEffects = EngineReducer.reduce(state: &state, event: .bleSample(rssi: -95, source: .connected, idleSeconds: 30), config: config, now: now)
        XCTAssertTrue(dropEffects.contains(.probeRSSIImmediately))
        guard let firstDeadline = state.deadlines[.lockConfirm] else {
            return XCTFail("Missing lockConfirm deadline")
        }

        // Fire at firstDeadline with NO new sample -> extends once to staleLossDeadline (12s total) instead of locking immediately
        let extendEffects = EngineReducer.reduce(
            state: &state,
            event: .deadlineFired(.lockConfirm, scheduledAt: firstDeadline, idleSeconds: 40, currentSSID: nil, sessionLocked: false),
            config: config,
            now: firstDeadline
        )
        XCTAssertFalse(extendEffects.contains(where: { if case .performLock = $0 { return true }; return false }))
        guard let secondDeadline = state.deadlines[.lockConfirm] else {
            return XCTFail("Expected extended lockConfirm deadline")
        }
        XCTAssertGreaterThan(secondDeadline, firstDeadline)

        // Second fire reaches staleLossDeadline -> settles and locks
        let settleEffects = EngineReducer.reduce(
            state: &state,
            event: .deadlineFired(.lockConfirm, scheduledAt: secondDeadline, idleSeconds: 50, currentSSID: nil, sessionLocked: false),
            config: config,
            now: secondDeadline
        )
        XCTAssertTrue(settleEffects.contains(.performLock(reason: "away", useScreensaver: false, sleepDisplay: false)))
    }

    func testStaleLockConfirmDeadlineIsIgnoredAfterReset() {
        var state = EngineState()
        let config = EngineConfig.defaultForTesting(unlockRSSI: -60, lockRSSI: -80)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let staleTime = now.addingTimeInterval(5.0)
        state.presence = true
        state.deadlines.set(.lockConfirm, at: staleTime)
        state.deadlines.cancel(.lockConfirm)

        let effects = EngineReducer.reduce(
            state: &state,
            event: .deadlineFired(.lockConfirm, scheduledAt: staleTime, idleSeconds: 60, currentSSID: nil, sessionLocked: false),
            config: config,
            now: staleTime
        )
        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(state.screen, .unlocked)
    }

    func testRapidSecondSleepCancelsPendingSystemWakeReady() {
        var state = EngineState()
        let config = EngineConfig.defaultForTesting()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        _ = EngineReducer.reduce(state: &state, event: .systemWillSleep, config: config, now: t0)
        _ = EngineReducer.reduce(state: &state, event: .systemDidWake, config: config, now: t0.addingTimeInterval(0.2))
        guard let wakeDeadline = state.deadlines[.systemWakeReady] else {
            return XCTFail("Expected systemWakeReady deadline")
        }

        // Second sleep arrives 0.4s later before 1.0s wake deadline
        _ = EngineReducer.reduce(state: &state, event: .systemWillSleep, config: config, now: t0.addingTimeInterval(0.6))
        XCTAssertNil(state.deadlines[.systemWakeReady])

        // Even if stale timer fires at wakeDeadline, systemPower stays .sleeping
        let effects = EngineReducer.reduce(
            state: &state,
            event: .deadlineFired(.systemWakeReady, scheduledAt: wakeDeadline, idleSeconds: 10, currentSSID: nil, sessionLocked: true),
            config: config,
            now: wakeDeadline
        )
        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(state.systemPower, .sleeping)
    }

    func testThreeSignalTimeoutsLockAsLostAndClearPresence() {
        var state = EngineState()
        let config = EngineConfig.defaultForTesting(signalTimeout: 60.0)
        var now = Date(timeIntervalSince1970: 1_700_000_000)

        _ = EngineReducer.reduce(state: &state, event: .bindDevice(uuid: UUID(), name: "Watch"), config: config, now: now)
        _ = EngineReducer.reduce(state: &state, event: .bleSample(rssi: -52, source: .connected, idleSeconds: 30), config: config, now: now)
        XCTAssertTrue(state.presence)

        for strike in 1...3 {
            guard let deadline = state.deadlines[.signalTimeout] else {
                return XCTFail("Missing signalTimeout at strike \(strike)")
            }
            now = deadline
            let effects = EngineReducer.reduce(
                state: &state,
                event: .deadlineFired(.signalTimeout, scheduledAt: deadline, idleSeconds: 60, currentSSID: nil, sessionLocked: false),
                config: config,
                now: now
            )
            if strike < 3 {
                XCTAssertTrue(state.presence)
                XCTAssertFalse(effects.contains(where: { if case .performLock = $0 { return true }; return false }))
            } else {
                XCTAssertFalse(state.presence)
                XCTAssertEqual(state.effectiveRSSI, -100.0)
                XCTAssertTrue(effects.contains(.performLock(reason: "lost", useScreensaver: false, sleepDisplay: false)))
            }
        }
    }

    func testSelfLockWindowPreventsMisclassifyingOutOfOrderSystemLockAsManual() {
        var state = EngineState()
        let config = EngineConfig.defaultForTesting(useScreensaver: true)
        var now = Date(timeIntervalSince1970: 1_700_000_000)

        state.presence = true
        state.effectiveRSSI = -88
        state.lastProximityAt = now.addingTimeInterval(-15)
        state.lastSampleAt = now.addingTimeInterval(-12)
        let confirmAt = now.addingTimeInterval(2.5)
        state.deadlines.set(.lockConfirm, at: confirmAt)
        state.lockConfirmContext = LockConfirmContext(startedAt: now, pollIntervalBefore: 2.0, extendedOnce: false)

        now = confirmAt
        _ = EngineReducer.reduce(
            state: &state,
            event: .deadlineFired(.lockConfirm, scheduledAt: confirmAt, idleSeconds: 30, currentSSID: nil, sessionLocked: false),
            config: config,
            now: now
        )
        XCTAssertEqual(state.intent, .autoLock)
        XCTAssertNotNil(state.selfLockWindowDeadline)

        // Screensaver + system lock notifications arrive out of order within 10s self-lock window
        _ = EngineReducer.reduce(state: &state, event: .screensaverDidStart, config: config, now: now.addingTimeInterval(0.2))
        _ = EngineReducer.reduce(state: &state, event: .systemScreenLockedNotification(sessionLocked: true), config: config, now: now.addingTimeInterval(0.4))
        XCTAssertEqual(state.intent, .autoLock)

        _ = EngineReducer.reduce(state: &state, event: .screensaverDidStop, config: config, now: now.addingTimeInterval(0.6))
        XCTAssertEqual(state.screen, .locked(reason: .away))

        // Outside self-lock window, system lock notification marks .manualLock
        now.addTimeInterval(15)
        _ = EngineReducer.reduce(state: &state, event: .sessionUnlockedConfirmed(idleSeconds: 1.0), config: config, now: now)
        _ = EngineReducer.reduce(state: &state, event: .systemScreenLockedNotification(sessionLocked: true), config: config, now: now.addingTimeInterval(1.0))
        XCTAssertTrue(state.intent.isManualLockActive)
        XCTAssertEqual(state.screen, .locked(reason: .manual))
    }

    func testLockVerificationFailureRollsBackToUnlocked() {
        var state = EngineState()
        let config = EngineConfig.defaultForTesting()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        _ = EngineReducer.reduce(state: &state, event: .lockNowRequested(sessionLocked: false), config: config, now: now)
        XCTAssertEqual(state.screen, .locked(reason: .manual))
        guard let verifyAt = state.deadlines[.lockVerify] else {
            return XCTFail("Expected lockVerify deadline")
        }

        _ = EngineReducer.reduce(
            state: &state,
            event: .deadlineFired(.lockVerify, scheduledAt: verifyAt, idleSeconds: 5, currentSSID: nil, sessionLocked: false),
            config: config,
            now: verifyAt
        )
        XCTAssertEqual(state.screen, .unlocked)
    }

    func testTrustedWiFiDefersLockAndRetriesOnLeave() {
        var state = EngineState()
        let config = EngineConfig.defaultForTesting(pauseOnWiFi: true, pauseOnWiFiSSID: "HomeWiFi")
        var now = Date(timeIntervalSince1970: 1_700_000_000)

        _ = EngineReducer.reduce(state: &state, event: .bindDevice(uuid: UUID(), name: "Watch"), config: config, now: now)
        _ = EngineReducer.reduce(state: &state, event: .bleSample(rssi: -52, source: .connected, idleSeconds: 30), config: config, now: now)
        for _ in 0..<14 {
            now.addTimeInterval(1.0)
            _ = EngineReducer.reduce(state: &state, event: .bleSample(rssi: -79, source: .connected, idleSeconds: 30), config: config, now: now)
        }
        XCTAssertGreaterThanOrEqual(state.effectiveRSSI, -80.0)
        now.addTimeInterval(2.0)
        _ = EngineReducer.reduce(state: &state, event: .bleSample(rssi: -95, source: .connected, idleSeconds: 30), config: config, now: now)
        guard let lockAt = state.deadlines[.lockConfirm] else { return XCTFail("Missing lockConfirm") }
        // Confirming probe sample arrives 0.5s later so first lockConfirm fire settles instead of extending
        _ = EngineReducer.reduce(state: &state, event: .bleSample(rssi: -95, source: .connected, idleSeconds: 30), config: config, now: now.addingTimeInterval(0.5))

        now = lockAt
        let blockedEffects = EngineReducer.reduce(
            state: &state,
            event: .deadlineFired(.lockConfirm, scheduledAt: lockAt, idleSeconds: 30, currentSSID: "HomeWiFi", sessionLocked: false),
            config: config,
            now: now
        )
        XCTAssertFalse(blockedEffects.contains(where: { if case .performLock = $0 { return true }; return false }))
        guard let recheckAt = state.deadlines[.deferredLockRecheck] else {
            return XCTFail("Expected deferredLockRecheck")
        }

        // Still on HomeWiFi -> reschedules recheck
        now = recheckAt
        _ = EngineReducer.reduce(
            state: &state,
            event: .deadlineFired(.deferredLockRecheck, scheduledAt: recheckAt, idleSeconds: 40, currentSSID: "HomeWiFi", sessionLocked: false),
            config: config,
            now: now
        )
        guard let nextRecheck = state.deadlines[.deferredLockRecheck] else {
            return XCTFail("Expected rescheduled deferredLockRecheck")
        }

        // Left HomeWiFi -> locks immediately
        now = nextRecheck
        let lockEffects = EngineReducer.reduce(
            state: &state,
            event: .deadlineFired(.deferredLockRecheck, scheduledAt: nextRecheck, idleSeconds: 50, currentSSID: "CafeWiFi", sessionLocked: false),
            config: config,
            now: now
        )
        XCTAssertTrue(lockEffects.contains(.performLock(reason: "away", useScreensaver: false, sleepDisplay: false)))
    }
}
