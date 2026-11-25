// LockScreenState.swift
// 锁屏/解锁状态领域模型（自 FUnManager.swift 抽离，保持单文件 <300 行）：
// ScreenState / SystemPowerState / LockIntent / WakePhase / MediaPlaybackState 与聚合状态 LockScreenState。

import Foundation

// MARK: - 状态枚举

public enum ScreenState: Equatable, Sendable, CustomStringConvertible {
    case unlocked
    case locked(reason: LockReason)
    case screensaver
    case displaySleeping

    public enum LockReason: Equatable, Sendable {
        case away, lost, manual, timeout
    }

    public var description: String {
        switch self {
        case .unlocked: return "unlocked"
        case .locked(let reason): return "locked(\(reason))"
        case .screensaver: return "screensaver"
        case .displaySleeping: return "displaySleeping"
        }
    }
}

public enum SystemPowerState: Equatable, Sendable, CustomStringConvertible {
    case awake, sleeping

    public var description: String {
        switch self {
        case .awake: return "awake"
        case .sleeping: return "sleeping"
        }
    }
}

public enum LockIntent: Equatable, Sendable {
    case autoLock
    /// deadline 为「最终兜底」过期时间（防配置错误永久卡死），正常恢复路径是 onUnlock 重置为 .autoLock
    case manualLock(deadline: Date)

    /// 手动锁屏后无条件阻止自动解锁（不依赖 deadline 过期），直到 onUnlock 重置 intent；
    /// deadline 仅作兜底标记保留，不参与判定
    public var isManualLockActive: Bool {
        if case .manualLock = self { return true }
        return false
    }
}

public enum WakePhase: Equatable, Sendable {
    case idle, pending, succeeded, failed
}

public enum MediaPlaybackState: Equatable, Sendable {
    case idle, wasPlaying, paused
}

// MARK: - 聚合状态

public struct LockScreenState: Equatable, Sendable {
    public var screen: ScreenState
    public var system: SystemPowerState
    public var intent: LockIntent
    public var wake: WakePhase
    public var media: MediaPlaybackState
    public var unlockedAt: Date

    public init(screen: ScreenState = .unlocked,
                system: SystemPowerState = .awake,
                intent: LockIntent = .autoLock,
                wake: WakePhase = .idle,
                media: MediaPlaybackState = .idle,
                unlockedAt: Date = .distantPast) {
        self.screen = screen
        self.system = system
        self.intent = intent
        self.wake = wake
        self.media = media
        self.unlockedAt = unlockedAt
    }

    public var isEffectivelyLocked: Bool {
        switch screen {
        case .locked, .screensaver, .displaySleeping: return true
        case .unlocked: return false
        }
    }
}