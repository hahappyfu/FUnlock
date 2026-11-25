// EngineReducer.swift
// 纯函数状态机总入口：(inout EngineState, EngineEvent, EngineConfig, Date) -> [EngineEffect]

import Foundation

public enum EngineReducer {
    public static let lockBufferDuration: TimeInterval = 0.8
    public static let unlockCooldownDuration: TimeInterval = 5.0
    public static let failureCooldownDuration: TimeInterval = 10.0
    public static let proximityGracePeriod: TimeInterval = 5.0
    public static let maxConsecutiveFailures: Int = 3
    public static let selfLockWindowDuration: TimeInterval = 10.0
    public static let manualLockIntentDuration: TimeInterval = 86_400.0
    public static let keepAliveIdleLimit: TimeInterval = 900.0
    public static let keepAliveRenewInterval: TimeInterval = 30.0
    public static let l1TimeoutDuration: TimeInterval = 1.2
    public static let l1PollInterval: TimeInterval = 0.15
    public static let l1SelfLearnWindow: TimeInterval = 2.5

    @discardableResult
    public static func reduce(
        state: inout EngineState,
        event: EngineEvent,
        config: EngineConfig,
        now: Date
    ) -> [EngineEffect] {
        var effects: [EngineEffect] = []

        switch event {
        case .bindDevice(let uuid, let name):
            reduceBindDevice(state: &state, uuid: uuid, name: name, config: config, now: now, effects: &effects)

        case .unbindDevice:
            reduceUnbindDevice(state: &state, effects: &effects)

        case .bleSample(let rssi, let source, let idleSeconds):
            reduceBLESample(state: &state, rawRSSI: rssi, source: source, idleSeconds: idleSeconds, config: config, now: now, effects: &effects)

        case .bleConnected:
            state.peripheralConnected = true
            state.deadlines.cancel(.peripheralConnectTimeout)

        case .bleDisconnected:
            state.peripheralConnected = false
            state.deadlines.cancel(.activePoll)
            state.deadlines.cancel(.peripheralConnectTimeout)
            state.signalTimeoutCount = 0
            effects.append(.updateScanMode)

        case .blePoweredOff:
            state.deadlines.cancelMonitorDeadlines()
            state.presence = false
            state.peripheralConnected = false
            state.lockConfirmContext = nil
            effects.append(.showBluetoothPowerWarning)

        case .blePoweredOn:
            if state.monitoredUUID != nil {
                state.deadlines.set(.signalTimeout, at: now.addingTimeInterval(config.signalTimeout))
                effects.append(.updateScanMode)
            }

        case .deadlineFired(let id, let scheduledAt, let idleSeconds, let currentSSID, let sessionLocked):
            guard state.deadlines.matches(id, scheduledAt: scheduledAt) else { return [] }
            state.deadlines.cancel(id)
            reduceDeadline(
                state: &state,
                id: id,
                idleSeconds: idleSeconds,
                currentSSID: currentSSID,
                sessionLocked: sessionLocked,
                config: config,
                now: now,
                effects: &effects
            )

        case .systemWillSleep:
            reduceSystemWillSleep(state: &state, effects: &effects)

        case .systemDidWake:
            reduceSystemDidWake(state: &state, now: now, effects: &effects)

        case .displayDidSleep(let idleSeconds):
            reduceDisplayDidSleep(state: &state, idleSeconds: idleSeconds, effects: &effects)

        case .displayDidWake(let systemLocked):
            reduceDisplayDidWake(state: &state, systemLocked: systemLocked, config: config, now: now, effects: &effects)

        case .systemScreenLockedNotification(let sessionLocked):
            reduceSystemScreenLockedNotification(state: &state, sessionLocked: sessionLocked, now: now, effects: &effects)

        case .screensaverDidStart:
            reduceScreensaverDidStart(state: &state, now: now, effects: &effects)

        case .screensaverDidStop:
            reduceScreensaverDidStop(state: &state)

        case .sessionUnlockNotification(let sessionLocked, let idleSeconds):
            reduceSessionUnlockNotification(state: &state, sessionLocked: sessionLocked, idleSeconds: idleSeconds, config: config, now: now, effects: &effects)

        case .sessionUnlockedConfirmed(let idleSeconds):
            reduceSessionUnlockedConfirmed(state: &state, idleSeconds: idleSeconds, config: config, now: now, effects: &effects)

        case .lockNowRequested(let sessionLocked):
            reduceLockNowRequested(state: &state, sessionLocked: sessionLocked, config: config, now: now, effects: &effects)

        case .passwordCheckResult, .injectionFinished, .negativeHintReceived:
            // Task 3 接管渐进解锁（L0/L1/L2）与负向信号快采分支
            break

        case .userIntervention:
            reduceUserIntervention(state: &state, effects: &effects)

        case .resetDegraded(let clearFailures):
            state.unlockPhase = .idle
            if clearFailures {
                state.consecutiveFailures = 0
            }

        case .setCalibrating(let calibrating):
            state.isCalibrating = calibrating

        case .configUpdated(let idleSeconds):
            if config.lockRSSI == SignalHysteresisEngine.lockDisabled {
                state.deadlines.cancel(.lockConfirm)
                state.deadlines.cancel(.heartbeat)
                state.lockConfirmContext = nil
            }
            if !config.enabled || !config.keepAliveWhilePresent || idleSeconds >= keepAliveIdleLimit {
                if state.keepAliveActive {
                    state.keepAliveActive = false
                    state.deadlines.cancel(.keepAliveRenew)
                    effects.append(.setKeepAlive(false))
                }
            }
        }

        return effects
    }

