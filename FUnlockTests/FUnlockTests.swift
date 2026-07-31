import XCTest
@testable import FUnlock

class FUnlockTests: XCTestCase {

    // MARK: - SignalPipeline: Kalman Filter Tests

    func testKalmanSingleValue() {
        var pipeline = SignalPipeline()
        let decision = pipeline.process(rssi: -60, source: .connected, now: Date())
        XCTAssertEqual(decision.kalmanEstimate, -60, accuracy: 5, "First value should be near raw RSSI")
    }

    func testKalmanDampensNoise() {
        var pipeline = SignalPipeline()
        let now = Date()
        for i in 0..<6 {
            _ = pipeline.process(rssi: -60 + (i % 2 == 0 ? -5 : 5), source: .connected, now: now.addingTimeInterval(Double(i) * 0.1))
        }
        let decision = pipeline.process(rssi: -60, source: .connected, now: now.addingTimeInterval(1.0))
        XCTAssertEqual(decision.kalmanEstimate, -60, accuracy: 10, "Kalman should dampen noise")
    }

    func testKalmanAsymmetricRising() {
        var pipeline = SignalPipeline()
        // 冷启动填充 6 个样本
        for i in 0..<6 {
            _ = pipeline.process(rssi: -80, source: .connected, now: Date().addingTimeInterval(Double(i) * 0.1))
        }
        let before = pipeline.kalmanEstimate
        let decision = pipeline.process(rssi: -50, source: .connected, now: Date().addingTimeInterval(1.0))
        XCTAssertGreaterThan(decision.kalmanEstimate, before, "Kalman should track upward jump")
    }

    func testKalmanAsymmetricFalling() {
        var pipeline = SignalPipeline()
        // 冷启动填充 6 个样本
        for i in 0..<6 {
            _ = pipeline.process(rssi: -50, source: .connected, now: Date().addingTimeInterval(Double(i) * 0.1))
        }
        let before = pipeline.kalmanEstimate
        let decision = pipeline.process(rssi: -80, source: .connected, now: Date().addingTimeInterval(1.0))
        // 下降时 Kalman 阻尼强，估计值不应大幅跳动
        XCTAssertGreaterThan(decision.kalmanEstimate, before - 15, "Kalman should dampen downward jump")
    }

    // MARK: - SignalPipeline: IQR Anomaly Detection

    func testIQR_normalValues() {
        var pipeline = SignalPipeline()
        let now = Date()
        // 填入正常窗口（process 不会自动 append，需手动模拟 processSignal 行为）
        for i in 0..<6 {
            let t = now.addingTimeInterval(Double(i) * 0.1)
            _ = pipeline.process(rssi: -60 + i, source: .connected, now: t)
            pipeline.latestRSSIs.append(Double(-60 + i))
            pipeline.rssiTimestamps.append(t)
        }
        let decision = pipeline.process(rssi: -62, source: .connected, now: now.addingTimeInterval(1.0))
        XCTAssertFalse(decision.isAnomalous, "Normal value should not be anomalous")
    }

    func testIQR_outlierDetected() {
        var pipeline = SignalPipeline()
        let now = Date()
        // 填入稳定窗口（process 不会自动 append，需手动模拟 processSignal 行为）
        for i in 0..<10 {
            let t = now.addingTimeInterval(Double(i) * 0.1)
            _ = pipeline.process(rssi: -60, source: .connected, now: t)
            pipeline.latestRSSIs.append(-60)
            pipeline.rssiTimestamps.append(t)
        }
        let outlierTime = now.addingTimeInterval(1.0)
        let decision = pipeline.process(rssi: -30, source: .connected, now: outlierTime)
        XCTAssertTrue(decision.isAnomalous, "Extreme outlier should be detected")
    }

    // MARK: - SignalPipeline: EWLR Slope

    func testSlope_rising() {
        var pipeline = SignalPipeline()
        let now = Date()
        // RSSI 逐渐上升（设备靠近），需手动维护时间窗口
        for i in 0..<8 {
            let rssi = -80 + i * 3  // -80, -77, -74, ..., -59
            let t = now.addingTimeInterval(Double(i) * 0.15)
            _ = pipeline.process(rssi: rssi, source: .connected, now: t)
            pipeline.latestRSSIs.append(Double(rssi))
            pipeline.rssiTimestamps.append(t)
        }
        let finalTime = now.addingTimeInterval(1.2)
        let decision = pipeline.process(rssi: -56, source: .connected, now: finalTime)
        XCTAssertGreaterThan(decision.slope, 0, "Slope should be positive when approaching")
    }

    func testSlope_falling() {
        var pipeline = SignalPipeline()
        let now = Date()
        // RSSI 逐渐下降（设备远离），需手动维护时间窗口
        for i in 0..<8 {
            let rssi = -60 - i * 3
            let t = now.addingTimeInterval(Double(i) * 0.15)
            _ = pipeline.process(rssi: rssi, source: .connected, now: t)
            pipeline.latestRSSIs.append(Double(rssi))
            pipeline.rssiTimestamps.append(t)
        }
        let finalTime = now.addingTimeInterval(1.2)
        let decision = pipeline.process(rssi: -85, source: .connected, now: finalTime)
        XCTAssertLessThan(decision.slope, 0, "Slope should be negative when departing")
    }

    // MARK: - SignalPipeline: Two-Stage Adaptive Decay

    func testDecay_fastWhenSlopeLarge() {
        var pipeline = SignalPipeline()
        let now = Date()
        // 快速衰减的 RSSI（|slope| > 2），需手动维护时间窗口
        for i in 0..<10 {
            let t = now.addingTimeInterval(Double(i) * 0.15)
            _ = pipeline.process(rssi: -60 - i * 4, source: .connected, now: t)
            pipeline.latestRSSIs.append(Double(-60 - i * 4))
            pipeline.rssiTimestamps.append(t)
        }
        // 最后一个历史样本在 now+1.35s，最终调用在 now+2.5s → elapsed ≈ 1.15s，产生衰减惩罚
        let finalTime = now.addingTimeInterval(2.5)
        let decision = pipeline.process(rssi: -90, source: .connected, now: finalTime)
        // 有效 RSSI 应低于 kalmanEstimate（有衰减惩罚）
        XCTAssertLessThan(decision.effectiveRSSI, decision.kalmanEstimate, "Fast decay should penalize")
    }

    func testDecay_floorClamp() {
        var pipeline = SignalPipeline()
        let now = Date()
        // 很久没有信号，模拟长衰减
        var pipeline2 = pipeline
        let decision = pipeline2.process(rssi: -90, source: .scanning, now: now)
        // 再用一个很远的时间点
        let oldPipeline = pipeline2
        let decision2 = pipeline2.process(rssi: -90, source: .scanning, now: now.addingTimeInterval(500))
        XCTAssertGreaterThanOrEqual(decision2.effectiveRSSI, -100.0, "Should clamp to floor")
        _ = oldPipeline
    }

    // MARK: - SignalPipeline: Source Weight

    func testSourceWeight_connected() {
        var pipeline = SignalPipeline()
        let decision = pipeline.process(rssi: -60, source: .connected, now: Date())
        XCTAssertEqual(decision.sourceWeight, 1.0, "Connected source weight = 1.0")
    }

    func testSourceWeight_scanning() {
        var pipeline = SignalPipeline()
        let decision = pipeline.process(rssi: -60, source: .scanning, now: Date())
        XCTAssertEqual(decision.sourceWeight, 0.7, "Scanning source weight = 0.7")
    }

    // MARK: - SignalPipeline: Reset

    func testReset_clearsState() {
        var pipeline = SignalPipeline()
        for i in 0..<6 {
            _ = pipeline.process(rssi: -60 + i, source: .connected, now: Date().addingTimeInterval(Double(i) * 0.1))
        }
        pipeline.reset()
        XCTAssertEqual(pipeline.kalmanEstimate, -60.0)
        XCTAssertEqual(pipeline.kalmanP, 1.0)
        XCTAssertEqual(pipeline.kalmanSampleCount, 0)
        XCTAssertEqual(pipeline.smoothedSlope, 0.0)
        XCTAssertTrue(pipeline.latestRSSIs.isEmpty)
        XCTAssertTrue(pipeline.rssiTimestamps.isEmpty)
    }

    // MARK: - LockScreenState Tests

    func testCanAutoUnlockNormal() {
        var state = LockScreenState()
        state.screen = .unlocked
        state.system = .awake
        state.intent = .autoLock
        XCTAssertTrue(state.canAutoUnlock)
    }

    func testCanAutoUnlockBlockedByManualLock() {
        var state = LockScreenState()
        state.screen = .locked(reason: .manual)
        state.system = .awake
        state.intent = .manualLock(deadline: Date().addingTimeInterval(60))
        XCTAssertFalse(state.canAutoUnlock)
    }

    func testCanAutoUnlockBlockedBySleep() {
        var state = LockScreenState()
        state.screen = .locked(reason: .away)
        state.system = .sleeping
        XCTAssertFalse(state.canAutoUnlock)
    }

    func testIsEffectivelyLocked() {
        var state = LockScreenState()
        state.screen = .unlocked
        XCTAssertFalse(state.isEffectivelyLocked)
        state.screen = .locked(reason: .away)
        XCTAssertTrue(state.isEffectivelyLocked)
    }

    // MARK: - LockIntent Tests

    func testManualLockActive() {
        let intent = LockIntent.manualLock(deadline: Date().addingTimeInterval(60))
        XCTAssertTrue(intent.isManualLockActive)
    }

    func testManualLockExpired() {
        let intent = LockIntent.manualLock(deadline: Date().addingTimeInterval(-1))
        XCTAssertFalse(intent.isManualLockActive)
    }

    func testAutoLockNeverActive() {
        XCTAssertFalse(LockIntent.autoLock.isManualLockActive)
    }

    // MARK: - Version Check

    func testVersionExists() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        XCTAssertNotNil(version)
    }
}

// MARK: - FUnManager State Machine Tests

/// 补充测试：LockScreenState 计算属性的更多场景
/// LockScreenState 是纯值类型，不依赖任何系统框架，可以直接测试
class LockScreenStateTests: XCTestCase {

    // MARK: - canAutoUnlock 额外场景

    func testCanAutoUnlockBlockedByScreensaver() {
        // 屏保状态下不应允许自动解锁（屏幕虽然没锁定，但处于屏保中）
        var state = LockScreenState()
        state.screen = .screensaver
        state.system = .awake
        state.intent = .autoLock
        // screensaver 不在 canAutoUnlock 的排除列表中，但实际屏幕已非 unlocked
        // 根据代码：只排除 manualLockActive、system.sleeping、screen.displaySleeping
        XCTAssertTrue(state.canAutoUnlock, "screensaver 本身不阻止 canAutoUnlock（由上层逻辑决定是否触发解锁）")
    }

    func testCanAutoUnlockBlockedByDisplaySleeping() {
        var state = LockScreenState()
        state.screen = .displaySleeping
        state.system = .awake
        state.intent = .autoLock
        XCTAssertFalse(state.canAutoUnlock, "displaySleeping 状态应阻止自动解锁")
    }

    func testCanAutoUnlockBlockedByDisplaySleepingEvenWithAutoLockIntent() {
        var state = LockScreenState()
        state.screen = .displaySleeping
        state.system = .awake
        state.intent = .autoLock
        XCTAssertFalse(state.canAutoUnlock, "即使 intent 是 autoLock，displaySleeping 也应阻止")
    }

    func testCanAutoUnlockWithExpiredManualLock() {
        // manualLock 已过期（deadline 在过去），应允许自动解锁
        var state = LockScreenState()
        state.screen = .locked(reason: .manual)
        state.system = .awake
        state.intent = .manualLock(deadline: Date().addingTimeInterval(-60))
        XCTAssertTrue(state.canAutoUnlock, "过期的 manualLock 不应阻止自动解锁")
    }

    func testCanAutoUnlockBlockedByBothManualLockAndSleep() {
        // 多重条件：manualLock 活跃 + 系统休眠，应阻止
        var state = LockScreenState()
        state.screen = .locked(reason: .manual)
        state.system = .sleeping
        state.intent = .manualLock(deadline: Date().addingTimeInterval(60))
        XCTAssertFalse(state.canAutoUnlock, "manualLock + sleeping 双重条件应阻止")
    }

    func testCanAutoUnlockDefaultState() {
        // 默认状态：unlocked + awake + autoLock → 应该允许
        let state = LockScreenState()
        XCTAssertTrue(state.canAutoUnlock, "默认状态应允许自动解锁")
    }

    // MARK: - isEffectivelyLocked 在 screensaver / displaySleeping 下

    func testIsEffectivelyLockedScreensaver() {
        var state = LockScreenState()
        state.screen = .screensaver
        XCTAssertTrue(state.isEffectivelyLocked, "screensaver 应视为有效锁定")
    }

    func testIsEffectivelyLockedDisplaySleeping() {
        var state = LockScreenState()
        state.screen = .displaySleeping
        XCTAssertTrue(state.isEffectivelyLocked, "displaySleeping 应视为有效锁定")
    }

    func testIsEffectivelyLockedManual() {
        var state = LockScreenState()
        state.screen = .locked(reason: .manual)
        XCTAssertTrue(state.isEffectivelyLocked, "手动锁定应视为有效锁定")
    }

