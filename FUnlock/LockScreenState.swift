// LockScreenState.swift
// 锁屏/解锁状态领域模型（自 FUnManager.swift 抽离，保持单文件 <300 行）：
// ScreenState / SystemPowerState / LockIntent / WakePhase / MediaPlaybackState 与聚合状态 LockScreenState。

import Foundation

// MARK: - 状态枚举

enum ScreenState: Equatable, CustomStringConvertible {
    case unlocked
    case locked(reason: LockReason)
    case screensaver
    case displaySleeping

    enum LockReason: Equatable {
        case away, lost, manual, timeout
    }

    var description: String {
        switch self {
        case .unlocked: return "unlocked"
        case .locked(let reason): return "locked(\(reason))"
        case .screensaver: return "screensaver"
        case .displaySleeping: return "displaySleeping"
        }
    }
}

enum SystemPowerState: Equatable, CustomStringConvertible {
    case awake, sleeping

    var description: String {
        switch self {
        case .awake: return "awake"
        case .sleeping: return "sleeping"
        }
    }
}

enum LockIntent: Equatable {
    case autoLock
    /// deadline 为「最终兜底」过期时间（防配置错误永久卡死），正常恢复路径是 onUnlock 重置为 .autoLock
    case manualLock(deadline: Date)

    /// 手动锁屏后无条件阻止自动解锁（不依赖 deadline 过期），直到 onUnlock 重置 intent；
    /// deadline 仅作兜底标记保留，不参与判定
    var isManualLockActive: Bool {
        if case .manualLock = self { return true }
        return false
    }
}

enum WakePhase: Equatable {
    case idle, pending, succeeded, failed
}

enum MediaPlaybackState: Equatable {
    case idle, wasPlaying, paused
}

// MARK: - 聚合状态

struct LockScreenState: Equatable {
    var screen: ScreenState = .unlocked
    var system: SystemPowerState = .awake
    var intent: LockIntent = .autoLock
    var wake: WakePhase = .idle
    var media: MediaPlaybackState = .idle
    var unlockedAt: Date = .distantPast

    var isEffectivelyLocked: Bool {
        switch screen {
        case .locked, .screensaver, .displaySleeping: return true
        case .unlocked: return false
        }
    }
}
