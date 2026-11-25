// EngineReducer+BLESample.swift
// 纯函数状态机：RSSI 清洗与衰减计算、设备绑定/解绑复位、BLE 采样摄入与自适应轮询。

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

    private static func resetBLETrackingState(state: inout EngineState) {
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
    }

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
        resetBLETrackingState(state: &state)
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
        deactivateKeepAlive(state: &state, effects: &effects)
        if case .wakingDisplay = state.unlockPhase {
            effects.append(.releaseWakeAssertion)
        }
        state.monitoredUUID = nil
        state.monitoredDeviceName = nil
        resetBLETrackingState(state: &state)
        state.unlockPhase = .idle
        state.selfWakeStartedAt = nil
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

    // MARK: - 心跳调度计算

    static func computeHeartbeatInterval(state: EngineState, config: EngineConfig, now: Date) -> TimeInterval {
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
}
