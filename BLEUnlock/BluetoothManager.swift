// BluetoothManager.swift — 状态机骨架（Phase 1: 仅定义状态和流转规则）
//
// 设计目标：用 enum 状态机替换 AppDelegate 中散落的布尔值标志
// 暂不修改 BLE.swift 底层逻辑

import Foundation

// MARK: - 屏幕状态

/// 屏幕状态：解锁 / 锁定 / 屏保 / 显示器休眠
enum ScreenState: Equatable {
    case unlocked
    case locked(reason: LockReason)
    case screensaver
    case displaySleeping

    enum LockReason: Equatable {
        case away          // 设备远离
        case lost          // 信号丢失
        case manual        // 用户手动锁定
        case timeout       // 超时
    }
}

// MARK: - 系统状态

/// 系统电源状态：唤醒 / 休眠
enum SystemState: Equatable {
    case awake
    case sleeping
}

// MARK: - 锁定意图

/// 锁定意图：区分自动锁和手动锁，影响解锁权限
enum LockIntent: Equatable {
    case autoLock
    case manualLock(until: Date)  // 手动锁在指定时间前禁止自动解锁
}

// MARK: - 唤醒状态

/// 显示器唤醒操作状态
enum WakeState: Equatable {
    case idle
    case pending          // 已调用 wakeDisplay，等待系统回调
    case succeeded
    case failed
}

// MARK: - 媒体播放状态

/// Now Playing 状态
enum MediaState: Equatable {
    case idle
    case wasPlaying       // 锁屏前正在播放
    case paused           // 已暂停，等待解锁后恢复
}

// MARK: - 主状态机

/// 屏幕锁定/解锁状态机
/// 管理 ScreenState + SystemState + LockIntent + WakeState + MediaState 的组合
struct ScreenLockState: Equatable {
    var screen: ScreenState = .unlocked
    var system: SystemState = .awake
    var intent: LockIntent = .autoLock
    var wake: WakeState = .idle
    var media: MediaState = .idle
    var unlockedAt: Date = .distantPast

    // MARK: - 合法状态流转

    /// 设备远离/信号丢失 → 锁定
    mutating func deviceLeft(reason: ScreenState.LockReason) {
        guard screen == .unlocked || screen == .screensaver else { return }
        guard intent != .manualLock(until: Date()) || Date() > intentManualLockDeadline else { return }
        screen = .locked(reason: reason)
        wake = .idle
        // media 在外部设置（pauseNowPlaying 是异步的）
    }

    /// 设备靠近 → 唤醒/解锁
    mutating func deviceApproached() {
        switch screen {
        case .displaySleeping:
            // 靠近 → 唤醒显示器
            wake = .pending
            screen = .locked(reason: .away)  // 唤醒后仍是锁定状态，等待解锁
        case .locked:
            // 已锁定 → 尝试解锁（需验证密码）
            break // 解锁逻辑在 tryUnlockScreen 中处理
        case .screensaver:
            // 屏保中 → 尝试解锁
            break
        case .unlocked:
            break // 已解锁，无需操作
        }
    }

    /// 系统休眠
    mutating func systemSleep() {
        system = .sleeping
        // 不改变 screen 状态，唤醒后恢复
    }

    /// 系统唤醒
    mutating func systemWake() {
        system = .awake
        // 唤醒后由 tryUnlockScreen 决定是否解锁
    }

    /// 显示器休眠
    mutating func displaySleep() {
        screen = .displaySleeping
    }

    /// 显示器唤醒
    mutating func displayWake() {
        wake = .succeeded
        if screen == .displaySleeping {
            screen = .locked(reason: .away) // 唤醒后回到锁定状态
        }
    }

    /// 屏保启动
    mutating func screensaverStart() {
        screen = .screensaver
    }

    /// 屏保停止
    mutating func screensaverStop() {
        if screen == .screensaver {
            screen = .locked(reason: .manual)
        }
    }

    /// 用户手动锁屏
    mutating func manualLock() {
        intent = .manualLock(until: Date().addingTimeInterval(10))
        screen = .locked(reason: .manual)
    }

    /// 自动解锁成功
    mutating func autoUnlocked() {
        screen = .unlocked
        intent = .autoLock
        wake = .idle
        unlockedAt = Date()
    }

    /// 用户手动解锁（系统通知 com.apple.screenIsUnlocked）
    mutating func userUnlocked() {
        screen = .unlocked
        intent = .autoLock
        wake = .idle
        unlockedAt = Date()
    }

    /// 是否允许自动解锁
    var canAutoUnlock: Bool {
        // 手动锁定后 10 秒内禁止自动解锁
        if case .manualLock(let deadline) = intent, Date() < deadline {
            return false
        }
        // 系统休眠中禁止
        if system == .sleeping { return false }
        // 显示器休眠中禁止
        if screen == .displaySleeping { return false }
        return true
    }

    /// 是否处于锁定状态
    var isLocked: Bool {
        if case .locked = screen { return true }
        return false
    }

    // MARK: - 辅助

    private var intentManualLockDeadline: Date {
        if case .manualLock(let until) = intent { return until }
        return .distantPast
    }
}

// MARK: - 状态机使用示例（伪代码）

/*
 当前散落的布尔值 → 状态机映射：

 displaySleep = true       → state.screen = .displaySleeping
 systemSleep = true        → state.system = .sleeping
 inScreensaver = true      → state.screen = .screensaver
 manualLock = true         → state.intent = .manualLock(until: ...)
 wakeSucceeded = true      → state.wake = .succeeded
 nowPlayingWasPlaying=true → state.media = .wasPlaying

 当前的 if/else 判定 → 统一用 state.canAutoUnlock 代替：
   guard !manualLock           → guard state.canAutoUnlock
   guard !systemSleep          → guard state.system == .awake
   guard !displaySleep         → guard state.screen != .displaySleeping

 事件驱动入口：
   onDisplaySleep()   → state.displaySleep()
   onDisplayWake()    → state.displayWake()
   onSystemSleep()    → state.systemSleep()
   onSystemWake()     → state.systemWake()
   onUnlock()         → state.userUnlocked()
   onScreensaverStart→ state.screensaverStart()
   onScreensaverStop()→ state.screensaverStop()
   lockNow()          → state.manualLock()
   updatePresence()   → state.deviceLeft() / state.deviceApproached()
   tryUnlockScreen()  → state.autoUnlocked() (成功时)
*/
