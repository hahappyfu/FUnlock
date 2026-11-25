// EngineReducer+LockAndSession.swift
// 纯函数状态机：BLE 采样管道、自适应轮询、心跳/信号超时、离场锁屏结算与系统电源/会话流转。

import Foundation

extension EngineReducer {
    // MARK: - 纯计算辅助

    public static func sanitizeRSSI(_ raw: Int) -> Int? {
        guard raw < 0, raw >= -127 else { return nil }
        return raw
    }

    public static func decayedEffectiveRSSI(
        effectiveRSSI: Double,
        elapsedSinceLastReceive: TimeInterval,
        lockThreshold: Int?,
        pollInterval: TimeInterval = 2.0
    ) -> Double {
        let cap: Double = lockThreshold.map { max(20.0, effectiveRSSI - Double($0) + 6.0) } ?? 20.0
        let grace = max(6.0, pollInterval + 2.0)
        let penalty: Double
        if elapsedSinceLastReceive <= grace {
            penalty = 0
        } else if elapsedSinceLastReceive <= grace + 4.0 {
            penalty = (elapsedSinceLastReceive - grace) * 0.75
        } else {
            penalty = min(3.0 + (elapsedSinceLastReceive - grace - 4.0), cap)
        }
        return max(effectiveRSSI - penalty, -100.0)
    }

    public static func currentEffectiveRSSI(
        state: EngineState,
        config: EngineConfig,
        now: Date
    ) -> Double {
        let elapsed = state.lastSampleAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
        let pollInterval = state.lockConfirmContext?.pollIntervalBefore ?? state.activePollInterval
        return decayedEffectiveRSSI(
            effectiveRSSI: state.effectiveRSSI,
            elapsedSinceLastReceive: elapsed,
            lockThreshold: config.resolvedLockThreshold,
            pollInterval: pollInterval
        )
    }

    public static func staleLossDeadline(forPollInterval pollInterval: TimeInterval) -> TimeInterval {
        max(10.0, pollInterval + 4.0)
    }

    public static func lockTimerSettlementAction(
        hasFreshSample: Bool,
        elapsed: TimeInterval,
        pollIntervalBeforeTimer: TimeInterval,
        alreadyExtended: Bool
    ) -> LockTimerSettlement {
        if hasFreshSample { return .settleNow }
        let deadline = staleLossDeadline(forPollInterval: pollIntervalBeforeTimer)
        if elapsed >= deadline || alreadyExtended { return .settleNow }
        return .extend(deadline - elapsed)
    }

    // MARK: - 设备绑定与解绑

    static func reduceBindDevice(
        state: inout EngineState,
        uuid: UUID,
        name: String,
        config: EngineConfig,
        now: Date,
        effects: inout [EngineEffect]
    ) {
        if let old = state.monitoredUUID, old != uuid {
            effects.append(.cancelPeripheralConnection)
        }
        state.monitoredUUID = uuid
        state.monitoredDeviceName = name
        state.peripheralConnected = false
        state.presence = false
        state.signalTimeoutCount = 0
        state.stablePollCount = 0
        state.activePollInterval = 2.0
        state.lastPollEstimatedRSSI = 0
        state.pipeline.reset()
        state.effectiveRSSI = -60.0
        state.displayRSSI = -60.0
        state.lastRawRSSI = nil
        state.preWakeEMA = -100.0
        state.preWakeLastUpdate = nil
        state.lastSignalAnomalous = false
        state.lastSampleAt = nil
        state.lockConfirmContext = nil
        state.deferredLockReason = nil
        state.deadlines.cancelMonitorDeadlines()
        state.deadlines.set(.signalTimeout, at: now.addingTimeInterval(config.signalTimeout))
        effects.append(.startMonitoringDevice(uuid))
    }

