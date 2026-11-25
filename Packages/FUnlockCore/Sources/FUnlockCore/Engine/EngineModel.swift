// EngineModel.swift
// FUnlockCore 领域状态树、配置快照、输入事件与输出副作用模型（零 UI/硬件依赖）。

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

// MARK: - 引擎配置快照

public struct EngineConfig: Equatable, Sendable {
    public var enabled: Bool
    public var unlockRSSI: Int
    public var lockRSSI: Int
    public var proximityTimeout: TimeInterval
    public var signalTimeout: TimeInterval
    public var wakeAdvance: Int
    public var preUnlockTrigger: Int
    public var wakeOnProximity: Bool
    public var wakeWithoutUnlocking: Bool
    public var useScreensaver: Bool
    public var sleepDisplay: Bool
    public var pauseMedia: Bool
    public var lockOnIdle: Bool
    public var keepAliveWhilePresent: Bool
    public var preferNativeWatchUnlock: Bool
    public var pauseOnWiFi: Bool
    public var pauseOnWiFiSSID: String
    public var passiveMode: Bool
    public var isKnownIPhone: Bool

    public init(
        enabled: Bool = true,
        unlockRSSI: Int = -60,
        lockRSSI: Int = -80,
        proximityTimeout: TimeInterval = 5.0,
        signalTimeout: TimeInterval = 60.0,
        wakeAdvance: Int = SignalHysteresisEngine.defaultWakeAdvance,
        preUnlockTrigger: Int = SignalHysteresisEngine.defaultPreUnlockTrigger,
        wakeOnProximity: Bool = false,
        wakeWithoutUnlocking: Bool = false,
        useScreensaver: Bool = false,
        sleepDisplay: Bool = false,
        pauseMedia: Bool = false,
        lockOnIdle: Bool = true,
        keepAliveWhilePresent: Bool = true,
        preferNativeWatchUnlock: Bool = true,
        pauseOnWiFi: Bool = false,
        pauseOnWiFiSSID: String = "",
        passiveMode: Bool = false,
        isKnownIPhone: Bool = false
    ) {
        self.enabled = enabled
        self.unlockRSSI = unlockRSSI
        self.lockRSSI = lockRSSI
        self.proximityTimeout = proximityTimeout
        self.signalTimeout = signalTimeout
        self.wakeAdvance = wakeAdvance
        self.preUnlockTrigger = preUnlockTrigger
        self.wakeOnProximity = wakeOnProximity
        self.wakeWithoutUnlocking = wakeWithoutUnlocking
        self.useScreensaver = useScreensaver
        self.sleepDisplay = sleepDisplay
        self.pauseMedia = pauseMedia
        self.lockOnIdle = lockOnIdle
        self.keepAliveWhilePresent = keepAliveWhilePresent
        self.preferNativeWatchUnlock = preferNativeWatchUnlock
        self.pauseOnWiFi = pauseOnWiFi
        self.pauseOnWiFiSSID = pauseOnWiFiSSID
        self.passiveMode = passiveMode
        self.isKnownIPhone = isKnownIPhone
    }

    public static func defaultForTesting(
        enabled: Bool = true,
        unlockRSSI: Int = -60,
        lockRSSI: Int = -80,
        proximityTimeout: TimeInterval = 5.0,
        signalTimeout: TimeInterval = 60.0,
        wakeOnProximity: Bool = false,
        wakeWithoutUnlocking: Bool = false,
        useScreensaver: Bool = false,
        sleepDisplay: Bool = false,
        lockOnIdle: Bool = true,
        keepAliveWhilePresent: Bool = true,
        preferNativeWatchUnlock: Bool = true,
        pauseOnWiFi: Bool = false,
        pauseOnWiFiSSID: String = "",
        passiveMode: Bool = false,
        isKnownIPhone: Bool = false
    ) -> EngineConfig {
        EngineConfig(
            enabled: enabled,
            unlockRSSI: unlockRSSI,
            lockRSSI: lockRSSI,
            proximityTimeout: proximityTimeout,
            signalTimeout: signalTimeout,
            wakeOnProximity: wakeOnProximity,
            wakeWithoutUnlocking: wakeWithoutUnlocking,
            useScreensaver: useScreensaver,
            sleepDisplay: sleepDisplay,
            lockOnIdle: lockOnIdle,
            keepAliveWhilePresent: keepAliveWhilePresent,
            preferNativeWatchUnlock: preferNativeWatchUnlock,
            pauseOnWiFi: pauseOnWiFi,
            pauseOnWiFiSSID: pauseOnWiFiSSID,
            passiveMode: passiveMode,
            isKnownIPhone: isKnownIPhone
        )
    }

    public var preWakeThreshold: Int {
        guard unlockRSSI != SignalHysteresisEngine.unlockDisabled else { return unlockRSSI }
        return max(unlockRSSI - SignalHysteresisEngine.clampOffset(wakeAdvance), -100)
    }

    public var unlockStairThreshold: Int {
        guard unlockRSSI != SignalHysteresisEngine.unlockDisabled else { return unlockRSSI }
        return max(unlockRSSI - SignalHysteresisEngine.clampOffset(preUnlockTrigger), -100)
    }