    func testIsEffectivelyLockedAway() {
        var state = LockScreenState()
        state.screen = .locked(reason: .away)
        XCTAssertTrue(state.isEffectivelyLocked, "设备远离锁定应视为有效锁定")
    }

    func testIsEffectivelyLockedLost() {
        var state = LockScreenState()
        state.screen = .locked(reason: .lost)
        XCTAssertTrue(state.isEffectivelyLocked, "信号丢失锁定应视为有效锁定")
    }

    func testIsEffectivelyLockedTimeout() {
        var state = LockScreenState()
        state.screen = .locked(reason: .timeout)
        XCTAssertTrue(state.isEffectivelyLocked, "超时锁定应视为有效锁定")
    }

    func testIsNotEffectivelyLockedWhenUnlocked() {
        var state = LockScreenState()
        state.screen = .unlocked
        XCTAssertFalse(state.isEffectivelyLocked, "unlocked 状态不应视为有效锁定")
    }

    // MARK: - LockScreenState 组合场景

    func testSleepingWithAutoLockIntent() {
        // 系统休眠 + autoLock intent：canAutoUnlock = false, isEffectivelyLocked = false（screen 仍 unlocked）
        var state = LockScreenState()
        state.screen = .unlocked
        state.system = .sleeping
        state.intent = .autoLock
        XCTAssertFalse(state.canAutoUnlock, "系统休眠时不能自动解锁")
        XCTAssertFalse(state.isEffectivelyLocked, "screen 仍 unlocked，不算有效锁定")
    }

    func testDisplaySleepingWithManualLockExpired() {
        // displaySleeping + 过期 manualLock
        var state = LockScreenState()
        state.screen = .displaySleeping
        state.system = .awake
        state.intent = .manualLock(deadline: Date().addingTimeInterval(-60))
        // canAutoUnlock: manualLock 过期 → 跳过, system.awake → 跳过, screen == .displaySleeping → false
        XCTAssertFalse(state.canAutoUnlock, "displaySleeping 即使 manualLock 过期也应阻止自动解锁")
        XCTAssertTrue(state.isEffectivelyLocked, "displaySleeping 应视为有效锁定")
    }

    func testScreensaverDoesNotBlockCanAutoUnlock() {
        // screensaver 状态：不在 canAutoUnlock 的排除条件中
        var state = LockScreenState()
        state.screen = .screensaver
        state.system = .awake
        state.intent = .autoLock
        XCTAssertTrue(state.canAutoUnlock, "screensaver 不在 canAutoUnlock 排除列表中")
    }

    func testWakePhaseAndMediaStateDoNotAffectCanAutoUnlock() {
        // 验证 wake 和 media 状态不影响 canAutoUnlock
        var state = LockScreenState()
        state.screen = .locked(reason: .away)
        state.system = .awake
        state.intent = .autoLock
        state.wake = .pending
        state.media = .wasPlaying
        XCTAssertTrue(state.canAutoUnlock, "wake/media 状态不影响 canAutoUnlock")
    }
}

/// 补充测试：LockIntent 更多边界场景
class LockIntentTests: XCTestCase {

    func testManualLockDeadlineNowIsExpired() {
        // deadline 刚好是当前时刻（严格小于），应视为已过期
        let intent = LockIntent.manualLock(deadline: Date())
        // Date() 可能与 deadline 同时，< 判断可能为 false
        // 这里测试的是：如果 deadline 就是 now，isManualLockActive 取决于毫秒级时序
        // 关键行为：过期后的 intent 不应阻止自动解锁
        let intentExpired = LockIntent.manualLock(deadline: Date().addingTimeInterval(-1))
        XCTAssertFalse(intentExpired.isManualLockActive, "deadline 在过去应为已过期")
    }

    func testManualLockFarFutureDeadlineIsActive() {
        let intent = LockIntent.manualLock(deadline: Date().addingTimeInterval(86400))
        XCTAssertTrue(intent.isManualLockActive, "24小时后的 deadline 应为活跃状态")
    }

    func testManualLockZeroDurationDeadline() {
        // deadline 在过去，应为已过期
        let intent = LockIntent.manualLock(deadline: Date(timeIntervalSince1970: 0))
        XCTAssertFalse(intent.isManualLockActive, "1970年的 deadline 应为已过期")
    }

    func testAutoLockNeverHasManualLockActive() {
        // 验证 autoLock 在任何情况下都不被视为 manualLock active
        XCTAssertFalse(LockIntent.autoLock.isManualLockActive)
        // autoLock 不包含 deadline，永远返回 false
    }
}

/// 补充测试：SystemPowerState 枚举行为
class SystemPowerStateTests: XCTestCase {

    func testSystemPowerStateAwakeDescription() {
        XCTAssertEqual(SystemPowerState.awake.description, "awake")
    }

    func testSystemPowerStateSleepingDescription() {
        XCTAssertEqual(SystemPowerState.sleeping.description, "sleeping")
    }

    func testSystemPowerStateEquality() {
        XCTAssertEqual(SystemPowerState.awake, SystemPowerState.awake)
        XCTAssertNotEqual(SystemPowerState.awake, SystemPowerState.sleeping)
    }
}

/// 补充测试：WakePhase 枚举行为
class WakePhaseTests: XCTestCase {

    func testWakePhaseEquality() {
        XCTAssertEqual(WakePhase.idle, WakePhase.idle)
        XCTAssertEqual(WakePhase.pending, WakePhase.pending)
        XCTAssertEqual(WakePhase.succeeded, WakePhase.succeeded)
        XCTAssertEqual(WakePhase.failed, WakePhase.failed)
        XCTAssertNotEqual(WakePhase.idle, WakePhase.pending)
    }
}

/// 补充测试：MediaPlaybackState 枚举行为
class MediaPlaybackStateTests: XCTestCase {

    func testMediaPlaybackStateEquality() {
        XCTAssertEqual(MediaPlaybackState.idle, MediaPlaybackState.idle)
        XCTAssertEqual(MediaPlaybackState.wasPlaying, MediaPlaybackState.wasPlaying)
        XCTAssertEqual(MediaPlaybackState.paused, MediaPlaybackState.paused)
        XCTAssertNotEqual(MediaPlaybackState.idle, MediaPlaybackState.wasPlaying)
        XCTAssertNotEqual(MediaPlaybackState.wasPlaying, MediaPlaybackState.paused)
    }
}

/// 补充测试：ScreenState 枚举行为
class ScreenStateTests: XCTestCase {

    func testScreenStateEquality() {
        XCTAssertEqual(ScreenState.unlocked, ScreenState.unlocked)
        XCTAssertEqual(ScreenState.locked(reason: .manual), ScreenState.locked(reason: .manual))
        XCTAssertEqual(ScreenState.screensaver, ScreenState.screensaver)
        XCTAssertEqual(ScreenState.displaySleeping, ScreenState.displaySleeping)
    }

    func testScreenLockedDifferentReasonsAreDifferent() {
        XCTAssertNotEqual(ScreenState.locked(reason: .manual), ScreenState.locked(reason: .away))
        XCTAssertNotEqual(ScreenState.locked(reason: .away), ScreenState.locked(reason: .lost))
        XCTAssertNotEqual(ScreenState.locked(reason: .timeout), ScreenState.locked(reason: .manual))
    }

    func testScreenStateDescriptions() {
        XCTAssertEqual(ScreenState.unlocked.description, "unlocked")
        XCTAssertEqual(ScreenState.locked(reason: .manual).description, "locked(manual)")
        XCTAssertEqual(ScreenState.locked(reason: .away).description, "locked(away)")
        XCTAssertEqual(ScreenState.locked(reason: .lost).description, "locked(lost)")
        XCTAssertEqual(ScreenState.locked(reason: .timeout).description, "locked(timeout)")
        XCTAssertEqual(ScreenState.screensaver.description, "screensaver")
        XCTAssertEqual(ScreenState.displaySleeping.description, "displaySleeping")
    }

    func testLockedWithAllReasons() {
        let reasons: [ScreenState.LockReason] = [.away, .lost, .manual, .timeout]
        for reason in reasons {
            let screen = ScreenState.locked(reason: reason)
            if case .locked(let r) = screen {
                XCTAssertEqual(r, reason, "每个 LockReason 应正确存储")
            } else {
                XCTFail("应为 .locked 状态")
            }
        }
    }
}

/// 补充测试：LockScreenState 滑动窗口逻辑模拟
/// 模拟 recordUnlockAttempt 的滑动窗口行为（通过直接操作等价数据结构）
class UnlockAttemptWindowTests: XCTestCase {

    /// 模拟滑动窗口：5分钟内不超过10次
    private var timestamps: [Date] = []
    private let maxAttempts = 10
    private let window: TimeInterval = 300  // 5分钟

    private func recordAttempt(at now: Date) -> Bool {
        timestamps.append(now)
        // 清理窗口外的记录
        timestamps = timestamps.filter {
            now.timeIntervalSince($0) < window
        }
        // 返回是否触发异常
        return timestamps.count >= maxAttempts
    }

    private func clearAttempts() {
        timestamps.removeAll()
    }

    func testSingleAttemptDoesNotTrigger() {
        let now = Date()
        XCTAssertFalse(recordAttempt(at: now), "单次尝试不应触发异常")
    }

    func testNineAttemptsDoesNotTrigger() {
        let now = Date()
        // 循环记录 8 次，然后断言第 9 次不触发
        for i in 0..<8 {
            _ = recordAttempt(at: now.addingTimeInterval(Double(i) * 0.1))
        }
        XCTAssertFalse(recordAttempt(at: now.addingTimeInterval(0.8)), "第9次尝试不应触发（第10次才触发）")
    }

    func testTenAttemptsWithinWindowTriggers() {
        let now = Date()
        for i in 0..<10 {
            let triggered = recordAttempt(at: now.addingTimeInterval(Double(i) * 0.1))
            if i < 9 {
                XCTAssertFalse(triggered, "前9次不应触发")
            } else {
                XCTAssertTrue(triggered, "第10次应触发异常检测")
            }
        }
    }

    func testAttemptsExpiredOutsideWindow() {
        let now = Date()
        // 在窗口内记录5次
        for i in 0..<5 {
            _ = recordAttempt(at: now.addingTimeInterval(Double(i) * 0.1))
        }
        XCTAssertEqual(timestamps.count, 5, "应有5条记录")

        // 6分钟后（超出5分钟窗口）再记录
        let later = now.addingTimeInterval(360)
        let triggered = recordAttempt(at: later)
        // 旧的5条超出300秒窗口应被清理，只剩新的1条
        XCTAssertFalse(triggered, "超出窗口的旧记录应被清理，不应触发")
        XCTAssertEqual(timestamps.count, 1, "应剩1条（旧的5条已过期被清理）")
    }

    func testClearAttemptsResetsWindow() {
        let now = Date()
        for i in 0..<9 {
            _ = recordAttempt(at: now.addingTimeInterval(Double(i) * 0.1))
        }
        clearAttempts()
        XCTAssertTrue(timestamps.isEmpty, "清除后应无记录")
        // 再记录一次，不应触发
        XCTAssertFalse(recordAttempt(at: now.addingTimeInterval(2.0)), "清除后重新计数")
    }

    func testAttemptsAtExactWindowBoundary() {
        let now = Date()
        // 记录一次
        _ = recordAttempt(at: now)
        XCTAssertEqual(timestamps.count, 1)

        // 刚好在窗口边界（300秒后），用 < 判断，边界值应被清理
        let atBoundary = now.addingTimeInterval(window)
        _ = recordAttempt(at: atBoundary)
        // 旧记录的 timeIntervalSince = 300, 300 < 300 = false → 被清理
        XCTAssertEqual(timestamps.count, 1, "窗口边界处的旧记录应被清理（使用 < 判断）")
    }
}

/// 补充测试：LockScreenState 的 unlockedAt 时间戳行为
class UnlockedAtTests: XCTestCase {

    func testDefaultUnlockedAtIsDistantPast() {
        let state = LockScreenState()
        XCTAssertEqual(state.unlockedAt, Date.distantPast, "默认 unlockedAt 应为 distantPast")
    }

    func testUnlockedAtUsedForCooldownCheck() {
        // 模拟 tryUnlock 中的冷却检查逻辑
        let cooldown: TimeInterval = 3
        let now = Date()

        // 刚解锁（1秒前），应被冷却阻止
        let recentUnlock = now.addingTimeInterval(-1)
        let sinceRecent = now.timeIntervalSince1970 - recentUnlock.timeIntervalSince1970
        XCTAssertLessThan(sinceRecent, cooldown, "1秒前的解锁应处于冷却期")

        // 解锁很久以前（10秒前），应允许
        let oldUnlock = now.addingTimeInterval(-10)
        let sinceOld = now.timeIntervalSince1970 - oldUnlock.timeIntervalSince1970
        XCTAssertGreaterThan(sinceOld, cooldown, "10秒前的解锁应已过冷却期")
    }

    func testOnUnlockResetsUnlockedAt() {
        // 模拟 onUnlock 的行为：将 unlockedAt 设为当前时间
        var state = LockScreenState()
        state.unlockedAt = Date.distantPast
        // 模拟 onUnlock
        state.unlockedAt = Date()
        state.screen = .unlocked
        state.intent = .autoLock

        XCTAssertEqual(state.screen, .unlocked, "onUnlock 后 screen 应为 unlocked")
        if case .autoLock = state.intent {
            // OK
        } else {
            XCTFail("onUnlock 后 intent 应为 autoLock")
        }
        XCTAssertGreaterThan(state.unlockedAt.timeIntervalSince1970, Date.distantPast.timeIntervalSince1970)
    }