    static func reduceUnbindDevice(
        state: inout EngineState,
        effects: inout [EngineEffect]
    ) {
        if state.peripheralConnected {
            effects.append(.cancelPeripheralConnection)
        }
        if state.keepAliveActive {
            state.keepAliveActive = false
            effects.append(.setKeepAlive(false))
        }
        if case .wakingDisplay = state.unlockPhase {
            effects.append(.releaseWakeAssertion)
        }
        state.monitoredUUID = nil
        state.monitoredDeviceName = nil
        state.peripheralConnected = false
        state.presence = false
        state.signalTimeoutCount = 0
        state.stablePollCount = 0
        state.activePollInterval = 2.0
        state.lastPollEstimatedRSSI = 0
        state.pipeline.reset()
        state.effectiveRSSI = -60.0
        state.displayRSSI = -60.0
        state.lastRawRSSI = nil
        state.preWakeEMA = -100.0
        state.preWakeLastUpdate = nil
        state.lastSignalAnomalous = false
        state.lastSampleAt = nil
        state.lockConfirmContext = nil
        state.deferredLockReason = nil
        state.unlockPhase = .idle
        state.selfWakeStartedAt = nil
        state.deadlines.cancelMonitorDeadlines()
        effects.append(.stopMonitoringDevice)
    }

    // MARK: - BLE 采样摄入

    static func reduceBLESample(
        state: inout EngineState,
        rawRSSI: Int,
        source: SignalSource,
        idleSeconds: TimeInterval,
        config: EngineConfig,
        now: Date,
        effects: inout [EngineEffect]
    ) {
        guard state.monitoredUUID != nil, let rssi = sanitizeRSSI(rawRSSI) else { return }

        state.signalTimeoutCount = 0
        state.pipeline.latestRSSIs.append(Double(rssi))
        state.pipeline.rssiTimestamps.append(now)
        let cutoff = now.addingTimeInterval(-state.pipeline.effectiveWindowDuration())
        while let first = state.pipeline.rssiTimestamps.first,
              first < cutoff,
              state.pipeline.rssiTimestamps.count > state.pipeline.iqrSampleCount {
            state.pipeline.rssiTimestamps.removeFirst()
            state.pipeline.latestRSSIs.removeFirst()
        }

        let decision = state.pipeline.process(rssi: rssi, source: source, now: now)
        state.lastSampleAt = now
        state.lastRawRSSI = rssi
        state.effectiveRSSI = decision.effectiveRSSI
        state.lastSignalAnomalous = decision.isAnomalous
        state.displayRSSI = 0.1 * Double(rssi) + 0.9 * state.displayRSSI

        if let lastPre = state.preWakeLastUpdate {
            let dt = max(0, now.timeIntervalSince(lastPre))
            let alpha = 1.0 - exp(-dt / 1.0)
            state.preWakeEMA = alpha * Double(rssi) + (1.0 - alpha) * state.preWakeEMA
        } else {
            state.preWakeEMA = Double(rssi)
        }
        state.preWakeLastUpdate = now

        state.deadlines.set(.signalTimeout, at: now.addingTimeInterval(config.signalTimeout))
        updateAdaptivePolling(state: &state, decision: decision, source: source, config: config, now: now)

        let proximity = SignalHysteresisEngine.checkProximity(
            effectiveRSSI: decision.effectiveRSSI,
            unlockRSSI: config.unlockRSSI,
            lockRSSI: config.lockRSSI
        )
        let unlockEnabled = config.unlockRSSI != SignalHysteresisEngine.unlockDisabled
        var flippedClose = false

        if proximity.isClose && !state.presence {
            state.presence = true
            flippedClose = true
            state.lastProximityAt = now
            state.idleSleepLatched = false
            state.deferredLockReason = nil
            state.deadlines.cancel(.deferredLockRecheck)
            state.deadlines.cancel(.lockConfirm)
            state.lockConfirmContext = nil
            state.pipeline.latestRSSIs.removeAll()
            state.pipeline.rssiTimestamps.removeAll()
        }

        effects.append(.recordSignalSample(
            rawRSSI: Double(rssi),
            kalmanEstimate: decision.kalmanEstimate,
            effectiveRSSI: decision.effectiveRSSI,
            slope: decision.slope,
            isAnomalous: decision.isAnomalous,
            event: (flippedClose && unlockEnabled) ? .unlocked : nil
        ))

        if idleSeconds.isFinite, idleSeconds >= 0, idleSeconds < 2.0 {
            state.idleSleepLatched = false
        }

        if state.presence && config.lockRSSI != SignalHysteresisEngine.lockDisabled {
            ensureHeartbeatScheduled(state: &state, config: config, now: now)
        }

        applyLockTimer(state: &state, effectiveRSSI: currentEffectiveRSSI(state: state, config: config, now: now), idleSeconds: idleSeconds, config: config, now: now, effects: &effects)
        evaluateKeepAlive(state: &state, idleSeconds: idleSeconds, config: config, now: now, effects: &effects)
        evaluatePreWakeAndApproach(state: &state, config: config, now: now, effects: &effects)
    }