    private static func reduceDeadline(
        state: inout EngineState,
        id: DeadlineID,
        idleSeconds: TimeInterval,
        currentSSID: String?,
        sessionLocked: Bool,
        config: EngineConfig,
        now: Date,
        effects: inout [EngineEffect]
    ) {
        switch id {
        case .signalTimeout:
            reduceSignalTimeoutDeadline(state: &state, idleSeconds: idleSeconds, currentSSID: currentSSID, config: config, now: now, effects: &effects)

        case .heartbeat:
            reduceHeartbeatDeadline(state: &state, idleSeconds: idleSeconds, currentSSID: currentSSID, config: config, now: now, effects: &effects)

        case .lockConfirm:
            reduceLockConfirmDeadline(state: &state, idleSeconds: idleSeconds, currentSSID: currentSSID, config: config, now: now, effects: &effects)

        case .deferredLockRecheck:
            reduceDeferredLockRecheckDeadline(state: &state, idleSeconds: idleSeconds, currentSSID: currentSSID, config: config, now: now, effects: &effects)

        case .lockVerify:
            if !sessionLocked && state.screen != .unlocked {
                state.screen = .unlocked
                state.selfLockWindowDeadline = nil
            }

        case .screenLockConfirm:
            if sessionLocked {
                applySystemScreenLocked(state: &state, now: now, effects: &effects)
            }

        case .screenUnlockConfirm:
            if !sessionLocked {
                reduceSessionUnlockedConfirmed(state: &state, idleSeconds: idleSeconds, config: config, now: now, effects: &effects)
            }

        case .systemWakeReady:
            guard state.systemPower == .sleeping else { return }
            state.systemPower = .awake
            if !sessionLocked {
                reconcileUnlockedIfNeeded(state: &state)
            }

        case .activePoll:
            if state.peripheralConnected && !config.passiveMode {
                effects.append(.probeRSSIImmediately)
                state.deadlines.set(.activePoll, at: now.addingTimeInterval(state.activePollInterval))
            }

        case .peripheralConnectTimeout:
            effects.append(.cancelPeripheralConnection)
            effects.append(.updateScanMode)

        case .uiDiscoveryFlush:
            effects.append(.flushCandidateDevicesUI)

        case .deviceExpiry(let uuid):
            effects.append(.expireDiscoveredDevice(uuid))

        case .wakeRetry, .unlockDelay, .l1NativeCheck, .intrudeCheck, .keepAliveRenew:
            // Task 3 实现 L0/L1/L2 与入侵检查时序
            break
        }
    }
}
