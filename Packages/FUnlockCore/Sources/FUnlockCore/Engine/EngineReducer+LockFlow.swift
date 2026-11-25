// EngineReducer+LockFlow.swift
// 纯函数状态机：离场锁屏确认计时、心跳巡检、信号失联超时、延迟补锁与自动锁屏副作用。

import Foundation

extension EngineReducer {
    static func deactivateKeepAlive(state: inout EngineState, effects: inout [EngineEffect]) {
        if state.keepAliveActive {
            state.keepAliveActive = false
            state.deadlines.cancel(.keepAliveRenew)
            effects.append(.setKeepAlive(false))
        }
    }

    private static func deferLockUntil(state: inout EngineState, reason: String, at deadline: Date) {
        state.deferredLockReason = reason
        state.deadlines.set(.deferredLockRecheck, at: deadline)
    }

    static func applyLockTimer(
        state: inout EngineState,
        effectiveRSSI: Double,
        idleSeconds: TimeInterval,
        config: EngineConfig,
        now: Date,
        effects: inout [EngineEffect]
    ) {
        guard config.lockRSSI != SignalHysteresisEngine.lockDisabled else {
            state.deadlines.cancel(.lockConfirm)
            state.lockConfirmContext = nil
            return
        }
        let decision = SignalHysteresisEngine.checkProximity(
            effectiveRSSI: effectiveRSSI,
            unlockRSSI: config.unlockRSSI,
            lockRSSI: config.lockRSSI
        )
        if !decision.isAway {
            state.deadlines.cancel(.lockConfirm)
            state.lockConfirmContext = nil
            return
        }
        guard state.presence, state.lockConfirmContext == nil else { return }

        if SignalHysteresisEngine.isWithinLockGracePeriod(
            lastUnlockTime: state.lastProximityAt,
            gracePeriod: proximityGracePeriod,
            now: now
        ) {
            return
        }
        if config.lockOnIdle && idleSeconds < 15.0 {
            state.lastSampleAt = now
            state.pipeline.decayBaseline = now
            return
        }
        startLockConfirm(state: &state, config: config, now: now, effects: &effects)
    }

    private static func startLockConfirm(
        state: inout EngineState,
        config: EngineConfig,
        now: Date,
        effects: inout [EngineEffect]
    ) {
        let timeout = SignalHysteresisEngine.lockTimeout(
            slope: state.pipeline.smoothedSlope,
            base: config.proximityTimeout
        )
        state.lockConfirmContext = LockConfirmContext(
            startedAt: now,
            pollIntervalBefore: state.activePollInterval,
            extendedOnce: false
        )
        state.deadlines.set(.lockConfirm, at: now.addingTimeInterval(timeout))
        if state.activePollInterval > 0.5 {
            state.activePollInterval = 0.5
            state.stablePollCount = 0
        }
        effects.append(.probeRSSIImmediately)
    }

    static func reduceHeartbeatDeadline(
        state: inout EngineState,
        idleSeconds: TimeInterval,
        currentSSID: String?,
        config: EngineConfig,
        now: Date,
        effects: inout [EngineEffect]
    ) {
        guard state.presence, config.lockRSSI != SignalHysteresisEngine.lockDisabled else { return }
        let eff = currentEffectiveRSSI(state: state, config: config, now: now)
        let threshold = Double(config.resolvedLockThreshold)
        let graceElapsed = now.timeIntervalSince(state.lastProximityAt)

        if eff < threshold && state.lockConfirmContext == nil && graceElapsed >= proximityGracePeriod {
            if config.lockOnIdle && idleSeconds < 15.0 {
                state.lastSampleAt = now
                state.pipeline.decayBaseline = now
            } else {
                startLockConfirm(state: &state, config: config, now: now, effects: &effects)
            }
        }
        let nextInterval = computeHeartbeatInterval(state: state, config: config, now: now)
        state.lastHeartbeatInterval = nextInterval
        state.deadlines.set(.heartbeat, at: now.addingTimeInterval(nextInterval))
        _ = currentSSID
    }

    static func reduceLockConfirmDeadline(
        state: inout EngineState,
        idleSeconds: TimeInterval,
        currentSSID: String?,
        config: EngineConfig,
        now: Date,
        effects: inout [EngineEffect]
    ) {
        guard let ctx = state.lockConfirmContext else { return }
        let lastRecv = state.lastSampleAt ?? .distantPast
        let elapsed = now.timeIntervalSince(lastRecv)
        let settlement = lockTimerSettlementAction(
            hasFreshSample: lastRecv > ctx.startedAt,
            elapsed: elapsed,
            pollIntervalBeforeTimer: ctx.pollIntervalBefore,
            alreadyExtended: ctx.extendedOnce
        )
        if case .extend(let remaining) = settlement {
            state.lockConfirmContext?.extendedOnce = true
            state.deadlines.set(.lockConfirm, at: now.addingTimeInterval(max(1.0, remaining)))
            effects.append(.probeRSSIImmediately)
            return
        }

        state.lockConfirmContext = nil
        let nowEff = currentEffectiveRSSI(state: state, config: config, now: now)
        let threshold = Double(config.resolvedLockThreshold)
        if nowEff >= threshold {
            return
        }
        if config.lockOnIdle && idleSeconds < 15.0 {
            state.lastSampleAt = now
            state.pipeline.decayBaseline = now
            return
        }
        if SignalHysteresisEngine.isWithinLockGracePeriod(
            lastUnlockTime: state.lastProximityAt,
            gracePeriod: proximityGracePeriod,
            now: now
        ) {
            deferLockUntil(
                state: &state,
                reason: "away",
                at: state.lastProximityAt.addingTimeInterval(proximityGracePeriod + 0.05)
            )
            return
        }

        state.presence = false
        state.deadlines.cancel(.heartbeat)
        executeDeviceLeft(reason: "away", config: config, currentSSID: currentSSID, now: now, state: &state, effects: &effects)
    }