    private static func updateAdaptivePolling(
        state: inout EngineState,
        decision: SignalDecision,
        source: SignalSource,
        config: EngineConfig,
        now: Date
    ) {
        guard source == .connected, !config.passiveMode else { return }

        let nearThreshold: Bool
        if config.unlockRSSI != SignalHysteresisEngine.unlockDisabled {
            let nearClimb = SignalHysteresisEngine.isNearThreshold(decision.effectiveRSSI, threshold: Double(config.unlockStairThreshold))
            let nearLock = config.lockRSSI == SignalHysteresisEngine.lockDisabled
                ? false
                : SignalHysteresisEngine.isNearThreshold(decision.effectiveRSSI, threshold: Double(config.resolvedLockThreshold))
            nearThreshold = nearClimb || nearLock
        } else if config.lockRSSI != SignalHysteresisEngine.lockDisabled {
            nearThreshold = SignalHysteresisEngine.isNearThreshold(decision.effectiveRSSI, threshold: Double(config.lockRSSI))
        } else {
            nearThreshold = false
        }

        let fluctuation = abs(decision.kalmanEstimate - Double(state.lastPollEstimatedRSSI))
        state.lastPollEstimatedRSSI = Int(decision.kalmanEstimate)

        if state.negativeBoostSamplesRemaining > 0 {
            state.negativeBoostSamplesRemaining -= 1
            state.activePollInterval = 0.5
        } else if nearThreshold {
            state.activePollInterval = 0.5
        } else {
            if fluctuation < 5 {
                state.stablePollCount += 1
            } else {
                state.stablePollCount = 0
            }
            if state.activePollInterval == 0.5 {
                state.activePollInterval = 2.0
                state.stablePollCount = 0
            } else if state.stablePollCount >= 10 && state.activePollInterval < 8.0 {
                state.activePollInterval = 8.0
            } else if fluctuation >= 5 && state.activePollInterval > 2.0 {
                state.activePollInterval = 2.0
                state.stablePollCount = 0
            }
        }
        state.deadlines.set(.activePoll, at: now.addingTimeInterval(state.activePollInterval))
    }

    // MARK: - 心跳与锁定时延

    private static func computeHeartbeatInterval(state: EngineState, config: EngineConfig, now: Date) -> TimeInterval {
        let eff = currentEffectiveRSSI(state: state, config: config, now: now)
        let baseTh = Double(config.unlockRSSI) + 10.0
        let lockTh = config.lockRSSI == SignalHysteresisEngine.lockDisabled
            ? Double(config.unlockRSSI)
            : Double(config.lockRSSI) + 10.0
        if eff > baseTh { return 8.0 }
        if eff < lockTh { return 2.0 }
        return 3.0
    }

    static func ensureHeartbeatScheduled(state: inout EngineState, config: EngineConfig, now: Date) {
        guard config.lockRSSI != SignalHysteresisEngine.lockDisabled, state.presence else {
            state.deadlines.cancel(.heartbeat)
            return
        }
        if state.deadlines[.heartbeat] == nil {
            let interval = computeHeartbeatInterval(state: state, config: config, now: now)
            state.lastHeartbeatInterval = interval
            state.deadlines.set(.heartbeat, at: now.addingTimeInterval(interval))
        }
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
            state.deferredLockReason = "away"
            state.deadlines.set(.deferredLockRecheck, at: state.lastProximityAt.addingTimeInterval(proximityGracePeriod + 0.05))
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
            state.deferredLockReason = reason
            state.deadlines.set(.deferredLockRecheck, at: state.lastProximityAt.addingTimeInterval(proximityGracePeriod + 0.05))
            return
        }
        if config.pauseOnWiFi,
           !config.pauseOnWiFiSSID.isEmpty,
           let currentSSID,
           currentSSID == config.pauseOnWiFiSSID {
            state.deferredLockReason = reason
            state.deadlines.set(.deferredLockRecheck, at: now.addingTimeInterval(10.0))
            return
        }