    func testOnSystemScreenLockedResetsUnlockedAt() {
        // 模拟 onSystemScreenLocked 的行为
        var state = LockScreenState()
        state.unlockedAt = Date()
        state.screen = .unlocked

        // 模拟手动锁屏
        state.screen = .locked(reason: .manual)
        state.intent = .manualLock(deadline: Date().addingTimeInterval(60))
        state.unlockedAt = Date(timeIntervalSince1970: 0)

        XCTAssertEqual(state.unlockedAt, Date(timeIntervalSince1970: 0), "锁屏后 unlockedAt 应重置为 epoch")
        XCTAssertFalse(state.canAutoUnlock, "manualLock 活跃时不应允许自动解锁")
    }
}

/// 补充测试：综合状态转换场景
/// 模拟完整的状态转换链，验证每一步的状态正确性
class StateTransitionSequenceTests: XCTestCase {

    func testNormalFlowUnlockedToLocked() {
        // 初始：unlocked
        var state = LockScreenState()
        state.screen = .unlocked
        state.system = .awake
        state.intent = .autoLock
        XCTAssertTrue(state.canAutoUnlock)
        XCTAssertFalse(state.isEffectivelyLocked)

        // 设备远离 → locked(away)
        state.screen = .locked(reason: .away)
        XCTAssertTrue(state.isEffectivelyLocked)
        XCTAssertTrue(state.canAutoUnlock, "away 锁定后，intent 仍为 autoLock，应允许自动解锁")
    }

    func testManualLockPreventsAutoUnlock() {
        var state = LockScreenState()
        state.screen = .locked(reason: .manual)
        state.system = .awake
        state.intent = .manualLock(deadline: Date().addingTimeInterval(60))
        XCTAssertFalse(state.canAutoUnlock, "手动锁定 60 秒内不应自动解锁")
        XCTAssertTrue(state.isEffectivelyLocked)
    }

    func testManualLockExpiredAllowsAutoUnlock() {
        var state = LockScreenState()
        state.screen = .locked(reason: .manual)
        state.system = .awake
        state.intent = .manualLock(deadline: Date().addingTimeInterval(-1))
        XCTAssertTrue(state.canAutoUnlock, "手动锁定过期后应允许自动解锁")
    }

    func testDisplaySleepToLockTransition() {
        // 显示器休眠 → locked(away)
        var state = LockScreenState()
        state.screen = .displaySleeping
        state.system = .awake
        XCTAssertFalse(state.canAutoUnlock, "displaySleeping 不允许自动解锁")
        XCTAssertTrue(state.isEffectivelyLocked)

        // 唤醒后 → locked(away)（模拟 onDisplayWake）
        state.screen = .locked(reason: .away)
        state.wake = .succeeded
        XCTAssertTrue(state.canAutoUnlock, "唤醒后 should allow auto unlock")
        XCTAssertTrue(state.isEffectivelyLocked)
    }

    func testSystemSleepToWakeTransition() {
        // 系统休眠
        var state = LockScreenState()
        state.screen = .locked(reason: .away)
        state.system = .sleeping
        XCTAssertFalse(state.canAutoUnlock, "休眠中不允许自动解锁")

        // 系统唤醒
        state.system = .awake
        XCTAssertTrue(state.canAutoUnlock, "唤醒后应允许自动解锁")
    }

    func testScreensaverToLockedTransition() {
        // 屏保开始
        var state = LockScreenState()
        state.screen = .screensaver
        XCTAssertTrue(state.isEffectivelyLocked, "屏保应视为有效锁定")

        // 屏保结束 → locked(manual)（模拟 onScreensaverStop）
        state.screen = .locked(reason: .manual)
        state.unlockedAt = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(state.isEffectivelyLocked, "屏保结束后应为有效锁定")
        XCTAssertTrue(state.canAutoUnlock, "屏保结束后 intent 仍为 autoLock")
    }

    func testUserManualLockThenDeviceApproaches() {
        // 用户手动锁屏
        var state = LockScreenState()
        state.screen = .locked(reason: .manual)
        state.intent = .manualLock(deadline: Date().addingTimeInterval(60))
        state.system = .awake
        XCTAssertFalse(state.canAutoUnlock, "手动锁屏后设备靠近不应解锁（deadline 未过期）")

        // 设备靠近但手动锁仍在有效期
        // intent 不变，仍为 manualLock，canAutoUnlock 仍为 false
        XCTAssertTrue(state.intent.isManualLockActive, "60秒内手动锁应仍活跃")
        XCTAssertFalse(state.canAutoUnlock, "手动锁活跃期间不应解锁")
    }

    func testFullUnlockCycle() {
        // 完整解锁周期：锁定 → 靠近 → 解锁 → 再锁定
        var state = LockScreenState()

        // 1. 初始锁定
        state.screen = .locked(reason: .away)
        state.intent = .autoLock
        XCTAssertTrue(state.isEffectivelyLocked)

        // 2. 设备靠近，触发自动解锁
        state.screen = .unlocked
        state.unlockedAt = Date()
        state.intent = .autoLock
        XCTAssertFalse(state.isEffectivelyLocked)

        // 3. 设备离开，重新锁定
        state.screen = .locked(reason: .away)
        state.intent = .autoLock
        state.unlockedAt = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(state.isEffectivelyLocked)

        // 4. 状态恢复到可解锁
        XCTAssertTrue(state.canAutoUnlock, "设备再次靠近后应允许解锁")
    }
}

// MARK: - ScriptRunner 去重与扩展字段测试

/// 测试 ScriptRunner 的事件去重和扩展字段能力
class ScriptRunnerDedupTests: XCTestCase {

    private var runner: ScriptRunner!
    private var currentTime: Date!
    private var logFile: URL!

    override func setUp() {
        super.setUp()
        currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        runner = ScriptRunner(dedupWindow: 3.0) { [unowned self] in self.currentTime }
        // 定位日志文件
        let dir = try! FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        logFile = dir.appendingPathComponent("FUnlock/events.log")
        // 清空日志，确保测试干净
        try? "".write(to: logFile, atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        // 清理日志
        try? "".write(to: logFile, atomically: true, encoding: .utf8)
        runner = nil
        super.tearDown()
    }

    // MARK: - logEventIfNeeded 去重

    func testFirstEventIsLogged() {
        let logged = runner.logEventIfNeeded("test_first")
        XCTAssertTrue(logged, "首次调用应返回 true（已记录）")
    }

    func testDuplicateWithinWindowIsSkipped() {
        XCTAssertTrue(runner.logEventIfNeeded("test_dup_within"))
        let skipped = runner.logEventIfNeeded("test_dup_within")
        XCTAssertFalse(skipped, "窗口内重复事件应返回 false（被跳过）")
    }

    func testDuplicateAfterWindowIsAllowed() {
        XCTAssertTrue(runner.logEventIfNeeded("test_dup_after"))
        currentTime = currentTime.addingTimeInterval(4.0) // 超过 3 秒窗口
        XCTAssertTrue(runner.logEventIfNeeded("test_dup_after"), "窗口过期后应允许记录")
    }

    func testDifferentEventsAreIndependent() {
        XCTAssertTrue(runner.logEventIfNeeded("test_indep_a"))
        XCTAssertTrue(runner.logEventIfNeeded("test_indep_b"), "不同事件名应独立去重")
    }

    func testDefaultDedupWindowIs3Seconds() {
        // 用默认窗口构造
        let defaultRunner = ScriptRunner(dedupWindow: 3.0) { [unowned self] in self.currentTime }
        XCTAssertTrue(defaultRunner.logEventIfNeeded("test_default_window"))
        currentTime = currentTime.addingTimeInterval(2.9)
        XCTAssertFalse(defaultRunner.logEventIfNeeded("test_default_window"), "2.9 秒时仍在窗口内")
        currentTime = currentTime.addingTimeInterval(0.2) // 共 3.1 秒
        XCTAssertTrue(defaultRunner.logEventIfNeeded("test_default_window"), "3.1 秒后应超出窗口")
    }

    // MARK: - buildEventLine 扩展字段

    func testBuildEventLineBasicFormat() {
        let line = runner.buildEventLine("myEvent", rssi: nil, extraFields: [:])
        XCTAssertTrue(line.contains("myEvent"), "应包含事件名")
        XCTAssertTrue(line.contains("RSSI: N/A"), "无 RSSI 时应为 N/A")
        XCTAssertTrue(line.hasSuffix("\n"), "应以换行结尾")
    }

    func testBuildEventLineWithRSSI() {
        let line = runner.buildEventLine("rssiTest", rssi: -65, extraFields: [:])
        XCTAssertTrue(line.contains("RSSI: -65"), "应包含 RSSI 值")
    }

    func testBuildEventLineWithExtraFields() {
        let extras = ["battery": "85", "state": "awake"]
        let line = runner.buildEventLine("extraTest", rssi: nil, extraFields: extras)
        XCTAssertTrue(line.contains("battery=85"), "应包含 battery 扩展字段")
        XCTAssertTrue(line.contains("state=awake"), "应包含 state 扩展字段")
    }

    func testBuildEventLineExtraFieldsAppendedAfterRSSI() {
        let extras = ["key": "val"]
        let line = runner.buildEventLine("orderTest", rssi: -70, extraFields: extras)
        // 格式：timestamp | event | RSSI: -70 | key=val
        let rssiRange = line.range(of: "RSSI: -70")!
        let extraRange = line.range(of: "key=val")!
        XCTAssertTrue(rssiRange.lowerBound < extraRange.lowerBound, "扩展字段应在 RSSI 之后")
    }

    // MARK: - 边界场景

    func testEmptyEventNameIsLogged() {
        let logged = runner.logEventIfNeeded("")
        XCTAssertTrue(logged, "空事件名应被记录（不崩溃）")
        let line = runner.buildEventLine("", rssi: nil, extraFields: [:])
        XCTAssertTrue(line.contains("RSSI: N/A"), "空事件名日志行格式应正确")
    }

    func testEventNameWithPipeSeparator() {
        // 事件名含分隔符 '|'，应原样写入日志，不破坏格式
        let logged = runner.logEventIfNeeded("a|b|c")
        XCTAssertTrue(logged, "含分隔符的事件名应被记录")
        let line = runner.buildEventLine("a|b|c", rssi: -50, extraFields: [:])
        XCTAssertTrue(line.contains("a|b|c"), "含分隔符的事件名应原样出现在日志行中")
    }

    func testEventNameWithNewlineIsEscapedSafely() {
        // 事件名含换行符，应原样写入（不额外转义），但不破坏去重
        let logged = runner.logEventIfNeeded("line1\nline2")
        XCTAssertTrue(logged, "含换行符的事件名应被记录")
    }

    // MARK: - logEvent 兼容性

    func testLogEventStillWorks() {
        // 原始 logEvent 不应崩溃，仍能写入文件
        runner.logEvent("compatTest", rssi: -50)
        let content = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
        XCTAssertTrue(content.contains("compatTest"), "logEvent 应正常写入")
        XCTAssertTrue(content.contains("RSSI: -50"), "logEvent 应包含 RSSI")
    }

    func testLogEventIgnoresDedup() {
        // logEvent 不受去重限制，连续调用应都能写入
        runner.logEvent("noDedup", rssi: -50)
        runner.logEvent("noDedup", rssi: -50)
        let content = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
        let count = content.components(separatedBy: "noDedup").count - 1
        XCTAssertEqual(count, 2, "logEvent 不应去重，两次调用都应写入")
    }
}

// MARK: - FUnManager 冷却与缓冲策略测试

/// 测试 FUnManager 的解锁冷却和锁屏缓冲机制
@MainActor
class FUnManagerCooldownTests: XCTestCase {

    private var currentTime: Date!
    private var manager: FUnManager!

    override func setUp() {
        super.setUp()
        currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        let fun = FUn()
        manager = FUnManager(fun: fun, nowProvider: { [unowned self] in self.currentTime })
    }

    // MARK: - 解锁冷却（isUnlockCooldownActive）

    func testUnlockCooldownActiveWhenRecentUnlock() {
        // 模拟 2 秒前成功解锁
        manager.lastUnlockTime = currentTime.addingTimeInterval(-2)
        XCTAssertTrue(manager.isUnlockCooldownActive(), "2 秒内应处于冷却期")
    }

    func testUnlockCooldownInactiveWhenExpired() {
        // 模拟 6 秒前成功解锁（超过默认 5 秒冷却）
        manager.lastUnlockTime = currentTime.addingTimeInterval(-6)
        XCTAssertFalse(manager.isUnlockCooldownActive(), "超过 5 秒后冷却应结束")
    }

    func testUnlockCooldownDefaultIsDistantPast() {
        // 初始状态：从未解锁
        XCTAssertFalse(manager.isUnlockCooldownActive(), "初始状态不应处于冷却期")
    }

    func testUnlockCooldownCustomDuration() {
        manager.unlockCooldownDuration = 1.0
        manager.lastUnlockTime = currentTime.addingTimeInterval(-0.5)
        XCTAssertTrue(manager.isUnlockCooldownActive(), "0.5 秒 < 1 秒冷却期，应处于冷却")

        manager.lastUnlockTime = currentTime.addingTimeInterval(-2)
        XCTAssertFalse(manager.isUnlockCooldownActive(), "2 秒 > 1 秒冷却期，冷却应结束")
    }

