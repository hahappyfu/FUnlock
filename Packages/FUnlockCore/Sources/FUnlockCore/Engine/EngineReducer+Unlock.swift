// EngineReducer+Unlock.swift
// 纯函数状态机：L0 有界在场保活、预备唤醒与解锁前序调度（L1/L2 结算见 UnlockSettlement）。

import Foundation

extension EngineReducer {
    // MARK: - L0 有界在场保活

    static func shouldKeepAliveBeActive(
        state: EngineState,
        idleSeconds: TimeInterval,
        config: EngineConfig
    ) -> Bool {
        guard config.enabled,
              config.keepAliveWhilePresent,
              state.screen == .unlocked,
              state.systemPower == .awake,
              !state.intent.isManualLockActive,
              state.presence,
              state.lockConfirmContext == nil,
              idleSeconds.isFinite,
              idleSeconds >= 0,
              idleSeconds < keepAliveIdleLimit else {
            return false
        }
        let anchorThreshold = config.unlockRSSI == SignalHysteresisEngine.unlockDisabled
            ? config.resolvedLockThreshold
            : config.unlockRSSI
        return state.effectiveRSSI >= Double(anchorThreshold)
    }

    public static func evaluateKeepAlive(
        state: inout EngineState,
        idleSeconds: TimeInterval,
        config: EngineConfig,
        now: Date,
        effects: inout [EngineEffect],
        forceRenew: Bool = false
    ) {
        let shouldBeActive = shouldKeepAliveBeActive(state: state, idleSeconds: idleSeconds, config: config)
        if shouldBeActive {
            let needsEmit = !state.keepAliveActive || forceRenew
            state.keepAliveActive = true
            state.deadlines.set(.keepAliveRenew, at: now.addingTimeInterval(keepAliveRenewInterval))
            if needsEmit {
                effects.append(.setKeepAlive(true))
            }
        } else {
            deactivateKeepAlive(state: &state, effects: &effects)
        }
    }

    // MARK: - 预备唤醒与解锁调度入口

    static func evaluatePreWakeAndApproach(
        state: inout EngineState,
        config: EngineConfig,
        now: Date,
        effects: inout [EngineEffect]
    ) {
        guard config.enabled,
              config.unlockRSSI != SignalHysteresisEngine.unlockDisabled else {
            return
        }

        if state.screen == .displaySleeping,
           state.systemPower == .awake,
           config.wakeOnProximity,
           !state.idleSleepLatched,
           !state.intent.isManualLockActive,
           state.preWakeEMA >= Double(config.preWakeThreshold) {
            triggerSelfWakeIfNeeded(state: &state, config: config, now: now, effects: &effects)
            return
        }

        if state.screen != .unlocked,
           state.screen != .displaySleeping,
           state.presence,
           state.effectiveRSSI >= Double(config.unlockRSSI) {
            scheduleUnlockIfAllowed(state: &state, config: config, now: now, effects: &effects)
        }
    }

    private static func triggerSelfWakeIfNeeded(
        state: inout EngineState,
        config: EngineConfig,
        now: Date,
        effects: inout [EngineEffect]
    ) {
        if case .wakingDisplay = state.unlockPhase { return }
        guard state.selfWakeStartedAt == nil else { return }

        state.selfWakeStartedAt = now
        state.wakePhase = .pending
        state.screen = .locked(reason: .away)
        let shouldParallelUnlock = !config.wakeWithoutUnlocking && state.effectiveRSSI >= Double(config.unlockRSSI)
        state.unlockPhase = .wakingDisplay(attempt: 0, parallelUnlockScheduled: shouldParallelUnlock)
        state.deadlines.set(.wakeRetry, at: now.addingTimeInterval(0.5))
        if shouldParallelUnlock {
            state.deadlines.set(.unlockDelay, at: now.addingTimeInterval(0.8))
        }
        effects.append(.wakeDisplay)
    }

    static func canAttemptUnlock(state: EngineState, now: Date) -> Bool {
        if case .degraded = state.unlockPhase { return false }
        if case .injecting = state.unlockPhase { return false }
        if case .waitingNativeUnlock = state.unlockPhase { return false }
        if case .cooldown(let until) = state.unlockPhase, now < until { return false }
        if state.consecutiveFailures >= maxConsecutiveFailures { return false }
        return true
    }

    static func scheduleUnlockIfAllowed(
        state: inout EngineState,
        config: EngineConfig,
        now: Date,
        effects: inout [EngineEffect]
    ) {
        guard config.enabled,
              state.presence,
              config.unlockRSSI != SignalHysteresisEngine.unlockDisabled,
              state.effectiveRSSI >= Double(config.unlockRSSI),
              state.systemPower == .awake,
              !config.wakeWithoutUnlocking,
              !state.intent.isManualLockActive,
              state.screen != .unlocked,
              state.screen != .displaySleeping,
              canAttemptUnlock(state: state, now: now) else {
            return
        }
        guard now.timeIntervalSince(state.lastLockAt) >= lockBufferDuration else { return }
        guard now.timeIntervalSince(state.lastUnlockAt) >= unlockCooldownDuration else { return }
        guard state.deadlines[.unlockDelay] == nil else { return }

        state.unlockPhase = .waitingDelay
        state.deadlines.set(.unlockDelay, at: now.addingTimeInterval(0.3))
        _ = effects
    }