        state.deferredLockReason = nil
        state.deadlines.cancel(.deferredLockRecheck)
        if state.keepAliveActive {
            state.keepAliveActive = false
            state.deadlines.cancel(.keepAliveRenew)
            effects.append(.setKeepAlive(false))
        }
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

    // MARK: - 电源与会话通知

    static func reduceSystemWillSleep(state: inout EngineState, effects: inout [EngineEffect]) {
        state.systemPower = .sleeping
        state.deadlines.cancel(.systemWakeReady)
        state.deadlines.cancel(.deferredLockRecheck)
        state.deferredLockReason = nil
        if state.keepAliveActive {
            state.keepAliveActive = false
            state.deadlines.cancel(.keepAliveRenew)
            effects.append(.setKeepAlive(false))
        }
        effects.append(.recordDecision(category: .system, outcome: .info, reason: .systemSleep, rssi: state.lastRawRSSI, device: state.monitoredDeviceName, screen: state.screen.description, detail: ""))
    }

    static func reduceSystemDidWake(state: inout EngineState, now: Date, effects: inout [EngineEffect]) {
        state.deadlines.set(.systemWakeReady, at: now.addingTimeInterval(1.0))
        effects.append(.recordDecision(category: .system, outcome: .info, reason: .systemWake, rssi: state.lastRawRSSI, device: state.monitoredDeviceName, screen: state.screen.description, detail: ""))
    }

    static func reduceDisplayDidSleep(state: inout EngineState, idleSeconds: TimeInterval, effects: inout [EngineEffect]) {
        state.screen = .displaySleeping
        if state.keepAliveActive {
            state.keepAliveActive = false
            state.deadlines.cancel(.keepAliveRenew)
            effects.append(.setKeepAlive(false))
        }
        if (state.presence && idleSeconds >= keepAliveIdleLimit) || state.intent.isManualLockActive {
            state.idleSleepLatched = true
        }
        effects.append(.recordDecision(category: .system, outcome: .info, reason: .displaySleep, rssi: state.lastRawRSSI, device: state.monitoredDeviceName, screen: state.screen.description, detail: ""))
    }

    static func reduceDisplayDidWake(state: inout EngineState, systemLocked: Bool, config: EngineConfig, now: Date, effects: inout [EngineEffect]) {
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
        effects.append(.recordDecision(category: .system, outcome: .info, reason: .displayWake, rssi: state.lastRawRSSI, device: state.monitoredDeviceName, screen: state.screen.description, detail: ""))
    }

    static func reduceSystemScreenLockedNotification(state: inout EngineState, sessionLocked: Bool, now: Date, effects: inout [EngineEffect]) {
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
        if state.keepAliveActive {
            state.keepAliveActive = false
            state.deadlines.cancel(.keepAliveRenew)
            effects.append(.setKeepAlive(false))
        }
        if !isSelfLock {
            effects.append(.recordDecision(category: .user, outcome: .success, reason: .userLocked, rssi: state.lastRawRSSI, device: state.monitoredDeviceName, screen: state.screen.description, detail: ""))
        }
    }

    static func reduceScreensaverDidStart(state: inout EngineState, now: Date, effects: inout [EngineEffect]) {
        let withinSelfLock = state.selfLockWindowDeadline.map { now <= $0 } ?? false
        if !withinSelfLock {
            state.intent = .manualLock(deadline: now.addingTimeInterval(manualLockIntentDuration))
        }
        state.screen = .screensaver
        if state.keepAliveActive {
            state.keepAliveActive = false
            state.deadlines.cancel(.keepAliveRenew)
            effects.append(.setKeepAlive(false))
        }
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
        if state.keepAliveActive {
            state.keepAliveActive = false
            state.deadlines.cancel(.keepAliveRenew)
            effects.append(.setKeepAlive(false))
        }
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