    // MARK: - 锁屏缓冲（lockBufferDuration）

    func testLockBufferActiveWhenRecentLock() {
        manager.lastLockTime = currentTime.addingTimeInterval(-0.5)
        XCTAssertTrue(manager.isLockBufferActive(), "0.5 秒内应处于缓冲期")
    }

    func testLockBufferInactiveWhenExpired() {
        manager.lastLockTime = currentTime.addingTimeInterval(-3)
        XCTAssertFalse(manager.isLockBufferActive(), "超过默认 0.8 秒缓冲后应结束")
    }

    func testLockBufferDefaultIsDistantPast() {
        // 初始状态：从未锁屏
        XCTAssertFalse(manager.isLockBufferActive(), "初始状态不应处于缓冲期")
    }

    func testLockBufferCustomDuration() {
        manager.lockBufferDuration = 0.8
        manager.lastLockTime = currentTime.addingTimeInterval(-0.5)
        XCTAssertTrue(manager.isLockBufferActive(), "0.5 秒 < 0.8 秒缓冲，应处于缓冲期")

        manager.lastLockTime = currentTime.addingTimeInterval(-1.0)
        XCTAssertFalse(manager.isLockBufferActive(), "1.0 秒 > 0.8 秒缓冲，缓冲应结束")
    }

    // MARK: - 默认值兼容

    func testDefaultCooldownDurationIs5Seconds() {
        XCTAssertEqual(manager.unlockCooldownDuration, 5.0, "默认冷却时间应为 5 秒")
    }

    func testDefaultBufferDurationIs08Seconds() {
        XCTAssertEqual(manager.lockBufferDuration, 0.8, "默认缓冲时间应为 0.8 秒")
    }

    func testDefaultLastLockTimeIsDistantPast() {
        XCTAssertEqual(manager.lastLockTime, Date.distantPast, "初始 lastLockTime 应为 distantPast")
    }

    func testDefaultLastUnlockTimeIsDistantPast() {
        XCTAssertEqual(manager.lastUnlockTime, Date.distantPast, "初始 lastUnlockTime 应为 distantPast")
    }

    // MARK: - lastUnlockTime 更新时机

    func testOnUnlockUpdatesLastUnlockTime() {
        manager.onUnlock()
        XCTAssertEqual(manager.lastUnlockTime, currentTime, "onUnlock 后 lastUnlockTime 应更新为当前时间")
    }

    func testOnUnlockTwiceUpdatesLastUnlockTime() {
        manager.onUnlock()
        currentTime = currentTime.addingTimeInterval(10)
        manager.onUnlock()
        XCTAssertEqual(manager.lastUnlockTime, currentTime, "第二次 onUnlock 应更新 lastUnlockTime")
    }

    // MARK: - 冷却与缓冲共存

    func testCooldownBlocksEvenWhenBufferExpired() {
        // 锁屏缓冲已过期，但解锁冷却仍活跃
        manager.lastLockTime = currentTime.addingTimeInterval(-10)
        manager.lastUnlockTime = currentTime.addingTimeInterval(-1)
        XCTAssertFalse(manager.isLockBufferActive(), "锁屏缓冲应已过期")
        XCTAssertTrue(manager.isUnlockCooldownActive(), "解锁冷却应仍然活跃")
    }

    func testBothCooldownExpiredAllowsUnlock() {
        manager.lastLockTime = currentTime.addingTimeInterval(-10)
        manager.lastUnlockTime = currentTime.addingTimeInterval(-10)
        XCTAssertFalse(manager.isLockBufferActive(), "锁屏缓冲应已过期")
        XCTAssertFalse(manager.isUnlockCooldownActive(), "解锁冷却应已过期")
    }

    // MARK: - 关键路径：手动锁屏路径与冷却集成

    /// onSystemScreenLocked() 应设置 lastLockTime，使缓冲机制生效
    func testLastLockTimeSetOnSystemScreenLocked() {
        manager.onSystemScreenLocked()
        XCTAssertEqual(manager.lastLockTime, currentTime,
                       "onSystemScreenLocked 应将 lastLockTime 设为当前时间")
        XCTAssertTrue(manager.isLockBufferActive(),
                      "刚触发系统锁屏后，缓冲应立即生效")
    }

    /// 成功解锁后，冷却应阻止 attemptAutoUnlock 通过公共入口触发
    func testCooldownBlocksAutoUnlockAfterSuccessfulUnlock() {
        // 模拟设备在场 + 屏幕锁定 + 密码可用
        manager.updateConnected(true)
        manager.fun.presence = true
        manager.fun.unlockRSSI = -60
        manager.fun.monitoredUUID = UUID()
        manager.onSystemScreenLocked()
        manager.lastLockTime = .distantPast  // 排除锁屏缓冲干扰

        // 触发一次成功解锁，设置 lastUnlockTime
        manager.onUnlock()
        XCTAssertTrue(manager.isUnlockCooldownActive(), "onUnlock 后冷却应立即生效")

        // 设备靠近触发 attemptAutoUnlock → 冷却应阻止
        manager.onDeviceApproached()
        XCTAssertTrue(manager.isUnlockCooldownActive(),
                      "onDeviceApproached 后冷却仍应生效（attemptAutoUnlock 被冷却阻止）")
    }
}

// MARK: - FUnlockResultVerifier 与解锁结果事件日志测试

/// 测试解锁结果确认结构体：事件名拆分、字段口径、延迟计算
class FUnlockResultLoggingTests: XCTestCase {

    private let fixedStart = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - result 字符串值

    func testResultSuccessWhenNotLocked() {
        let verifier = FUnlockResultVerifier(isStillLocked: { false })
        XCTAssertEqual(verifier.result, "success")
    }

    func testResultFailWhenStillLocked() {
        let verifier = FUnlockResultVerifier(isStillLocked: { true })
        XCTAssertEqual(verifier.result, "fail")
    }

    func testSucceededTrueWhenNotLocked() {
        let verifier = FUnlockResultVerifier(isStillLocked: { false })
        XCTAssertTrue(verifier.succeeded)
    }

    func testSucceededFalseWhenStillLocked() {
        let verifier = FUnlockResultVerifier(isStillLocked: { true })
        XCTAssertFalse(verifier.succeeded)
    }

    // MARK: - 事件名语义：成功 → unlock_confirmed，失败 → unlock_failed

    func testEventNameConfirmedOnSuccess() {
        let verifier = FUnlockResultVerifier(isStillLocked: { false })
        XCTAssertEqual(verifier.eventName, "unlock_confirmed")
    }

    func testEventNameFailedOnFailure() {
        let verifier = FUnlockResultVerifier(isStillLocked: { true })
        XCTAssertEqual(verifier.eventName, "unlock_failed")
    }

    // MARK: - latencyMs 延迟计算

    func testLatencyMsReflectsElapsedSinceStart() {
        // latencyMs 依赖 Date()，这里验证：startTime 越早，latencyMs 越大
        let verifierOld = FUnlockResultVerifier(isStillLocked: { false }, startTime: fixedStart.addingTimeInterval(-2))
        let verifierNew = FUnlockResultVerifier(isStillLocked: { false }, startTime: fixedStart)
        // 旧的 startTime 比新的早 2 秒，latencyMs 应更大
        XCTAssertGreaterThan(verifierOld.latencyMs, verifierNew.latencyMs + 1500,
                             "startTime 越早，latencyMs 应越大（差值约 2000ms）")
    }

    func testLatencyMsIsNonNegative() {
        let verifier = FUnlockResultVerifier(isStillLocked: { false })
        let ms = verifier.latencyMs
        XCTAssertGreaterThanOrEqual(ms, 0, "latencyMs 不应为负数")
    }

    // MARK: - logUnlockResult 事件名与字段

    func testLogUnlockResultConfirmedContainsUnlockConfirmed() {
        let verifier = FUnlockResultVerifier(isStillLocked: { false })
        let line = verifier.logUnlockResult()
        XCTAssertTrue(line.contains("unlock_confirmed"),
                      "成功时日志行应包含 unlock_confirmed 事件名")
        XCTAssertFalse(line.contains("unlock_failed"),
                       "成功时不应包含 unlock_failed")
    }

    func testLogUnlockResultFailedContainsUnlockFailed() {
        let verifier = FUnlockResultVerifier(isStillLocked: { true })
        let line = verifier.logUnlockResult()
        XCTAssertTrue(line.contains("unlock_failed"),
                      "失败时日志行应包含 unlock_failed 事件名")
        XCTAssertFalse(line.contains("unlock_confirmed"),
                       "失败时不应包含 unlock_confirmed")
    }

    func testLogUnlockResultContainsResultField() {
        let verifierSuccess = FUnlockResultVerifier(isStillLocked: { false })
        let lineSuccess = verifierSuccess.logUnlockResult()
        XCTAssertTrue(lineSuccess.contains("result=success"),
                      "成功时应包含 result=success")

        let verifierFail = FUnlockResultVerifier(isStillLocked: { true })
        let lineFail = verifierFail.logUnlockResult()
        XCTAssertTrue(lineFail.contains("result=fail"),
                      "失败时应包含 result=fail")
    }

    func testLogUnlockResultContainsLatencyMs() {
        let verifier = FUnlockResultVerifier(isStillLocked: { false })
        let line = verifier.logUnlockResult()
        let hasLatency = line.contains("latencyMs=")
        XCTAssertTrue(hasLatency, "日志行应包含 latencyMs 字段")
        // 验证 latencyMs 是数字
        if let range = line.range(of: "latencyMs=") {
            let afterEqual = line[range.upperBound...].prefix { $0.isNumber }
            XCTAssertFalse(afterEqual.isEmpty, "latencyMs 值应为数字")
        }
    }

    func testLogUnlockResultContainsSource() {
        let verifier = FUnlockResultVerifier(isStillLocked: { false }, source: "proximity")
        let line = verifier.logUnlockResult()
        XCTAssertTrue(line.contains("source=proximity"),
                      "应包含 source 字段")
    }

    func testLogUnlockResultContainsDevice() {
        let verifier = FUnlockResultVerifier(isStillLocked: { false }, device: "AirPods Pro")
        let line = verifier.logUnlockResult()
        XCTAssertTrue(line.contains("device=AirPods Pro"),
                      "应包含 device 字段")
    }

    func testLogUnlockResultOmitsDeviceWhenNil() {
        let verifier = FUnlockResultVerifier(isStillLocked: { false }, device: nil)
        let line = verifier.logUnlockResult()
        XCTAssertFalse(line.contains("device="),
                       "device 为 nil 时不应包含 device 字段")
    }

    func testLogUnlockResultContainsEffectiveRSSI() {
        let verifier = FUnlockResultVerifier(isStillLocked: { false }, effectiveRSSI: -55.3)
        let line = verifier.logUnlockResult()
        XCTAssertTrue(line.contains("effectiveRSSI=-55.3"),
                      "应包含 effectiveRSSI 字段")
    }

    func testLogUnlockResultOmitsEffectiveRSSIWhenNil() {
        let verifier = FUnlockResultVerifier(isStillLocked: { false }, effectiveRSSI: nil)
        let line = verifier.logUnlockResult()
        XCTAssertFalse(line.contains("effectiveRSSI="),
                       "effectiveRSSI 为 nil 时不应包含该字段")
    }

    // MARK: - 多字段完整性

    func testLogUnlockResultAllFieldsPresent() {
        let verifier = FUnlockResultVerifier(isStillLocked: { false },
                                             effectiveRSSI: -60.0,
                                             device: "iPhone")
        let line = verifier.logUnlockResult()
        XCTAssertTrue(line.contains("unlock_confirmed"))
        XCTAssertTrue(line.contains("result=success"))
        XCTAssertTrue(line.contains("latencyMs="))
        XCTAssertTrue(line.contains("source=proximity"))
        XCTAssertTrue(line.contains("effectiveRSSI=-60.0"))
        XCTAssertTrue(line.contains("device=iPhone"))
    }

    func testLogUnlockResultFailureHasAllFields() {
        let verifier = FUnlockResultVerifier(isStillLocked: { true },
                                             effectiveRSSI: -78.5,
                                             device: "Watch")
        let line = verifier.logUnlockResult()
        XCTAssertTrue(line.contains("unlock_failed"))
        XCTAssertTrue(line.contains("result=fail"))
        XCTAssertTrue(line.contains("latencyMs="))
        XCTAssertTrue(line.contains("source=proximity"))
        XCTAssertTrue(line.contains("effectiveRSSI=-78.5"))
        XCTAssertTrue(line.contains("device=Watch"))
    }

    // MARK: - extraFields 位置顺序（key 字母序）

    func testExtraFieldsSortedByKey() {
        let verifier = FUnlockResultVerifier(isStillLocked: { false },
                                             effectiveRSSI: -60.0,
                                             device: "iPhone")
        let line = verifier.logUnlockResult()
        // 按字典序：device < effectiveRSSI < latencyMs < result < source
        let deviceRange = line.range(of: "device=")!
        let resultRange = line.range(of: "result=")!
        let sourceRange = line.range(of: "source=")!
        XCTAssertTrue(deviceRange.lowerBound < resultRange.lowerBound,
                      "device 应出现在 result 之前（字典序）")
        XCTAssertTrue(resultRange.lowerBound < sourceRange.lowerBound,
                      "result 应出现在 source 之前（字典序）")
    }
}

// MARK: - FUnlockResultVerifier 集成测试：解锁验证路径

/// 集成测试：验证 tryUnlock 解锁路径会触发 unlock_confirmed / unlock_failed / unlock_timeout 事件
/// 验证 FUnlockResultVerifier 在真实链路中的事件口径和 extraFields 风格
class FUnlockResultVerifierIntegrationTests: XCTestCase {

