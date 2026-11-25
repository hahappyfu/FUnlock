// EngineReducer+UnlockSettlement.swift
// 纯函数状态机：L1 原生协商超时/退化、L2 密码注入结果结算与 L1 自学习/负向信号快采加速。

import Foundation

extension EngineReducer {
    // MARK: - L1 1.2s 原生解锁轮询与自动退化

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

    // MARK: - L2 注入结算与滑窗降级保护

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

    // MARK: - 负向信号快采加速与 L1 自学习收尾

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