    static func reduceSignalTimeoutDeadline(
        state: inout EngineState,
        idleSeconds: TimeInterval,
        currentSSID: String?,
        config: EngineConfig,
        now: Date,
        effects: inout [EngineEffect]
    ) {
        guard state.monitoredUUID != nil else { return }
        if config.lockOnIdle && idleSeconds < 15.0 {
            state.signalTimeoutCount = 0
            state.lastSampleAt = now
            state.pipeline.decayBaseline = now
            state.deadlines.set(.signalTimeout, at: now.addingTimeInterval(config.signalTimeout))
            return
        }
        if let last = state.lastSampleAt, now.timeIntervalSince(last) < config.signalTimeout {
            state.deadlines.set(.signalTimeout, at: last.addingTimeInterval(config.signalTimeout))
            return
        }
        state.signalTimeoutCount += 1
        if state.signalTimeoutCount < 3 {
            state.deadlines.set(.signalTimeout, at: now.addingTimeInterval(config.signalTimeout))
            return
        }

        let wasPresent = state.presence
        state.presence = false
        state.signalTimeoutCount = 0
        state.effectiveRSSI = -100.0
        state.lastRawRSSI = nil
        state.lockConfirmContext = nil
        state.deadlines.cancel(.heartbeat)
        state.deadlines.cancel(.lockConfirm)
        if wasPresent {
            executeDeviceLeft(reason: "lost", config: config, currentSSID: currentSSID, now: now, state: &state, effects: &effects)
        }
    }

    static func reduceDeferredLockRecheckDeadline(
        state: inout EngineState,
        idleSeconds: TimeInterval,
        currentSSID: String?,
        config: EngineConfig,
        now: Date,
        effects: inout [EngineEffect]
    ) {
        guard let reason = state.deferredLockReason,
              state.screen == .unlocked,
              !state.presence,
              currentEffectiveRSSI(state: state, config: config, now: now) < Double(config.resolvedLockThreshold) else {
            state.deferredLockReason = nil
            return
        }
        _ = idleSeconds
        executeDeviceLeft(reason: reason, config: config, currentSSID: currentSSID, now: now, state: &state, effects: &effects)
    }

    static func executeDeviceLeft(
        reason: String,
        config: EngineConfig,
        currentSSID: String?,
        now: Date,
        state: inout EngineState,
        effects: inout [EngineEffect]
    ) {
        guard config.enabled,
              !state.isCalibrating,
              state.screen == .unlocked,
              config.lockRSSI != SignalHysteresisEngine.lockDisabled else {
            state.deferredLockReason = nil
            return
        }
        if SignalHysteresisEngine.isWithinLockGracePeriod(
            lastUnlockTime: state.lastProximityAt,
            gracePeriod: proximityGracePeriod,
            now: now
        ) {
            deferLockUntil(
                state: &state,
                reason: reason,
                at: state.lastProximityAt.addingTimeInterval(proximityGracePeriod + 0.05)
            )
            return
        }
        if config.pauseOnWiFi,
           !config.pauseOnWiFiSSID.isEmpty,
           let currentSSID,
           currentSSID == config.pauseOnWiFiSSID {
            deferLockUntil(state: &state, reason: reason, at: now.addingTimeInterval(10.0))
            return
        }

        state.deferredLockReason = nil
        state.deadlines.cancel(.deferredLockRecheck)
        deactivateKeepAlive(state: &state, effects: &effects)
        state.screen = config.sleepDisplay
            ? .displaySleeping
            : .locked(reason: reason == "lost" ? .lost : .away)
        state.lastLockAt = now
        state.selfLockWindowDeadline = now.addingTimeInterval(selfLockWindowDuration)
        state.deadlines.set(.lockVerify, at: now.addingTimeInterval(2.0))
        if config.pauseMedia {
            effects.append(.pauseMediaIfNeeded)
        }
        effects.append(.performLock(reason: reason, useScreensaver: config.useScreensaver, sleepDisplay: config.sleepDisplay))
        effects.append(.recordSignalSample(
            rawRSSI: Double(state.lastRawRSSI ?? -100),
            kalmanEstimate: state.pipeline.kalmanEstimate,
            effectiveRSSI: state.effectiveRSSI,
            slope: state.pipeline.smoothedSlope,
            isAnomalous: state.lastSignalAnomalous,
            event: reason == "lost" ? .lockedLost : .locked
        ))
        effects.append(.recordDecision(
            category: .lock,
            outcome: .success,
            reason: reason == "lost" ? .lockedLost : .lockedAway,
            rssi: state.lastRawRSSI,
            device: state.monitoredDeviceName,
            screen: state.screen.description,
            detail: ""
        ))
        effects.append(.runScript(event: reason, rssi: state.lastRawRSSI, deviceName: state.monitoredDeviceName))
        effects.append(.sendNotifications(event: reason, rssi: state.effectiveRSSI, deviceName: state.monitoredDeviceName))
    }
}