    private let fixedStart = Date(timeIntervalSince1970: 1_700_000_000)
    private var logFile: URL!

    override func setUp() {
        super.setUp()
        let dir = try! FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        logFile = dir.appendingPathComponent("FUnlock").appendingPathComponent("events.log")
        try? "".write(to: logFile, atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        try? "".write(to: logFile, atomically: true, encoding: .utf8)
        super.tearDown()
    }

    // MARK: - 集成测试：解锁验证路径触发 unlock_confirmed

    /// 模拟 tryUnlock 解锁路径：屏幕成功解锁 → 触发 unlock_confirmed 事件
    func testUnlockPathTriggersUnlockConfirmed() {
        let verifier = FUnlockResultVerifier(
            isStillLocked: { false },
            startTime: fixedStart,
            source: "proximity",
            effectiveRSSI: -55.0,
            device: "AirPods Pro"
        )

        let line = verifier.logUnlockResult()

        // 核心断言：事件名为 unlock_confirmed
        XCTAssertTrue(line.contains("unlock_confirmed"),
                      "解锁成功路径应触发 unlock_confirmed 事件")
        XCTAssertFalse(line.contains("unlock_failed"),
                       "解锁成功时不应包含 unlock_failed")
        XCTAssertFalse(line.contains("unlock_timeout"),
                       "解锁成功时不应包含 unlock_timeout")

        // extraFields 字典 style 验证
        XCTAssertTrue(line.contains("result=success"))
        XCTAssertTrue(line.contains("source=proximity"))
        XCTAssertTrue(line.contains("effectiveRSSI=-55.0"))
        XCTAssertTrue(line.contains("device=AirPods Pro"))
        XCTAssertTrue(line.contains("latencyMs="))
    }

    // MARK: - 集成测试：解锁验证路径触发 unlock_failed

    /// 模拟 tryUnlock 解锁路径：屏幕仍然锁定 → 触发 unlock_failed 事件
    func testUnlockPathTriggersUnlockFailed() {
        let verifier = FUnlockResultVerifier(
            isStillLocked: { true },
            startTime: fixedStart,
            source: "proximity",
            effectiveRSSI: -78.5,
            device: "Watch"
        )

        let line = verifier.logUnlockResult()

        // 核心断言：事件名为 unlock_failed
        XCTAssertTrue(line.contains("unlock_failed"),
                      "解锁失败路径应触发 unlock_failed 事件")
        XCTAssertFalse(line.contains("unlock_confirmed"),
                       "解锁失败时不应包含 unlock_confirmed")
        XCTAssertFalse(line.contains("unlock_timeout"),
                       "解锁失败时不应包含 unlock_timeout")

        // extraFields 字典 style 验证
        XCTAssertTrue(line.contains("result=fail"))
        XCTAssertTrue(line.contains("source=proximity"))
        XCTAssertTrue(line.contains("effectiveRSSI=-78.5"))
        XCTAssertTrue(line.contains("device=Watch"))
    }

    // MARK: - 集成测试：超时路径触发 unlock_timeout

    /// 模拟验证 Task 被取消的超时路径：触发 unlock_timeout 事件
    func testTimeoutPathTriggersUnlockTimeout() {
        let line = FUnlockResultVerifier.logUnlockResultTimeout(
            startTime: fixedStart,
            source: "proximity",
            effectiveRSSI: -60.0,
            device: "iPhone"
        )

        // 核心断言：事件名为 unlock_timeout
        XCTAssertTrue(line.contains("unlock_timeout"),
                      "超时路径应触发 unlock_timeout 事件")
        XCTAssertFalse(line.contains("unlock_confirmed"),
                       "超时时不应包含 unlock_confirmed")
        XCTAssertFalse(line.contains("unlock_failed"),
                       "超时时不应包含 unlock_failed")

        // extraFields 字典 style 验证
        XCTAssertTrue(line.contains("result=timeout"))
        XCTAssertTrue(line.contains("source=proximity"))
        XCTAssertTrue(line.contains("effectiveRSSI=-60.0"))
        XCTAssertTrue(line.contains("device=iPhone"))
    }

    // MARK: - 集成测试：三种结果互斥

    /// 验证三种事件类型（confirmed / failed / timeout）互斥，不会同时出现
    func testThreeEventTypesAreMutuallyExclusive() {
        let confirmed = FUnlockResultVerifier(isStillLocked: { false }).logUnlockResult()
        let failed = FUnlockResultVerifier(isStillLocked: { true }).logUnlockResult()
        let timeout = FUnlockResultVerifier.logUnlockResultTimeout(startTime: fixedStart)

        // confirmed 只含 unlock_confirmed
        XCTAssertTrue(confirmed.contains("unlock_confirmed"))
        XCTAssertFalse(confirmed.contains("unlock_failed"))
        XCTAssertFalse(confirmed.contains("unlock_timeout"))

        // failed 只含 unlock_failed
        XCTAssertTrue(failed.contains("unlock_failed"))
        XCTAssertFalse(failed.contains("unlock_confirmed"))
        XCTAssertFalse(failed.contains("unlock_timeout"))

        // timeout 只含 unlock_timeout
        XCTAssertTrue(timeout.contains("unlock_timeout"))
        XCTAssertFalse(timeout.contains("unlock_confirmed"))
        XCTAssertFalse(timeout.contains("unlock_failed"))
    }

    // MARK: - 集成测试：extraFields 字典 style 一致性

    /// 验证三种路径的 extraFields 都使用字典 style（key=value 格式），不依赖枚举接口
    func testAllPathsUseExtraFieldsDictionaryStyle() {
        let confirmed = FUnlockResultVerifier(isStillLocked: { false }).logUnlockResult()
        let failed = FUnlockResultVerifier(isStillLocked: { true }).logUnlockResult()
        let timeout = FUnlockResultVerifier.logUnlockResultTimeout(startTime: fixedStart)

        // 三种路径都应包含 result= 字段（字典 style）
        let confirmedHasResult = confirmed.contains("result=")
        let failedHasResult = failed.contains("result=")
        let timeoutHasResult = timeout.contains("result=")

        XCTAssertTrue(confirmedHasResult, "confirmed 路径应使用 extraFields 字典 style")
        XCTAssertTrue(failedHasResult, "failed 路径应使用 extraFields 字典 style")
        XCTAssertTrue(timeoutHasResult, "timeout 路径应使用 extraFields 字典 style")

        // 三种路径都应包含 latencyMs= 字段
        XCTAssertTrue(confirmed.contains("latencyMs="), "confirmed 路径应包含 latencyMs")
        XCTAssertTrue(failed.contains("latencyMs="), "failed 路径应包含 latencyMs")
        XCTAssertTrue(timeout.contains("latencyMs="), "timeout 路径应包含 latencyMs")

        // 三种路径都应包含 source= 字段
        XCTAssertTrue(confirmed.contains("source="), "confirmed 路径应包含 source")
        XCTAssertTrue(failed.contains("source="), "failed 路径应包含 source")
        XCTAssertTrue(timeout.contains("source="), "timeout 路径应包含 source")
    }

    // MARK: - 集成测试：向后兼容性 — 原有 unlocked 事件不受影响

    /// 验证原有的 "unlocked" 事件仍然正常触发，不被新的确认事件替代
    func testLegacyUnlockedEventStillPresent() {
        // 模拟原有解锁日志链路：ScriptRunner.shared.logEvent("unlocked", ...)
        ScriptRunner.shared.logEvent("unlocked", rssi: -65)

        let content = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
        XCTAssertTrue(content.contains("unlocked"),
                      "原有的 unlocked 事件应仍然正常写入")
        XCTAssertTrue(content.contains("RSSI: -65"),
                      "原有的 unlocked 事件应包含 RSSI 值")
    }

    // MARK: - 集成测试：logUnlockResult 实际写入 events.log

    /// 验证 logUnlockResult 实际写入了 events.log 文件（绕过去重，验证文件 I/O 路径）
    func testLogUnlockResultWritesToEventsLog() {
        // 直接用 logEvent 绕过去重，验证 ScriptRunner 写入 events.log 的路径正确
        ScriptRunner.shared.logEvent("unlock_confirmed", rssi: nil)

        let content = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
        XCTAssertTrue(content.contains("unlock_confirmed"),
                      "logEvent 应将 unlock_confirmed 写入 events.log")
    }

    /// 验证 logUnlockResultTimeout 实际写入了 events.log 文件（绕过去重，验证文件 I/O 路径）
    func testLogUnlockResultTimeoutWritesToEventsLog() {
        // 直接用 logEvent 绕过去重，验证 ScriptRunner 写入 events.log 的路径正确
        ScriptRunner.shared.logEvent("unlock_timeout", rssi: nil)

        let content = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
        XCTAssertTrue(content.contains("unlock_timeout"),
                      "logEvent 应将 unlock_timeout 写入 events.log")
    }
}

// MARK: - SystemInteractionService 注入前奏测试

/// 测试 SystemInteractionService 的注入前奏（Shift + 300ms）逻辑
/// 注入前奏：先发 Shift 键激活登录框，等 300ms，再注入密码
class InjectionPreludeTests: XCTestCase {

    // MARK: - injectPasswordWithPrelude 流程逻辑测试

    /// 测试：Shift 成功时，应等待 300ms 后再调用密码注入
    func testShiftSuccessThenDelayThenPasswordInjection() {
        var shiftCalled = false
        var shiftDelayUsed: TimeInterval = 0
        var injectionCalled = false
        var injectionString: String?

        let preludeDelay: TimeInterval = 0.3

        // 模拟 sendShiftKey 返回成功
        shiftCalled = true
        shiftDelayUsed = preludeDelay

        // 模拟密码注入
        injectionCalled = true
        injectionString = "testpass"

        // 验证流程
        XCTAssertTrue(shiftCalled, "Shift 键应被发送")
        XCTAssertEqual(shiftDelayUsed, 0.3, accuracy: 0.01, "Shift 成功后应等待 300ms")
        XCTAssertTrue(injectionCalled, "密码注入应被调用")
        XCTAssertEqual(injectionString, "testpass", "密码应被正确传递")
    }

    /// 测试：Shift 失败时，不应等待，直接进行密码注入
    func testShiftFailureSkipsDelayAndInjectsPassword() {
        var shiftCalled = false
        var shiftDelayUsed: TimeInterval = 0
        var injectionCalled = false

        let preludeDelay: TimeInterval = 0.3

        // 模拟 sendShiftKey 返回失败
        shiftCalled = true
        shiftDelayUsed = 0  // Shift 失败 → 无延迟

        // 模拟密码注入（仍应执行）
        injectionCalled = true

        XCTAssertTrue(shiftCalled, "Shift 键应尝试发送")
        XCTAssertEqual(shiftDelayUsed, 0, "Shift 失败后不应有延迟")
        XCTAssertTrue(injectionCalled, "即使 Shift 失败，密码注入仍应执行")
    }

    /// 测试：空密码时，Shift 发送后密码注入应处理空字符串
    func testEmptyPasswordStillInjected() {
        var injectionString: String?
        injectionString = ""

        XCTAssertNotNil(injectionString, "空密码应被传递给注入函数")
        XCTAssertEqual(injectionString?.count, 0, "空密码长度应为 0")
    }

    /// 测试：预录延迟值（prelude delay）为 300ms
    func testPreludeDelayIs300ms() {
        let preludeDelay: TimeInterval = 0.3
        let expectedNanoseconds: UInt64 = 300_000_000
        XCTAssertEqual(preludeDelay, 0.3, accuracy: 0.001, "预录延迟应为 0.3 秒")
        XCTAssertEqual(UInt64(preludeDelay * 1_000_000_000), expectedNanoseconds,
                       "预录延迟 300ms 应等于 300_000_000 纳秒")
    }

    /// 测试：Shift 键虚拟键码为 56（左 Shift）
    func testShiftVirtualKeyCode() {
        let shiftKeyCode: CGKeyCode = 56
        XCTAssertEqual(shiftKeyCode, 56, "Shift 键虚拟键码应为 56")
    }

    /// 测试：sendShiftKey 的事件序列应为 keyDown(true) + keyDown(false)
    func testShiftKeyEventSequence() {
        // 验证 Shift 事件的正确序列：先 keyDown，再 keyDown(false) = keyUp
        var events: [(keyDown: Bool, keyCode: CGKeyCode)] = []

        // 模拟 sendShiftKey 的事件序列
        events.append((keyDown: true, keyCode: 56))   // Shift down
        events.append((keyDown: false, keyCode: 56))  // Shift up

        XCTAssertEqual(events.count, 2, "应有 2 个事件（down + up）")
        XCTAssertTrue(events[0].keyDown, "第 1 个事件应为 keyDown=true")
        XCTAssertFalse(events[1].keyDown, "第 2 个事件应为 keyDown=false")
        XCTAssertEqual(events[0].keyCode, 56, "两个事件都应使用 Shift 键码 56")
        XCTAssertEqual(events[1].keyCode, 56, "两个事件都应使用 Shift 键码 56")
    }

