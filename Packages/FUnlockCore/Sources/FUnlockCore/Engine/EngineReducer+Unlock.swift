// EngineReducer+Unlock.swift
// 纯函数状态机：L0 有界在场保活、预备唤醒、L1 自学习零注入、L2 密码注入结果结算与负向信号快采。

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

    static func evaluateKeepAlive(
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
        } else if state.keepAliveActive {
            state.keepAliveActive = false
            state.deadlines.cancel(.keepAliveRenew)
            effects.append(.setKeepAlive(false))
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

    static func reduceL1NativeCheckDeadline(
        state: inout EngineState,
        idleSeconds: TimeInterval,
        sessionLocked: Bool,
        config: EngineConfig,
        now: Date,
        effects: inout [EngineEffect]
    ) {
        guard case .waitingNativeUnlock(let startedAt, let reason) = state.unlockPhase else { return }

        if !sessionLocked {
            reduceSessionUnlockedConfirmed(
                state: &state,
                idleSeconds: idleSeconds,
                config: config,
                now: now,
                effects: &effects
            )
            return
        }

        if now.timeIntervalSince(startedAt) < l1TimeoutDuration {
            state.deadlines.set(.l1NativeCheck, at: now.addingTimeInterval(l1PollInterval))
            effects.append(.pollSessionUnlocked)
            return
        }

        // L1 1.2s 超时
        if reason == .watchObserved {
            state.consecutiveL1Timeouts += 1
            if state.consecutiveL1Timeouts >= maxConsecutiveFailures {
                state.watchAutoUnlockObserved = false
                state.consecutiveL1Timeouts = 0
                effects.append(.persistWatchAutoUnlockObserved(false))
            }
            state.unlockPhase = .injecting
            effects.append(.injectPassword)
        } else {
            state.unlockPhase = .idle
            effects.append(.recordDecision(
                category: .unlock,
                outcome: .skipped,
                reason: .keychainColdBoot,
                rssi: state.lastRawRSSI,
                device: state.monitoredDeviceName,
                screen: state.screen.description,
                detail: "冷启动 Keychain 锁定且未观测到原生解锁"
            ))
        }
    }

    // MARK: - L2 注入结算

    static func reduceInjectionFinished(
        state: inout EngineState,
        succeeded: Bool,
        verifiedUnlocked: Bool,
        displayPoweredOn: Bool,
        axTrusted: Bool,
        sessionStillLocked: Bool,
        config: EngineConfig,
        now: Date,
        effects: inout [EngineEffect]
    ) {
        guard state.unlockPhase == .injecting else { return }

        if !succeeded {
            state.unlockPhase = .idle
            if !displayPoweredOn {
                effects.append(.recordDecision(
                    category: .unlock,
                    outcome: .skipped,
                    reason: .displaySleeping,
                    rssi: state.lastRawRSSI,
                    device: state.monitoredDeviceName,
                    screen: state.screen.description,
                    detail: "注入中止（显示器休眠未点亮，已拦截盲打）"
                ))
            } else if axTrusted {
                effects.append(.recordDecision(
                    category: .unlock,
                    outcome: .skipped,
                    reason: nil,
                    rssi: state.lastRawRSSI,
                    device: state.monitoredDeviceName,
                    screen: state.screen.description,
                    detail: "注入中止（用户手动解锁或屏幕已脱离锁定态）"
                ))
            } else {
                effects.append(.recordDecision(
                    category: .unlock,
                    outcome: .blocked,
                    reason: .axRevoked,
                    rssi: state.lastRawRSSI,
                    device: state.monitoredDeviceName,
                    screen: state.screen.description,
                    detail: "事件注入失败"
                ))
                effects.append(.showAXRevokedAlert)
            }
            return
        }

        if verifiedUnlocked || !sessionStillLocked {
            state.lastAutoUnlockSuccessAt = now
            state.selfLockWindowDeadline = nil
            state.screen = .unlocked
            state.intent = .autoLock
            state.idleSleepLatched = false
            state.selfWakeStartedAt = nil
            state.wakePhase = .idle
            state.lastUnlockAt = now
            state.lastProximityAt = now
            state.consecutiveFailures = 0
            state.consecutiveL1Timeouts = 0
            state.unlockPhase = .idle
            effects.append(.recordDecision(
                category: .unlock,
                outcome: .success,
                reason: .unlockSuccess,
                rssi: state.lastRawRSSI,
                device: state.monitoredDeviceName,
                screen: state.screen.description,
                detail: ""
            ))
            effects.append(.runScript(event: "unlocked", rssi: state.lastRawRSSI, deviceName: state.monitoredDeviceName))
            effects.append(.sendNotifications(event: "unlocked", rssi: state.effectiveRSSI, deviceName: state.monitoredDeviceName))
            effects.append(.resumeMediaIfNeeded)
            effects.append(.flushPendingAlertsAndPasswordPrompt)
            return
        }

        if !displayPoweredOn {
            state.unlockPhase = .idle
            effects.append(.recordDecision(
                category: .unlock,
                outcome: .skipped,
                reason: .displaySleeping,
                rssi: state.lastRawRSSI,
                device: state.monitoredDeviceName,
                screen: state.screen.description,
                detail: "解锁验证未通过（显示器未处于唤醒状态，不计入密码失败）"
            ))
            return
        }

        // 密码注入后仍处于锁定态：累计失败并做滑窗异常频率检测
        state.consecutiveFailures += 1
        state.recentAttemptTimestamps = state.recentAttemptTimestamps.filter {
            now.timeIntervalSince($0) < 300.0
        }
        state.recentAttemptTimestamps.append(now)
        if state.recentAttemptTimestamps.count >= 10 {
            effects.append(.showAbnormalUnlockAlert(count: state.recentAttemptTimestamps.count, window: 300))
        }

        effects.append(.recordDecision(
            category: .unlock,
            outcome: .failed,
            reason: .unlockFailed,
            rssi: state.lastRawRSSI,
            device: state.monitoredDeviceName,
            screen: state.screen.description,
            detail: "第 \(state.consecutiveFailures)/\(maxConsecutiveFailures) 次尝试"
        ))

        if state.consecutiveFailures >= maxConsecutiveFailures {
            state.unlockPhase = .degraded
            effects.append(.sendDegradedNotification)
            effects.append(.recordDecision(
                category: .unlock,
                outcome: .blocked,
                reason: .passwordMismatch,
                rssi: state.lastRawRSSI,
                device: state.monitoredDeviceName,
                screen: state.screen.description,
                detail: "失败次数过多"
            ))
            effects.append(.showPasswordMismatchAlert)
        } else {
            state.unlockPhase = .cooldown(until: now.addingTimeInterval(failureCooldownDuration))
        }
    }

    // MARK: - 负向信号快采加速

    static func reduceNegativeHint(
        state: inout EngineState,
        source: NegativeHintSource,
        config: EngineConfig,
        now: Date,
        effects: inout [EngineEffect]
    ) {
        guard state.monitoredUUID != nil, state.presence else { return }
        state.negativeBoostSamplesRemaining = 4
        if state.activePollInterval > 0.5 {
            state.activePollInterval = 0.5
            state.stablePollCount = 0
            if state.peripheralConnected && !config.passiveMode {
                state.deadlines.set(.activePoll, at: now.addingTimeInterval(0.5))
            }
        }
        effects.append(.probeRSSIImmediately)
        _ = source
    }

    // MARK: - L1 自学习与解绑/解锁收尾辅助

    static func handleSessionUnlockedLearningAndAccounting(
        state: inout EngineState,
        idleSeconds: TimeInterval,
        config: EngineConfig,
        now: Date,
        effects: inout [EngineEffect]
    ) {
        let l1Reason: L1TriggerReason? = {
            if case .waitingNativeUnlock(_, let r) = state.unlockPhase { return r }
            return nil
        }()
        let didNotInject = state.unlockPhase != .injecting
        let recentlyAutoUnlocked = state.lastAutoUnlockSuccessAt.map { now.timeIntervalSince($0) < 4.0 } ?? false
        let withinSelfWakeWindow = state.selfWakeStartedAt.map { now.timeIntervalSince($0) <= l1SelfLearnWindow } ?? false

        if didNotInject,
           !recentlyAutoUnlocked,
           l1Reason != .coldBoot,
           state.intent == .autoLock,
           withinSelfWakeWindow,
           state.presence,
           idleSeconds > 2.0,
           !config.isKnownIPhone {
            if !state.watchAutoUnlockObserved {
                state.watchAutoUnlockObserved = true
                effects.append(.persistWatchAutoUnlockObserved(true))
            }
            state.consecutiveL1Timeouts = 0
        }

        if l1Reason == .watchObserved {
            state.lastAutoUnlockSuccessAt = now
            state.consecutiveL1Timeouts = 0
            effects.append(.recordDecision(
                category: .unlock,
                outcome: .success,
                reason: .unlockSuccess,
                rssi: state.lastRawRSSI,
                device: state.monitoredDeviceName,
                screen: state.screen.description,
                detail: "原生解锁协同·零密码注入"
            ))
            effects.append(.runScript(event: "unlocked", rssi: state.lastRawRSSI, deviceName: state.monitoredDeviceName))
            effects.append(.sendNotifications(event: "unlocked", rssi: state.effectiveRSSI, deviceName: state.monitoredDeviceName))
            effects.append(.resumeMediaIfNeeded)
            state.pendingIntrudeCheck = false
        } else if !recentlyAutoUnlocked && didNotInject {
            effects.append(.recordDecision(
                category: .user,
                outcome: .success,
                reason: .userUnlocked,
                rssi: state.lastRawRSSI,
                device: state.monitoredDeviceName,
                screen: state.screen.description,
                detail: ""
            ))
            state.pendingIntrudeCheck = !state.presence && config.unlockRSSI != SignalHysteresisEngine.unlockDisabled
            if state.pendingIntrudeCheck {
                state.deadlines.set(.intrudeCheck, at: now.addingTimeInterval(2.0))
            }
        }

        state.selfWakeStartedAt = nil
        state.wakePhase = .idle
        state.deadlines.cancel(.wakeRetry)
        state.deadlines.cancel(.unlockDelay)
        state.deadlines.cancel(.l1NativeCheck)
    }
}
