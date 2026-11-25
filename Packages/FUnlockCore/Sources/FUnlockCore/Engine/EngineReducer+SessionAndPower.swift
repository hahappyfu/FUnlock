// EngineReducer+SessionAndPower.swift
// 纯函数状态机：系统睡眠/唤醒、显示器电源、屏保与锁屏/解锁会话通知流转。

import Foundation

extension EngineReducer {
    // MARK: - 电源与会话通知

    static func reduceSystemWillSleep(state: inout EngineState, effects: inout [EngineEffect]) {
        state.systemPower = .sleeping
        state.deadlines.cancel(.systemWakeReady)
        state.deadlines.cancel(.deferredLockRecheck)
        state.deferredLockReason = nil
        deactivateKeepAlive(state: &state, effects: &effects)
        effects.append(.recordDecision(
            category: .system,
            outcome: .info,
            reason: .systemSleep,
            rssi: state.lastRawRSSI,
            device: state.monitoredDeviceName,
            screen: state.screen.description,
            detail: ""
        ))
    }

    static func reduceSystemDidWake(state: inout EngineState, now: Date, effects: inout [EngineEffect]) {
        state.deadlines.set(.systemWakeReady, at: now.addingTimeInterval(1.0))
        effects.append(.recordDecision(
            category: .system,
            outcome: .info,
            reason: .systemWake,
            rssi: state.lastRawRSSI,
            device: state.monitoredDeviceName,
            screen: state.screen.description,
            detail: ""
        ))
    }

    static func reduceDisplayDidSleep(state: inout EngineState, idleSeconds: TimeInterval, effects: inout [EngineEffect]) {
        state.screen = .displaySleeping
        deactivateKeepAlive(state: &state, effects: &effects)
        if (state.presence && idleSeconds >= keepAliveIdleLimit) || state.intent.isManualLockActive {
            state.idleSleepLatched = true
        }
        effects.append(.recordDecision(
            category: .system,
            outcome: .info,
            reason: .displaySleep,
            rssi: state.lastRawRSSI,
            device: state.monitoredDeviceName,
            screen: state.screen.description,
            detail: ""
        ))
    }

    static func reduceDisplayDidWake(
        state: inout EngineState,
        systemLocked: Bool,
        config: EngineConfig,
        now: Date,
        effects: inout [EngineEffect]
    ) {
        let isSelfWake = state.selfWakeStartedAt != nil
        state.wakePhase = .succeeded
        state.deadlines.cancel(.wakeRetry)
        if state.screen == .displaySleeping {
            state.screen = systemLocked ? .locked(reason: .away) : .unlocked
        }
        if case .wakingDisplay(_, let parallelScheduled) = state.unlockPhase {
            state.unlockPhase = (parallelScheduled && state.deadlines[.unlockDelay] != nil) ? .waitingDelay : .idle
        }
        if !systemLocked {
            reconcileUnlockedIfNeeded(state: &state)
        }
        if !isSelfWake {
            reduceUserIntervention(state: &state, effects: &effects)
        } else if systemLocked {
            scheduleUnlockIfAllowed(state: &state, config: config, now: now, effects: &effects)
        }
        effects.append(.recordDecision(
            category: .system,
            outcome: .info,
            reason: .displayWake,
            rssi: state.lastRawRSSI,
            device: state.monitoredDeviceName,
            screen: state.screen.description,
            detail: ""
        ))
    }

    static func reduceSystemScreenLockedNotification(
        state: inout EngineState,
        sessionLocked: Bool,
        now: Date,
        effects: inout [EngineEffect]
    ) {
        state.deadlines.cancel(.deferredLockRecheck)
        state.deferredLockReason = nil
        state.deadlines.cancel(.screenLockConfirm)
        if sessionLocked {
            applySystemScreenLocked(state: &state, now: now, effects: &effects)
        } else {
            state.deadlines.set(.screenLockConfirm, at: now.addingTimeInterval(0.3))
        }
    }

    static func applySystemScreenLocked(state: inout EngineState, now: Date, effects: inout [EngineEffect]) {
        let isSelfLock = state.selfLockWindowDeadline.map { now <= $0 } ?? false
        if isSelfLock {
            state.intent = .autoLock
            switch state.screen {
            case .locked(reason: .away), .locked(reason: .lost):
                break
            default:
                state.screen = .locked(reason: .away)
            }
        } else {
            state.intent = .manualLock(deadline: now.addingTimeInterval(manualLockIntentDuration))
            state.screen = .locked(reason: .manual)
            state.idleSleepLatched = true
        }
        state.lastLockAt = now
        state.lastUnlockAt = Date(timeIntervalSince1970: 0)
        deactivateKeepAlive(state: &state, effects: &effects)
        if !isSelfLock {
            effects.append(.recordDecision(
                category: .user,
                outcome: .success,
                reason: .userLocked,
                rssi: state.lastRawRSSI,
                device: state.monitoredDeviceName,
                screen: state.screen.description,
                detail: ""
            ))
        }
    }