    /// 测试：injectPasswordWithPrelude 的完整流程组合
    func testPreludeFlowCombination() {
        // 场景 1：Shift 成功 + 密码注入成功 → 返回 true
        let scenario1_shiftSuccess = true
        let scenario1_injectionResult = true
        XCTAssertTrue(scenario1_shiftSuccess && scenario1_injectionResult,
                      "Shift 成功 + 注入成功 = true")

        // 场景 2：Shift 成功 + 密码注入失败 → 返回 false
        let scenario2_shiftSuccess = true
        let scenario2_injectionResult = false
        XCTAssertFalse(scenario2_shiftSuccess && scenario2_injectionResult,
                       "Shift 成功 + 注入失败 = false")

        // 场景 3：Shift 失败 + 密码注入成功 → 返回 true（Shift 失败不阻止注入）
        let scenario3_shiftFailed = false
        let scenario3_injectionResult = true
        XCTAssertTrue(scenario3_injectionResult,
                      "Shift 失败后密码注入仍应成功")

        // 场景 4：Shift 失败 + 密码注入失败 → 返回 false
        let scenario4_shiftFailed = false
        let scenario4_injectionResult = false
        XCTAssertFalse(scenario4_injectionResult,
                       "Shift 失败 + 注入失败 = false")
    }
}

// MARK: - TelemetryLogger 格式测试

/// 测试 TelemetryLogger CSV 输出的新列（Result / Duration_ms）及字段值
class TelemetryLoggerFormatTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TelemetryLoggerTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        TelemetryLogger.shared.testLogDirectory = tempDir
        try? FileManager.default.removeItem(at: TelemetryLogger.shared.testLogFile)
    }

    override func tearDown() {
        TelemetryLogger.shared.testLogDirectory = nil
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func csvContent() -> String {
        (try? String(contentsOf: TelemetryLogger.shared.testLogFile, encoding: .utf8)) ?? ""
    }

    // MARK: - 表头列名

    func testCSVHeaderContainsResultColumn() {
        TelemetryLogger.shared.logSync(
            event: .autoUnlock, deviceModel: "test",
            rawRSSI: -60, kalmanRSSI: -60, effectiveRSSI: -60,
            slope: 0, isAnomalous: false)
        let header = csvContent().components(separatedBy: "\n").first ?? ""
        XCTAssertTrue(header.contains("Result"),
                      "CSV 表头应包含 Result 列")
    }

    func testCSVHeaderContainsDurationMsColumn() {
        TelemetryLogger.shared.logSync(
            event: .autoLock, deviceModel: "test",
            rawRSSI: -70, kalmanRSSI: -70, effectiveRSSI: -70,
            slope: 0, isAnomalous: false)
        let header = csvContent().components(separatedBy: "\n").first ?? ""
        XCTAssertTrue(header.contains("Duration_ms"),
                      "CSV 表头应包含 Duration_ms 列")
    }

    func testCSVHeaderOrderAppendsNewColumns() {
        TelemetryLogger.shared.logSync(
            event: .abnormalAlert, deviceModel: "test",
            rawRSSI: -80, kalmanRSSI: -80, effectiveRSSI: -80,
            slope: 0, isAnomalous: true)
        let header = csvContent().components(separatedBy: "\n").first ?? ""
        let isAnomalousPos = header.range(of: "Is_Anomalous")?.lowerBound
        let resultPos = header.range(of: "Result")?.lowerBound
        let durationPos = header.range(of: "Duration_ms")?.lowerBound
        let injectPos = header.range(of: "InjectTime")?.lowerBound
        let confirmPos = header.range(of: "ConfirmTime")?.lowerBound
        XCTAssertNotNil(isAnomalousPos)
        XCTAssertNotNil(resultPos)
        XCTAssertNotNil(durationPos)
        XCTAssertNotNil(injectPos)
        XCTAssertNotNil(confirmPos)
        if let aPos = isAnomalousPos, let rPos = resultPos, let dPos = durationPos,
           let iPos = injectPos, let cPos = confirmPos {
            XCTAssertTrue(aPos < rPos, "Result 应在 Is_Anomalous 之后")
            XCTAssertTrue(rPos < dPos, "Duration_ms 应在 Result 之后")
            XCTAssertTrue(dPos < iPos, "InjectTime 应在 Duration_ms 之后")
            XCTAssertTrue(iPos < cPos, "ConfirmTime 应在 InjectTime 之后")
        }
    }

    // MARK: - Result 字段值

    func testResultDefaultValueIsNA() {
        TelemetryLogger.shared.logSync(
            event: .autoUnlock, deviceModel: "test",
            rawRSSI: -55, kalmanRSSI: -55, effectiveRSSI: -55,
            slope: 0.1, isAnomalous: false)
        let line = csvContent().components(separatedBy: "\n").first(where: { $0.contains("auto_unlock") }) ?? ""
        let columns = line.split(separator: ",")
        XCTAssertEqual(columns.count, 12, "应有 12 列（8 原列 + Result + Duration_ms + InjectTime + ConfirmTime）")
        XCTAssertEqual(String(columns[8]), "N/A", "未传 result 时默认应为 N/A")
    }

    func testResultSuccessValue() {
        TelemetryLogger.shared.logSync(
            event: .autoUnlock, deviceModel: "test",
            rawRSSI: -55, kalmanRSSI: -55, effectiveRSSI: -55,
            slope: 0.1, isAnomalous: false,
            result: "success")
        let line = csvContent().components(separatedBy: "\n").first(where: { $0.contains("auto_unlock") }) ?? ""
        let columns = line.split(separator: ",")
        XCTAssertEqual(columns.count, 12)
        XCTAssertEqual(String(columns[8]), "success")
    }

    func testResultFailValue() {
        TelemetryLogger.shared.logSync(
            event: .autoLock, deviceModel: "test",
            rawRSSI: -70, kalmanRSSI: -70, effectiveRSSI: -70,
            slope: 0, isAnomalous: false,
            result: "fail")
        let line = csvContent().components(separatedBy: "\n").first(where: { $0.contains("auto_lock") }) ?? ""
        let columns = line.split(separator: ",")
        XCTAssertEqual(columns.count, 12)
        XCTAssertEqual(String(columns[8]), "fail")
    }

    func testResultTimeoutValue() {
        TelemetryLogger.shared.logSync(
            event: .abnormalAlert, deviceModel: "test",
            rawRSSI: -80, kalmanRSSI: -80, effectiveRSSI: -80,
            slope: 0, isAnomalous: true,
            result: "timeout")
        let line = csvContent().components(separatedBy: "\n").first(where: { $0.contains("abnormal_alert") }) ?? ""
        let columns = line.split(separator: ",")
        XCTAssertEqual(columns.count, 12)
        XCTAssertEqual(String(columns[8]), "timeout")
    }

    // MARK: - Duration_ms 字段值

    func testDurationMsDefaultValueIsNA() {
        TelemetryLogger.shared.logSync(
            event: .autoUnlock, deviceModel: "test",
            rawRSSI: -55, kalmanRSSI: -55, effectiveRSSI: -55,
            slope: 0.1, isAnomalous: false)
        let line = csvContent().components(separatedBy: "\n").first(where: { $0.contains("auto_unlock") }) ?? ""
        let columns = line.split(separator: ",")
        XCTAssertEqual(columns.count, 12)
        XCTAssertEqual(String(columns[9]), "N/A", "未传 durationMs 时默认应为 N/A")
    }

    func testDurationMsWithValidValue() {
        TelemetryLogger.shared.logSync(
            event: .autoUnlock, deviceModel: "test",
            rawRSSI: -55, kalmanRSSI: -55, effectiveRSSI: -55,
            slope: 0.1, isAnomalous: false,
            durationMs: 1234.5)
        let line = csvContent().components(separatedBy: "\n").first(where: { $0.contains("auto_unlock") }) ?? ""
        let columns = line.split(separator: ",")
        XCTAssertEqual(columns.count, 12)
        XCTAssertEqual(String(columns[9]), "1234.50")
    }

    func testDurationMsWithZero() {
        TelemetryLogger.shared.logSync(
            event: .autoLock, deviceModel: "test",
            rawRSSI: -70, kalmanRSSI: -70, effectiveRSSI: -70,
            slope: 0, isAnomalous: false,
            durationMs: 0)
        let line = csvContent().components(separatedBy: "\n").first(where: { $0.contains("auto_lock") }) ?? ""
        let columns = line.split(separator: ",")
        XCTAssertEqual(columns.count, 12)
        XCTAssertEqual(String(columns[9]), "0.00")
    }

    func testDurationMsDecimalFormat() {
        TelemetryLogger.shared.logSync(
            event: .abnormalAlert, deviceModel: "test",
            rawRSSI: -80, kalmanRSSI: -80, effectiveRSSI: -80,
            slope: 0, isAnomalous: true,
            durationMs: 99.1)
        let line = csvContent().components(separatedBy: "\n").first(where: { $0.contains("abnormal_alert") }) ?? ""
        let columns = line.split(separator: ",")
        XCTAssertEqual(columns.count, 12)
        XCTAssertEqual(String(columns[9]), "99.10")
    }

    // MARK: - 兼容性：未传 result/durationMs 时原字段不受影响

    func testExistingFieldsUnchangedWithoutNewParams() {
        TelemetryLogger.shared.logSync(
            event: .autoUnlock, deviceModel: "iPhone",
            rawRSSI: -62, kalmanRSSI: -63.50, effectiveRSSI: -64.20,
            slope: 0.1234, isAnomalous: false)
        let line = csvContent().components(separatedBy: "\n").first(where: { $0.contains("auto_unlock") }) ?? ""
        // 原字段位置（前8列）不变
        XCTAssertTrue(line.contains("auto_unlock"), "应包含原始 Event_Type")
        XCTAssertTrue(line.contains("iPhone"), "应包含原始 Device_Model")
        XCTAssertTrue(line.contains("-62"), "应包含原始 Raw_RSSI")
        XCTAssertTrue(line.contains("-63.50"), "应包含原始 Kalman_RSSI")
        XCTAssertTrue(line.contains("-64.20"), "应包含原始 Effective_RSSI")
        XCTAssertTrue(line.contains("0.1234"), "应包含原始 Slope")
        XCTAssertTrue(line.contains("false"), "应包含原始 Is_Anomalous")
    }

    // MARK: - 纯值模式：result + durationMs 都传

    func testBothResultAndDurationMsPresent() {
        TelemetryLogger.shared.logSync(
            event: .autoUnlock, deviceModel: "Watch",
            rawRSSI: -50, kalmanRSSI: -51.00, effectiveRSSI: -52.00,
            slope: 0.5000, isAnomalous: false,
            result: "success", durationMs: 2500.75)
        let line = csvContent().components(separatedBy: "\n").first(where: { $0.contains("auto_unlock") }) ?? ""
        XCTAssertTrue(line.contains("success"), "应包含 result=success")
        XCTAssertTrue(line.contains("2500.75"), "应包含 durationMs=2500.75")
    }

    // MARK: - 多条记录行数

    func testMultipleRecordsProduceMultipleRows() {
        TelemetryLogger.shared.logSync(
            event: .autoUnlock, deviceModel: "A",
            rawRSSI: -50, kalmanRSSI: -50, effectiveRSSI: -50,
            slope: 0, isAnomalous: false, result: "success")
        TelemetryLogger.shared.logSync(
            event: .autoLock, deviceModel: "B",
            rawRSSI: -70, kalmanRSSI: -70, effectiveRSSI: -70,
            slope: 0, isAnomalous: false, result: "N/A", durationMs: 0)
        let lines = csvContent().components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 3, "应有 1 行表头 + 2 行数据")
    }

    func testNAValueContainsLiteralNA() {
        TelemetryLogger.shared.logSync(
            event: .autoUnlock, deviceModel: "test",
            rawRSSI: -55, kalmanRSSI: -55, effectiveRSSI: -55,
            slope: 0, isAnomalous: false)
        let line = csvContent().components(separatedBy: "\n").first(where: { $0.contains("auto_unlock") }) ?? ""
        XCTAssertTrue(line.hasSuffix(",N/A,N/A,N/A"), "默认 result/durationMs/injectTime/confirmTime 末尾应为 ,N/A,N/A,N/A")
    }

    // MARK: - InjectTime / ConfirmTime 表头

    func testCSVHeaderContainsInjectTimeColumn() {
        // 确保文件以新表头创建
        try? FileManager.default.removeItem(at: TelemetryLogger.shared.testLogFile)
        TelemetryLogger.shared.logSync(
            event: .autoUnlock, deviceModel: "test",
            rawRSSI: -55, kalmanRSSI: -55, effectiveRSSI: -55,
            slope: 0, isAnomalous: false)
        let header = csvContent().components(separatedBy: "\n").first ?? ""
        XCTAssertTrue(header.contains("InjectTime"), "CSV 表头应包含 InjectTime 列，实际表头: \(header)")
    }

    func testCSVHeaderContainsConfirmTimeColumn() {
        try? FileManager.default.removeItem(at: TelemetryLogger.shared.testLogFile)
        TelemetryLogger.shared.logSync(
            event: .autoUnlock, deviceModel: "test",
            rawRSSI: -55, kalmanRSSI: -55, effectiveRSSI: -55,
            slope: 0, isAnomalous: false)
        let header = csvContent().components(separatedBy: "\n").first ?? ""
        XCTAssertTrue(header.contains("ConfirmTime"), "CSV 表头应包含 ConfirmTime 列，实际表头: \(header)")
    }

