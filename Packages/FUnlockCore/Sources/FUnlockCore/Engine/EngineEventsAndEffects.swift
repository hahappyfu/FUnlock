// EngineEventsAndEffects.swift
// FUnlockCore 决策日志、阶段事务枚举、输入事件与输出副作用模型（零 UI/硬件依赖）。

import Foundation

// MARK: - 决策日志模型（值语义投影，与主工程 DecisionLogger rawValue 1:1 对齐）

public enum EngineDecisionCategory: String, Equatable, Sendable {
    case unlock, lock, system, user
}

public enum EngineDecisionOutcome: String, Equatable, Sendable {
    case success, skipped, failed, blocked, info
}

public enum EngineDecisionReason: String, Equatable, Sendable {
    case noPresence
    case signalBelowThreshold
    case unlockCooldownActive
    case lockBufferActive
    case manualLockActive
    case wifiPaused
    case disabled
    case unlockDisabled
    case stateMachineBlocked
    case axRevoked
    case noPassword
    case keychainColdBoot
    case notSecureForInjection
    case displaySleeping
    case systemNotReady
    case wakeWithoutUnlocking
    case recentlyUnlocked
    case screenNotLocked
    case inputActive
    case gracePeriod
    case signalBelowLockThreshold
    case unlockSuccess
    case unlockFailed
    case unlockTimeout
    case passwordMismatch
    case lockedAway
    case lockedLost
    case displaySleep
    case displayWake
    case systemSleep
    case systemWake
    case userUnlocked
    case userLocked
}

// MARK: - 事务与事件枚举

public enum L1TriggerReason: Equatable, Sendable {
    case watchObserved
    case coldBoot
}

public enum UnlockPhase: Equatable, Sendable {
    case idle
    case wakingDisplay(attempt: Int, parallelUnlockScheduled: Bool)
    case waitingDelay
    case waitingNativeUnlock(startedAt: Date, reason: L1TriggerReason)
    case injecting
    case cooldown(until: Date)
    case degraded
}

public enum NegativeHintSource: String, Equatable, Sendable {
    case audioOutputDisconnected
    case networkChanged
}

public struct LockConfirmContext: Equatable, Sendable {
    public var startedAt: Date
    public var pollIntervalBefore: TimeInterval
    public var extendedOnce: Bool

    public init(startedAt: Date, pollIntervalBefore: TimeInterval, extendedOnce: Bool = false) {
        self.startedAt = startedAt
        self.pollIntervalBefore = pollIntervalBefore
        self.extendedOnce = extendedOnce
    }
}

public enum LockTimerSettlement: Equatable, Sendable {
    case settleNow
    case extend(TimeInterval)
}

public enum PasswordAvailability: Equatable, Sendable {
    case available
    case missing
    case coldBoot
    case error(String)
}

// MARK: - 引擎输入事件与输出副作用

public enum EngineEvent: Equatable, Sendable {
    case bindDevice(uuid: UUID, name: String)
    case unbindDevice
    case bleSample(rssi: Int, source: SignalSource, idleSeconds: TimeInterval)
    case bleConnected
    case bleDisconnected
    case blePoweredOff
    case blePoweredOn
    case deadlineFired(DeadlineID, scheduledAt: Date, idleSeconds: TimeInterval, currentSSID: String?, sessionLocked: Bool)
    case systemWillSleep
    case systemDidWake
    case displayDidSleep(idleSeconds: TimeInterval)
    case displayDidWake(systemLocked: Bool)
    case systemScreenLockedNotification(sessionLocked: Bool)
    case screensaverDidStart
    case screensaverDidStop
    case sessionUnlockNotification(sessionLocked: Bool, idleSeconds: TimeInterval)
    case sessionUnlockedConfirmed(idleSeconds: TimeInterval)
    case lockNowRequested(sessionLocked: Bool)
    case passwordCheckResult(PasswordAvailability, sessionLocked: Bool, isSecureForPrelude: Bool)
    case injectionFinished(succeeded: Bool, verifiedUnlocked: Bool, displayPoweredOn: Bool, axTrusted: Bool, sessionStillLocked: Bool)
    case userIntervention
    case resetDegraded(clearFailures: Bool)
    case setCalibrating(Bool)
    case configUpdated(idleSeconds: TimeInterval)
    case negativeHintReceived(NegativeHintSource)
}

public enum EngineEffect: Equatable, Sendable {
    case startMonitoringDevice(UUID)
    case stopMonitoringDevice
    case connectPeripheral
    case cancelPeripheralConnection
    case probeRSSIImmediately
    case updateScanMode
    case performLock(reason: String, useScreensaver: Bool, sleepDisplay: Bool)
    case pauseMediaIfNeeded
    case resumeMediaIfNeeded
    case setKeepAlive(Bool)
    case wakeDisplay
    case releaseWakeAssertion
    case checkPasswordStatus
    case pollSessionUnlocked
    case injectPassword
    case persistWatchAutoUnlockObserved(Bool)
    case recordDecision(
        category: EngineDecisionCategory,
        outcome: EngineDecisionOutcome,
        reason: EngineDecisionReason?,
        rssi: Int?,
        device: String?,
        screen: String?,
        detail: String
    )
    case recordSignalSample(
        rawRSSI: Double,
        kalmanEstimate: Double,
        effectiveRSSI: Double,
        slope: Double,
        isAnomalous: Bool,
        event: SignalSampleEvent?
    )
    case runScript(event: String, rssi: Int?, deviceName: String?)
    case sendNotifications(event: String, rssi: Double, deviceName: String?)
    case sendDegradedNotification
    case clearLockNotification
    case showBluetoothPowerWarning
    case showPasswordMismatchAlert
    case showAXRevokedAlert
    case showAbnormalUnlockAlert(count: Int, window: Int)
    case flushPendingAlertsAndPasswordPrompt
    case checkForUpdates
    case flushCandidateDevicesUI
    case expireDiscoveredDevice(UUID)
}