    // MARK: - 解锁截止时间处理

    static func reduceWakeRetryDeadline(
        state: inout EngineState,
        sessionLocked: Bool,
        config: EngineConfig,
        now: Date,
        effects: inout [EngineEffect]
    ) {
        guard case .wakingDisplay(let attempt, let parallelScheduled) = state.unlockPhase else { return }
        if !sessionLocked {
            state.wakePhase = .succeeded
            state.unlockPhase = .idle
            effects.append(.releaseWakeAssertion)
            return
        }
        let nextAttempt = attempt + 1
        if nextAttempt < 10 {
            state.unlockPhase = .wakingDisplay(attempt: nextAttempt, parallelUnlockScheduled: parallelScheduled)
            state.deadlines.set(.wakeRetry, at: now.addingTimeInterval(0.5))
            effects.append(.wakeDisplay)
        } else {
            state.wakePhase = .failed
            state.unlockPhase = .idle
            state.selfWakeStartedAt = nil
            effects.append(.releaseWakeAssertion)
        }
        _ = config
    }

    static func reduceUnlockDelayDeadline(
        state: inout EngineState,
        currentSSID: String?,
        sessionLocked: Bool,
        config: EngineConfig,
        now: Date,
        effects: inout [EngineEffect]
    ) {
        guard config.enabled,
              state.presence,
              config.unlockRSSI != SignalHysteresisEngine.unlockDisabled,
              state.effectiveRSSI >= Double(config.unlockRSSI),
              state.systemPower == .awake,
              !config.wakeWithoutUnlocking,
              !state.intent.isManualLockActive,
              canAttemptUnlock(state: state, now: now),
              now.timeIntervalSince(state.lastLockAt) >= lockBufferDuration,
              now.timeIntervalSince(state.lastUnlockAt) >= unlockCooldownDuration else {
            if state.unlockPhase == .waitingDelay {
                state.unlockPhase = .idle
            }
            return
        }
        if config.pauseOnWiFi,
           !config.pauseOnWiFiSSID.isEmpty,
           let currentSSID,
           currentSSID == config.pauseOnWiFiSSID {
            if state.unlockPhase == .waitingDelay {
                state.unlockPhase = .idle
            }
            effects.append(.recordDecision(
                category: .unlock,
                outcome: .skipped,
                reason: .wifiPaused,
                rssi: state.lastRawRSSI,
                device: state.monitoredDeviceName,
                screen: state.screen.description,
                detail: "WiFi '\(config.pauseOnWiFiSSID)'"
            ))
            return
        }
        guard sessionLocked else {
            if state.unlockPhase == .waitingDelay {
                state.unlockPhase = .idle
            }
            return
        }
        effects.append(.checkPasswordStatus)
    }

    static func reducePasswordCheckResult(
        state: inout EngineState,
        availability: PasswordAvailability,
        sessionLocked: Bool,
        isSecureForPrelude: Bool,
        config: EngineConfig,
        now: Date,
        effects: inout [EngineEffect]
    ) {
        guard sessionLocked,
              state.systemPower == .awake,
              !state.intent.isManualLockActive,
              canAttemptUnlock(state: state, now: now) else {
            if state.unlockPhase == .waitingDelay {
                state.unlockPhase = .idle
            }
            return
        }

        switch availability {
        case .coldBoot:
            state.unlockPhase = .waitingNativeUnlock(startedAt: now, reason: .coldBoot)
            state.deadlines.set(.l1NativeCheck, at: now.addingTimeInterval(l1PollInterval))
            effects.append(.pollSessionUnlocked)

        case .missing:
            state.unlockPhase = .idle
            effects.append(.recordDecision(
                category: .unlock,
                outcome: .skipped,
                reason: .noPassword,
                rssi: state.lastRawRSSI,
                device: state.monitoredDeviceName,
                screen: state.screen.description,
                detail: ""
            ))

        case .error(let msg):
            state.unlockPhase = .idle
            effects.append(.recordDecision(
                category: .unlock,
                outcome: .skipped,
                reason: .keychainColdBoot,
                rssi: state.lastRawRSSI,
                device: state.monitoredDeviceName,
                screen: state.screen.description,
                detail: msg
            ))

        case .available:
            guard isSecureForPrelude else {
                state.unlockPhase = .idle
                effects.append(.recordDecision(
                    category: .unlock,
                    outcome: .skipped,
                    reason: .notSecureForInjection,
                    rssi: state.lastRawRSSI,
                    device: state.monitoredDeviceName,
                    screen: state.screen.description,
                    detail: ""
                ))
                return
            }
            if config.preferNativeWatchUnlock && state.watchAutoUnlockObserved {
                state.unlockPhase = .waitingNativeUnlock(startedAt: now, reason: .watchObserved)
                state.deadlines.set(.l1NativeCheck, at: now.addingTimeInterval(l1PollInterval))
                effects.append(.pollSessionUnlocked)
            } else {
                state.unlockPhase = .injecting
                effects.append(.injectPassword)
            }
        }
    }
}