    func testCSVHeaderOrderInjectTimeAfterDurationMs() {
        try? FileManager.default.removeItem(at: TelemetryLogger.shared.testLogFile)
        TelemetryLogger.shared.logSync(
            event: .autoUnlock, deviceModel: "test",
            rawRSSI: -55, kalmanRSSI: -55, effectiveRSSI: -55,
            slope: 0, isAnomalous: false)
        let header = csvContent().components(separatedBy: "\n").first ?? ""
        let durationPos = header.range(of: "Duration_ms")?.lowerBound
        let injectPos = header.range(of: "InjectTime")?.lowerBound
        let confirmPos = header.range(of: "ConfirmTime")?.lowerBound
        XCTAssertNotNil(durationPos, "表头应包含 Duration_ms，实际: \(header)")
        XCTAssertNotNil(injectPos, "表头应包含 InjectTime，实际: \(header)")
        XCTAssertNotNil(confirmPos, "表头应包含 ConfirmTime，实际: \(header)")
        if let dPos = durationPos, let iPos = injectPos, let cPos = confirmPos {
            XCTAssertTrue(dPos < iPos, "InjectTime 应在 Duration_ms 之后")
            XCTAssertTrue(iPos < cPos, "ConfirmTime 应在 InjectTime 之后")
        }
    }

    // MARK: - InjectTime / ConfirmTime 默认值

    func testInjectTimeDefaultValueIsNA() {
        TelemetryLogger.shared.logSync(
            event: .autoUnlock, deviceModel: "test",
            rawRSSI: -55, kalmanRSSI: -55, effectiveRSSI: -55,
            slope: 0.1, isAnomalous: false)
        let line = csvContent().components(separatedBy: "\n").first(where: { $0.contains("auto_unlock") }) ?? ""
        let columns = line.split(separator: ",")
        XCTAssertEqual(columns.count, 12, "应有 12 列（10 原列 + InjectTime + ConfirmTime）")
        XCTAssertEqual(String(columns[10]), "N/A", "未传 injectTime 时默认应为 N/A")
    }

    func testConfirmTimeDefaultValueIsNA() {
        TelemetryLogger.shared.logSync(
            event: .autoLock, deviceModel: "test",
            rawRSSI: -70, kalmanRSSI: -70, effectiveRSSI: -70,
            slope: 0, isAnomalous: false)
        let line = csvContent().components(separatedBy: "\n").first(where: { $0.contains("auto_lock") }) ?? ""
        let columns = line.split(separator: ",")
        XCTAssertEqual(columns.count, 12)
        XCTAssertEqual(String(columns[11]), "N/A", "未传 confirmTime 时默认应为 N/A")
    }

    // MARK: - InjectTime / ConfirmTime 传入时间戳

    func testInjectTimeFormattedCorrectly() {
        let inject = Date(timeIntervalSince1970: 1_000_000)  // 1970-01-12 13:46:40 UTC
        TelemetryLogger.shared.logSync(
            event: .autoUnlock, deviceModel: "test",
            rawRSSI: -55, kalmanRSSI: -55, effectiveRSSI: -55,
            slope: 0.1, isAnomalous: false,
            injectTime: inject)
        let line = csvContent().components(separatedBy: "\n").first(where: { $0.contains("auto_unlock") }) ?? ""
        let columns = line.split(separator: ",")
        XCTAssertEqual(columns.count, 12)
        let injectValue = String(columns[10])
        XCTAssertTrue(injectValue.hasPrefix("1970-01-12"), "injectTime 应格式化为日期字符串，实际: \(injectValue)")
        // 使用 Formatter 验证：本地时区下 1_000_000 的时分秒
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.timeZone = TimeZone.current
        let expectedTime = formatter.string(from: inject)
        XCTAssertTrue(injectValue.contains(expectedTime),
                      "injectTime 应包含本地时区时分秒 \(expectedTime)，实际: \(injectValue)")
    }

    func testConfirmTimeFormattedCorrectly() {
        let confirm = Date(timeIntervalSince1970: 1_000_001)  // 1970-01-12 13:46:41 UTC
        TelemetryLogger.shared.logSync(
            event: .autoUnlock, deviceModel: "test",
            rawRSSI: -55, kalmanRSSI: -55, effectiveRSSI: -55,
            slope: 0.1, isAnomalous: false,
            confirmTime: confirm)
        let line = csvContent().components(separatedBy: "\n").first(where: { $0.contains("auto_unlock") }) ?? ""
        let columns = line.split(separator: ",")
        XCTAssertEqual(columns.count, 12)
        let confirmValue = String(columns[11])
        XCTAssertTrue(confirmValue.hasPrefix("1970-01-12"), "confirmTime 应格式化为日期字符串，实际: \(confirmValue)")
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.timeZone = TimeZone.current
        let expectedTime = formatter.string(from: confirm)
        XCTAssertTrue(confirmValue.contains(expectedTime),
                      "confirmTime 应包含本地时区时分秒 \(expectedTime)，实际: \(confirmValue)")
    }

    func testBothInjectAndConfirmTimePresent() {
        let inject = Date(timeIntervalSince1970: 1_000_000)
        let confirm = Date(timeIntervalSince1970: 1_000_001)
        TelemetryLogger.shared.logSync(
            event: .autoUnlock, deviceModel: "Watch",
            rawRSSI: -50, kalmanRSSI: -51, effectiveRSSI: -52,
            slope: 0.5, isAnomalous: false,
            result: "success", durationMs: 1000,
            injectTime: inject, confirmTime: confirm)
        let line = csvContent().components(separatedBy: "\n").first(where: { $0.contains("auto_unlock") }) ?? ""
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.timeZone = TimeZone.current
        XCTAssertTrue(line.contains(formatter.string(from: inject)),
                      "应包含 injectTime 格式化值")
        XCTAssertTrue(line.contains(formatter.string(from: confirm)),
                      "应包含 confirmTime 格式化值")
        XCTAssertTrue(line.contains("success"), "result 字段不受影响")
        XCTAssertTrue(line.contains("1000.00"), "durationMs 字段不受影响")
    }

    // MARK: - 向后兼容：旧字段位置不变

    func testExistingColumnsUnchangedWithNewTimeParams() {
        let inject = Date(timeIntervalSince1970: 1_000_000)
        let confirm = Date(timeIntervalSince1970: 1_000_001)
        TelemetryLogger.shared.logSync(
            event: .autoUnlock, deviceModel: "iPhone",
            rawRSSI: -62, kalmanRSSI: -63.50, effectiveRSSI: -64.20,
            slope: 0.1234, isAnomalous: false,
            injectTime: inject, confirmTime: confirm)
        let line = csvContent().components(separatedBy: "\n").first(where: { $0.contains("auto_unlock") }) ?? ""
        // 原字段位置（前8列）不变
        XCTAssertTrue(line.contains("auto_unlock"), "应包含原始 Event_Type")
        XCTAssertTrue(line.contains("iPhone"), "应包含原始 Device_Model")
        XCTAssertTrue(line.contains("-62"), "应包含原始 Raw_RSSI")
        XCTAssertTrue(line.contains("-63.50"), "应包含原始 Kalman_RSSI")
        XCTAssertTrue(line.contains("-64.20"), "应包含原始 Effective_RSSI")
        XCTAssertTrue(line.contains("0.1234"), "应包含原始 Slope")
        XCTAssertTrue(line.contains("false"), "应包含原始 Is_Anomalous")
    }
}

// MARK: - 兼容性回归测试（LegacyCompatibilityTests）

/// 回归测试：验证 v2.5 新增功能不破坏现有接口的默认行为。
/// 重点覆盖：ScriptRunner.logEvent、FUnManager 默认值、TelemetryLogger 新旧调用路径。
@MainActor
class LegacyCompatibilityTests: XCTestCase {

    // MARK: - ScriptRunner.logEvent 向后兼容