    public var resolvedLockThreshold: Int {
        SignalHysteresisEngine.resolvedLockThreshold(unlockRSSI: unlockRSSI, lockRSSI: lockRSSI)
    }
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

// MARK: - 单一真相状态树

public struct EngineState: Equatable, Sendable {
    // 蓝牙与信号态
    public var monitoredUUID: UUID?
    public var monitoredDeviceName: String?
    public var peripheralConnected: Bool
    public var activePollInterval: TimeInterval
    public var lastPollEstimatedRSSI: Int
    public var stablePollCount: Int
    public var presence: Bool
    public var pipeline: SignalPipeline
    public var effectiveRSSI: Double
    public var displayRSSI: Double
    public var lastRawRSSI: Int?
    public var preWakeEMA: Double
    public var preWakeLastUpdate: Date?
    public var lastSignalAnomalous: Bool
    public var lastSampleAt: Date?
    public var signalTimeoutCount: Int
    public var lockConfirmContext: LockConfirmContext?
    public var deferredLockReason: String?
    public var lastHeartbeatInterval: TimeInterval

    // 会话与电源态
    public var screen: ScreenState
    public var systemPower: SystemPowerState
    public var intent: LockIntent
    public var wakePhase: WakePhase
    public var media: MediaPlaybackState
    public var idleSleepLatched: Bool
    public var selfWakeStartedAt: Date?
    public var selfLockWindowDeadline: Date?
    public var lastLockAt: Date
    public var lastUnlockAt: Date
    public var lastProximityAt: Date
    public var lastAutoUnlockSuccessAt: Date?

    // 解锁与保活事务态
    public var unlockPhase: UnlockPhase
    public var consecutiveFailures: Int
    public var recentAttemptTimestamps: [Date]
    public var watchAutoUnlockObserved: Bool
    public var consecutiveL1Timeouts: Int
    public var keepAliveActive: Bool
    public var negativeBoostSamplesRemaining: Int
    public var isCalibrating: Bool

    // 统一截止时间表
    public var deadlines: DeadlineTable

    public init(
        monitoredUUID: UUID? = nil,
        monitoredDeviceName: String? = nil,
        peripheralConnected: Bool = false,
        activePollInterval: TimeInterval = 2.0,
        lastPollEstimatedRSSI: Int = 0,
        stablePollCount: Int = 0,
        presence: Bool = false,
        pipeline: SignalPipeline = SignalPipeline(),
        effectiveRSSI: Double = -60.0,
        displayRSSI: Double = -60.0,
        lastRawRSSI: Int? = nil,
        preWakeEMA: Double = -100.0,
        preWakeLastUpdate: Date? = nil,
        lastSignalAnomalous: Bool = false,
        lastSampleAt: Date? = nil,
        signalTimeoutCount: Int = 0,
        lockConfirmContext: LockConfirmContext? = nil,
        deferredLockReason: String? = nil,
        lastHeartbeatInterval: TimeInterval = 2.0,
        screen: ScreenState = .unlocked,
        systemPower: SystemPowerState = .awake,
        intent: LockIntent = .autoLock,
        wakePhase: WakePhase = .idle,
        media: MediaPlaybackState = .idle,
        idleSleepLatched: Bool = false,
        selfWakeStartedAt: Date? = nil,
        selfLockWindowDeadline: Date? = nil,
        lastLockAt: Date = .distantPast,
        lastUnlockAt: Date = .distantPast,
        lastProximityAt: Date = .distantPast,
        lastAutoUnlockSuccessAt: Date? = nil,
        unlockPhase: UnlockPhase = .idle,
        consecutiveFailures: Int = 0,
        recentAttemptTimestamps: [Date] = [],
        watchAutoUnlockObserved: Bool = false,
        consecutiveL1Timeouts: Int = 0,
        keepAliveActive: Bool = false,
        negativeBoostSamplesRemaining: Int = 0,
        isCalibrating: Bool = false,
        deadlines: DeadlineTable = DeadlineTable()
    ) {
        self.monitoredUUID = monitoredUUID
        self.monitoredDeviceName = monitoredDeviceName
        self.peripheralConnected = peripheralConnected
        self.activePollInterval = activePollInterval
        self.lastPollEstimatedRSSI = lastPollEstimatedRSSI
        self.stablePollCount = stablePollCount
        self.presence = presence
        self.pipeline = pipeline
        self.effectiveRSSI = effectiveRSSI
        self.displayRSSI = displayRSSI
        self.lastRawRSSI = lastRawRSSI
        self.preWakeEMA = preWakeEMA
        self.preWakeLastUpdate = preWakeLastUpdate
        self.lastSignalAnomalous = lastSignalAnomalous
        self.lastSampleAt = lastSampleAt
        self.signalTimeoutCount = signalTimeoutCount
        self.lockConfirmContext = lockConfirmContext
        self.deferredLockReason = deferredLockReason
        self.lastHeartbeatInterval = lastHeartbeatInterval
        self.screen = screen
        self.systemPower = systemPower
        self.intent = intent
        self.wakePhase = wakePhase
        self.media = media
        self.idleSleepLatched = idleSleepLatched
        self.selfWakeStartedAt = selfWakeStartedAt
        self.selfLockWindowDeadline = selfLockWindowDeadline
        self.lastLockAt = lastLockAt
        self.lastUnlockAt = lastUnlockAt
        self.lastProximityAt = lastProximityAt
        self.lastAutoUnlockSuccessAt = lastAutoUnlockSuccessAt
        self.unlockPhase = unlockPhase
        self.consecutiveFailures = consecutiveFailures
        self.recentAttemptTimestamps = recentAttemptTimestamps
        self.watchAutoUnlockObserved = watchAutoUnlockObserved
        self.consecutiveL1Timeouts = consecutiveL1Timeouts
        self.keepAliveActive = keepAliveActive
        self.negativeBoostSamplesRemaining = negativeBoostSamplesRemaining
        self.isCalibrating = isCalibrating
        self.deadlines = deadlines
    }
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
