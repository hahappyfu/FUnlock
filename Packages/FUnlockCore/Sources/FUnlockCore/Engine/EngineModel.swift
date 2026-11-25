// EngineModel.swift
// FUnlockCore 引擎配置快照与单一真相状态树（零 UI/硬件依赖）。

import Foundation

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
    public var pendingIntrudeCheck: Bool

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
        pendingIntrudeCheck: Bool = false,
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
        self.pendingIntrudeCheck = pendingIntrudeCheck
        self.deadlines = deadlines
    }
}