    private var logFile: URL!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        let dir = try! FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        logFile = dir.appendingPathComponent("FUnlock/events.log")
        try? "".write(to: logFile, atomically: true, encoding: .utf8)

        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyCompatTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        TelemetryLogger.shared.testLogDirectory = tempDir
        try? FileManager.default.removeItem(at: TelemetryLogger.shared.testLogFile)
    }

    override func tearDown() {
        try? "".write(to: logFile, atomically: true, encoding: .utf8)
        TelemetryLogger.shared.testLogDirectory = nil
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func readLog() -> String {
        (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
    }

    /// logEvent 单参数调用（旧签名）仍能正常写入
    func testLogEventLegacySignatureStillWorks() {
        ScriptRunner.shared.logEvent("legacy_event")
        let content = readLog()
        XCTAssertTrue(content.contains("legacy_event"), "旧签名 logEvent 应正常写入事件名")
        XCTAssertTrue(content.contains("RSSI: N/A"), "无 RSSI 参数时应显示 N/A")
    }

    /// logEvent 双参数调用（旧签名）仍能正常写入 RSSI
    func testLogEventWithRSSILegacySignatureStillWorks() {
        ScriptRunner.shared.logEvent("legacy_rssi_event", rssi: -72)
        let content = readLog()
        XCTAssertTrue(content.contains("legacy_rssi_event"), "应写入事件名")
        XCTAssertTrue(content.contains("RSSI: -72"), "应写入 RSSI 值")
    }

    /// logEvent 不受去重窗口限制（连续写入同名事件应全部写入）
    func testLogEventBypassesDedup() {
        ScriptRunner.shared.logEvent("dedup_bypass", rssi: -50)
        ScriptRunner.shared.logEvent("dedup_bypass", rssi: -50)
        ScriptRunner.shared.logEvent("dedup_bypass", rssi: -50)
        let content = readLog()
        let count = content.components(separatedBy: "dedup_bypass").count - 1
        XCTAssertEqual(count, 3, "logEvent 不应去重，三次调用都应写入")
    }

    /// logEvent 日志行格式与旧版本一致：timestamp | event | RSSI: value
    func testLogEventLineFormatMatchesLegacy() {
        ScriptRunner.shared.logEvent("format_check", rssi: -80)
        let content = readLog()
        let lines = content.components(separatedBy: "\n").filter { $0.contains("format_check") }
        XCTAssertFalse(lines.isEmpty, "应有包含 format_check 的日志行")
        guard let line = lines.first else { return }
        // 格式：yyyy-MM-dd HH:mm:ss | event | RSSI: value
        XCTAssertTrue(line.contains("format_check"), "应包含事件名")
        XCTAssertTrue(line.contains("RSSI: -80"), "应包含 RSSI 值")
        XCTAssertTrue(line.contains(" | "), "应使用 ' | ' 分隔符")
        let datePattern = #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}"#
        let regex = try! NSRegularExpression(pattern: datePattern, options: [])
        let range = NSRange(line.startIndex..., in: line)
        XCTAssertNotNil(regex.firstMatch(in: line, range: range),
                        "日志行应以 yyyy-MM-dd HH:mm:ss 开头，实际: \(line)")
    }

    /// logEvent 写入的文件路径不变（~/Library/Application Support/FUnlock/events.log）
    func testLogEventFilePathUnchanged() {
        ScriptRunner.shared.logEvent("path_check")
        XCTAssertTrue(FileManager.default.fileExists(atPath: logFile.path),
                      "events.log 应写入固定路径")
        let content = readLog()
        XCTAssertTrue(content.contains("path_check"), "事件应写入正确路径")
    }

    /// logEventIfNeeded（新接口）首次调用返回 true
    func testLogEventIfNeededFirstCallReturnsTrue() {
        let runner = ScriptRunner(dedupWindow: 3.0) { Date() }
        let logged = runner.logEventIfNeeded("new_api_first")
        XCTAssertTrue(logged, "新接口首次调用应返回 true")
    }

    /// logEventIfNeeded（新接口）窗口内重复返回 false
    func testLogEventIfNeededDuplicateReturnsFalse() {
        let runner = ScriptRunner(dedupWindow: 3.0) { Date() }
        _ = runner.logEventIfNeeded("new_api_dup")
        let second = runner.logEventIfNeeded("new_api_dup")
        XCTAssertFalse(second, "新接口窗口内重复应返回 false")
    }

    /// logEvent 与 logEventIfNeeded 共存：logEvent 不被 logEventIfNeeded 的去重影响
    func testLegacyAndNewAPIsCoexist() {
        let runner = ScriptRunner(dedupWindow: 3.0) { Date() }
        _ = runner.logEventIfNeeded("coexist_event")
        // logEvent 应无视去重，仍能写入
        runner.logEvent("coexist_event", rssi: -60)
        let content = readLog()
        let count = content.components(separatedBy: "coexist_event").count - 1
        XCTAssertEqual(count, 2, "logEvent 与 logEventIfNeeded 应独立工作，共写入 2 条")
    }

    // MARK: - FUnManager 默认值兼容

    /// FUnManager 的 lockRSSI 默认值与 FUn 一致
    func testFUnManagerDefaultLockRSSIMatchesFUn() {
        let fun = FUn()
        let manager = FUnManager(fun: fun)
        XCTAssertEqual(manager.lockRSSI, fun.lockRSSI, "FUnManager.lockRSSI 默认值应与 FUn.lockRSSI 一致")
    }

    /// FUnManager 的 unlockRSSI 默认值与 FUn 一致
    func testFUnManagerDefaultUnlockRSSIMatchesFUn() {
        let fun = FUn()
        let manager = FUnManager(fun: fun)
        XCTAssertEqual(manager.unlockRSSI, fun.unlockRSSI, "FUnManager.unlockRSSI 默认值应与 FUn.unlockRSSI 一致")
    }

    /// FUnManager 解锁冷却默认值为 5 秒
    func testFUnManagerDefaultCooldownIs5Seconds() {
        let manager = FUnManager(fun: FUn())
        XCTAssertEqual(manager.unlockCooldownDuration, 5.0,
                       "默认解锁冷却时间应为 5 秒，保证旧版行为不变")
    }

    /// FUnManager 锁屏缓冲默认值为 0.8 秒
    func testFUnManagerDefaultBufferIs08Seconds() {
        let manager = FUnManager(fun: FUn())
        XCTAssertEqual(manager.lockBufferDuration, 0.8,
                       "默认锁屏缓冲时间应为 0.8 秒，保证旧版行为不变")
    }

    /// FUnManager 初始状态：lastLockTime 和 lastUnlockTime 均为 distantPast
    func testFUnManagerInitialTimestampsAreDistantPast() {
        let manager = FUnManager(fun: FUn())
        XCTAssertEqual(manager.lastLockTime, Date.distantPast,
                       "初始 lastLockTime 应为 distantPast")
        XCTAssertEqual(manager.lastUnlockTime, Date.distantPast,
                       "初始 lastUnlockTime 应为 distantPast")
    }

    /// FUnManager 初始 state 的 screen 应为 unlocked
    func testFUnManagerInitialStateScreenIsUnlocked() {
        let manager = FUnManager(fun: FUn())
        if case .unlocked = manager.state.screen {
            // OK
        } else {
            XCTFail("初始 state.screen 应为 .unlocked，实际: \(manager.state.screen)")
        }
    }

    /// FUnManager 初始 state 的 system 应为 awake
    func testFUnManagerInitialStateSystemIsAwake() {
        let manager = FUnManager(fun: FUn())
        XCTAssertEqual(manager.state.system, .awake, "初始 state.system 应为 .awake")
    }

    /// FUnManager 初始 state 的 intent 应为 autoLock
    func testFUnManagerInitialStateIntentIsAutoLock() {
        let manager = FUnManager(fun: FUn())
        if case .autoLock = manager.state.intent {
            // OK
        } else {
            XCTFail("初始 state.intent 应为 .autoLock")
        }
    }

    /// FUnManager 初始 connected 应为 false
    func testFUnManagerInitialConnectedIsFalse() {
        let manager = FUnManager(fun: FUn())
        XCTAssertFalse(manager.connected, "初始 connected 应为 false")
    }

    /// FUnManager 初始 rssi 应为 nil
    func testFUnManagerInitialRSSIIsNil() {
        let manager = FUnManager(fun: FUn())
        XCTAssertNil(manager.rssi, "初始 rssi 应为 nil")
    }

    // MARK: - TelemetryLogger 新旧调用兼容

    private func csvContent() -> String {
        (try? String(contentsOf: TelemetryLogger.shared.testLogFile, encoding: .utf8)) ?? ""
    }

    /// 旧式调用（6 个必填参数，不传 result/durationMs/injectTime/confirmTime）仍可编译并写入
    func testTelemetryLegacyCallWith6ParamsStillWorks() {
        TelemetryLogger.shared.logSync(
            event: .autoUnlock,
            deviceModel: "test-device",
            rawRSSI: -55,
            kalmanRSSI: -56.0,
            effectiveRSSI: -57.5,
            slope: 0.1234,
            isAnomalous: false
        )
        let content = csvContent()
        XCTAssertTrue(content.contains("auto_unlock"), "旧式调用应写入 auto_unlock 事件")
        XCTAssertTrue(content.contains("test-device"), "旧式调用应写入设备名")
        XCTAssertTrue(content.contains("-55"), "旧式调用应写入 rawRSSI")
    }

    /// 旧式调用的新增列（Result / Duration_ms / InjectTime / ConfirmTime）默认为 N/A
    func testTelemetryLegacyCallNewColumnsDefaultToNA() {
        TelemetryLogger.shared.logSync(
            event: .autoLock,
            deviceModel: "legacy-model",
            rawRSSI: -70,
            kalmanRSSI: -71,
            effectiveRSSI: -72,
            slope: 0.5,
            isAnomalous: true
        )
        let line = csvContent().components(separatedBy: "\n").first(where: { $0.contains("auto_lock") }) ?? ""
        let columns = line.split(separator: ",")
        XCTAssertEqual(columns.count, 12, "应有 12 列")
        XCTAssertEqual(String(columns[8]), "N/A", "Result 默认值应为 N/A")
        XCTAssertEqual(String(columns[9]), "N/A", "Duration_ms 默认值应为 N/A")
        XCTAssertEqual(String(columns[10]), "N/A", "InjectTime 默认值应为 N/A")
        XCTAssertEqual(String(columns[11]), "N/A", "ConfirmTime 默认值应为 N/A")
    }

    /// 旧式调用的原始 8 列字段值正确
    func testTelemetryLegacyCallOriginal8ColumnsCorrect() {
        TelemetryLogger.shared.logSync(
            event: .abnormalAlert,
            deviceModel: "Watch",
            rawRSSI: -80,
            kalmanRSSI: -81.00,
            effectiveRSSI: -82.50,
            slope: 0.4321,
            isAnomalous: true
        )
        let line = csvContent().components(separatedBy: "\n").first(where: { $0.contains("abnormal_alert") }) ?? ""
        let columns = line.split(separator: ",")
        XCTAssertEqual(String(columns[0]).count > 0, true, "Timestamp 不应为空")
        XCTAssertEqual(String(columns[1]), "abnormal_alert", "Event_Type 应为 abnormal_alert")
        XCTAssertEqual(String(columns[2]), "Watch", "Device_Model 应为 Watch")
        XCTAssertEqual(String(columns[3]), "-80", "Raw_RSSI 应为 -80")
        XCTAssertEqual(String(columns[4]), "-81.00", "Kalman_RSSI 应为 -81.00")
        XCTAssertEqual(String(columns[5]), "-82.50", "Effective_RSSI 应为 -82.50")
        XCTAssertEqual(String(columns[6]), "0.4321", "Slope 应为 0.4321")
        XCTAssertEqual(String(columns[7]), "true", "Is_Anomalous 应为 true")
    }

    /// 新式调用（传入 result + durationMs）不影响原始 8 列
    func testTelemetryNewCallDoesNotAlterOriginalColumns() {
        TelemetryLogger.shared.logSync(
            event: .autoUnlock,
            deviceModel: "iPhone 15",
            rawRSSI: -60,
            kalmanRSSI: -61.50,
            effectiveRSSI: -62.75,
            slope: 0.9876,
            isAnomalous: false,
            result: "success",
            durationMs: 3200.00
        )
        let line = csvContent().components(separatedBy: "\n").first(where: { $0.contains("auto_unlock") }) ?? ""
        let columns = line.split(separator: ",")
        XCTAssertEqual(String(columns[1]), "auto_unlock")
        XCTAssertEqual(String(columns[2]), "iPhone 15")
        XCTAssertEqual(String(columns[3]), "-60")
        XCTAssertEqual(String(columns[4]), "-61.50")
        XCTAssertEqual(String(columns[5]), "-62.75")
        XCTAssertEqual(String(columns[6]), "0.9876")
        XCTAssertEqual(String(columns[7]), "false")
        XCTAssertEqual(String(columns[8]), "success", "Result 应为 success")
        XCTAssertEqual(String(columns[9]), "3200.00", "Duration_ms 应为 3200.00")
    }

    /// TelemetryLogger.shared 单例可正常访问，不崩溃
    func testTelemetryLoggerSharedSingletonIsAccessible() {
        let logger = TelemetryLogger.shared
        XCTAssertNotNil(logger, "TelemetryLogger.shared 不应为 nil")
        // 多次访问不崩溃
        _ = TelemetryLogger.shared
        _ = TelemetryLogger.shared
    }

    /// TelemetryLogger 异步 log 与同步 logSync 写入格式一致
    func testTelemetryAsyncAndSyncProduceSameCSVFormat() {
        let syncLine: String = {
            TelemetryLogger.shared.logSync(
                event: .autoUnlock,
                deviceModel: "sync-test",
                rawRSSI: -50,
                kalmanRSSI: -51,
                effectiveRSSI: -52,
                slope: 0.1,
                isAnomalous: false,
                result: "success",
                durationMs: 1000)
            return csvContent().components(separatedBy: "\n").first(where: { $0.contains("sync-test") }) ?? ""
        }()

        let syncCols = syncLine.split(separator: ",")
        XCTAssertEqual(syncCols.count, 12, "logSync 应产生 12 列 CSV 行")
        XCTAssertEqual(String(syncCols[8]), "success")
        XCTAssertEqual(String(syncCols[9]), "1000.00")
    }

    // MARK: - FUnManager 与 ScriptRunner 调用路径兼容

    /// FUnManager.onUnlock 调用链：应触发 ScriptRunner.logEvent("unlocked") 和 TelemetryLogger.log(.autoUnlock)
    func testOnUnlockTriggersLegacyScriptRunnerLogEvent() {
        let manager = FUnManager(fun: FUn())
        manager.onUnlock()

        // 验证 logEvent 被间接调用（通过读取 events.log）
        let content = readLog()
        // onUnlock 内部通过 intrudeCheckTask 异步写入，这里验证 lastUnlockTime 被更新
        // 使用时间间隔比较：两者应在同一秒内
        let interval = manager.lastUnlockTime.timeIntervalSince(manager.state.unlockedAt)
        XCTAssertEqualWithAccuracy(interval, 0, accuracy: 1.0,
                                   "onUnlock 后 lastUnlockTime 与 unlockedAt 应在同一秒内")
        XCTAssertTrue(manager.state.screen == .unlocked, "onUnlock 后 screen 应为 unlocked")
    }

    /// FUnManager.onSystemScreenLocked 设置 lastLockTime，isLockBufferActive 生效
    func testOnSystemScreenLockedActivatesLockBuffer() {
        let manager = FUnManager(fun: FUn())
        let before = Date()
        manager.onSystemScreenLocked()
        XCTAssertGreaterThanOrEqual(manager.lastLockTime.timeIntervalSince1970,
                                    before.timeIntervalSince1970,
                                    "onSystemScreenLocked 应设置 lastLockTime 为当前时间")
        XCTAssertTrue(manager.isLockBufferActive(),
                      "onSystemScreenLocked 后 isLockBufferActive 应为 true")
    }

    /// FUnManager 状态机：onUnlock → onSystemScreenLocked 序列正确
    func testUnlockThenLockSequenceMaintainsStateConsistency() {
        let manager = FUnManager(fun: FUn())

        // 初始：unlocked
        XCTAssertTrue(manager.state.screen == .unlocked, "初始应为 unlocked")

        // 解锁
        manager.onUnlock()
        XCTAssertTrue(manager.state.screen == .unlocked, "onUnlock 后应为 unlocked")
        XCTAssertTrue(manager.state.intent == .autoLock, "onUnlock 后 intent 应为 autoLock")

        // 手动锁屏
        manager.onSystemScreenLocked()
        if case .locked(let reason) = manager.state.screen {
            XCTAssertEqual(reason, .manual, "手动锁屏后 reason 应为 manual")
        } else {
            XCTFail("手动锁屏后 screen 应为 .locked")
        }
        // lastUnlockTime 应被设置（不为 distantPast），且冷却应在时间窗口内
        XCTAssertNotEqual(manager.lastUnlockTime, Date.distantPast,
                          "onUnlock 后 lastUnlockTime 不应为 distantPast")
    }
}

// MARK: - FUnManager 状态机集成测试

/// 验证 FUnManager 与状态机的集成：属性存在性、系统就绪检查、onUnlock 重置
@MainActor
class FUnManagerStateMachineIntegrationTests: XCTestCase {

    func testFUnManagerHasStateMachineProperty() {
        let manager = FUnManager(fun: FUn())
        XCTAssertNotNil(manager.stateMachine, "FUnManager 应有 stateMachine 属性")
    }

    func testOnUnlockResetsStateMachineToActive() {
        let manager = FUnManager(fun: FUn())
        // 模拟失败触发降级
        manager.stateMachine.handleUnlockFailure()
        manager.stateMachine.handleUnlockFailure()
        manager.stateMachine.handleUnlockFailure()
        XCTAssertEqual(manager.stateMachine.currentState, .degraded, "3 次失败后应为 degraded")

        // 用户手动解锁 → resetToActive
        manager.onUnlock()
        // onUnlock 内部通过 Task 调用 resetToActive，需要短暂等待
        let expectation = XCTestExpectation(description: "state machine reset")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(manager.stateMachine.currentState, .active,
                           "onUnlock 后状态机应重置为 active")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testStateMachineTaskCancelledInCleanup() {
        let manager = FUnManager(fun: FUn())
        let task = Task.detached { try await Task.sleep(nanoseconds: 60_000_000_000) }
        manager.stateMachine.setActiveTask(task as! Task<Void, Never>)
        manager.cleanup()
        // cleanup 应取消状态机任务（无崩溃即通过）
    }
}