    static func reduceScreensaverDidStart(state: inout EngineState, now: Date, effects: inout [EngineEffect]) {
        let withinSelfLock = state.selfLockWindowDeadline.map { now <= $0 } ?? false
        if !withinSelfLock {
            state.intent = .manualLock(deadline: now.addingTimeInterval(manualLockIntentDuration))
        }
        state.screen = .screensaver
        deactivateKeepAlive(state: &state, effects: &effects)
    }

    static func reduceScreensaverDidStop(state: inout EngineState) {
        if state.screen == .screensaver {
            let reason: ScreenState.LockReason = state.intent.isManualLockActive ? .manual : .away
            state.screen = .locked(reason: reason)
            state.lastUnlockAt = Date(timeIntervalSince1970: 0)
        }
    }

    static func reduceSessionUnlockNotification(
        state: inout EngineState,
        sessionLocked: Bool,
        idleSeconds: TimeInterval,
        config: EngineConfig,
        now: Date,
        effects: inout [EngineEffect]
    ) {
        state.deadlines.cancel(.screenLockConfirm)
        state.deadlines.cancel(.screenUnlockConfirm)
        if sessionLocked {
            state.deadlines.set(.screenUnlockConfirm, at: now.addingTimeInterval(0.4))
            return
        }
        reduceSessionUnlockedConfirmed(state: &state, idleSeconds: idleSeconds, config: config, now: now, effects: &effects)
    }

    static func reduceSessionUnlockedConfirmed(
        state: inout EngineState,
        idleSeconds: TimeInterval,
        config: EngineConfig,
        now: Date,
        effects: inout [EngineEffect]
    ) {
        state.deadlines.cancel(.deferredLockRecheck)
        state.deferredLockReason = nil
        state.deadlines.cancel(.screenLockConfirm)
        state.deadlines.cancel(.screenUnlockConfirm)
        state.deadlines.cancel(.lockVerify)
        state.selfLockWindowDeadline = nil
        state.screen = .unlocked
        state.intent = .autoLock
        state.idleSleepLatched = false
        state.lastUnlockAt = now
        state.lastProximityAt = now
        state.consecutiveFailures = 0
        handleSessionUnlockedLearningAndAccounting(
            state: &state,
            idleSeconds: idleSeconds,
            config: config,
            now: now,
            effects: &effects
        )
        if state.unlockPhase != .injecting {
            state.unlockPhase = .idle
        }
        effects.append(.flushPendingAlertsAndPasswordPrompt)
        effects.append(.checkForUpdates)
    }

    static func reduceLockNowRequested(
        state: inout EngineState,
        sessionLocked: Bool,
        config: EngineConfig,
        now: Date,
        effects: inout [EngineEffect]
    ) {
        guard !sessionLocked, state.screen == .unlocked else { return }
        state.deadlines.cancel(.deferredLockRecheck)
        state.deferredLockReason = nil
        state.deadlines.cancel(.screenLockConfirm)
        state.selfLockWindowDeadline = nil
        state.intent = .manualLock(deadline: now.addingTimeInterval(manualLockIntentDuration))
        state.idleSleepLatched = true
        state.screen = .locked(reason: .manual)
        state.lastLockAt = now
        state.deadlines.set(.lockVerify, at: now.addingTimeInterval(2.0))
        deactivateKeepAlive(state: &state, effects: &effects)
        if config.pauseMedia {
            effects.append(.pauseMediaIfNeeded)
        }
        effects.append(.performLock(reason: "manual", useScreensaver: config.useScreensaver, sleepDisplay: config.sleepDisplay))
    }

    static func reduceUserIntervention(state: inout EngineState, effects: inout [EngineEffect]) {
        if case .wakingDisplay = state.unlockPhase {
            effects.append(.releaseWakeAssertion)
        }
        if state.unlockPhase != .degraded {
            state.unlockPhase = .idle
        }
        state.deadlines.cancel(.wakeRetry)
        state.deadlines.cancel(.unlockDelay)
        state.deadlines.cancel(.l1NativeCheck)
    }

    static func reconcileUnlockedIfNeeded(state: inout EngineState) {
        let isStaleLockedState: Bool
        if case .locked = state.screen { isStaleLockedState = true } else { isStaleLockedState = false }
        guard isStaleLockedState || state.intent.isManualLockActive else { return }
        state.screen = .unlocked
        state.intent = .autoLock
        state.idleSleepLatched = false
        state.selfLockWindowDeadline = nil
    }
}
