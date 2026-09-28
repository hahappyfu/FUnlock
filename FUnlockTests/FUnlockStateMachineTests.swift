// FUnlockTests/FUnlockStateMachineTests.swift
import XCTest
import UserNotifications
@testable import FUnlock

/// 测试 FUnlockStateMachine 的状态转换、冷却、降级逻辑
@MainActor
class FUnlockStateMachineTests: XCTestCase {

    private var sm: FUnlockStateMachine!

    override func setUp() async throws {
        try await super.setUp()
        sm = FUnlockStateMachine()
    }

    // MARK: - 初始状态

    func testInitialStateIsActive() {
        XCTAssertEqual(sm.currentState, .active, "初始状态应为 active")
    }

    func testInitialConsecutiveFailuresIsZero() {
        XCTAssertEqual(sm.consecutiveFailures, 0, "初始连续失败次数应为 0")
    }

    func testInitialIsNotInCooldown() {
        XCTAssertFalse(sm.isInCooldown, "初始状态不应处于冷却期")
    }

    func testInitialCanAttemptUnlock() {
        XCTAssertTrue(sm.canAttemptUnlock, "初始状态应允许解锁尝试")
    }

    // MARK: - 状态转换

    func testTransitionUnlockingToActive() {
        sm.transition(to: .unlocking)
        sm.transition(to: .active)
        XCTAssertEqual(sm.currentState, .active, "unlocking → active 应成功")
    }

    func testTransitionUnlockingToCooldown() {
        sm.transition(to: .unlocking)
        sm.transition(to: .cooldown)
        XCTAssertEqual(sm.currentState, .cooldown, "unlocking → cooldown 应成功")
    }

    func testTransitionCooldownToActive() {
        sm.transition(to: .unlocking)
        sm.transition(to: .cooldown)
        sm.transition(to: .active)
        XCTAssertEqual(sm.currentState, .active, "cooldown → active 应成功")
    }

    func testAnyStateCanTransitionToDegraded() {
        sm.transition(to: .unlocking)
        sm.transition(to: .degraded)
        XCTAssertEqual(sm.currentState, .degraded, "任意状态 → degraded 应成功")
    }

    func testAnyStateCanTransitionToActive() {
        sm.transition(to: .degraded)
        sm.transition(to: .active)
        XCTAssertEqual(sm.currentState, .active, "degraded → active 应成功（用户干预）")
    }

    func testInvalidTransitionIsRejected() {
        _ = sm.attemptUnlock()  // active → unlocking
        XCTAssertFalse(sm.transition(to: .unlocking), "unlocking → unlocking 自转移应被拒绝")
        XCTAssertEqual(sm.currentState, .unlocking, "非法转移后状态不应改变")
    }

    func testTransitionCooldownToUnlocking() {
        sm.transition(to: .unlocking)
        sm.transition(to: .cooldown)
        sm.transition(to: .unlocking)
        XCTAssertEqual(sm.currentState, .unlocking, "cooldown → unlocking 应成功（失败冷却后再次尝试解锁）")
    }

    func testTransitionReturnsSuccess() {
        XCTAssertTrue(sm.transition(to: .unlocking), "合法转移应返回 true")
        XCTAssertFalse(sm.transition(to: .unlocking), "非法转移应返回 false（可观测）")
    }

    // MARK: - attemptUnlock

    func testAttemptUnlockFromActiveSucceeds() {
        let allowed = sm.attemptUnlock()
        XCTAssertTrue(allowed, "active 状态下应允许解锁")
        XCTAssertEqual(sm.currentState, .unlocking, "attemptUnlock 后应进入 unlocking")
    }

    func testAttemptUnlockFromDegraded() {
        sm.transition(to: .degraded)
        let allowed = sm.attemptUnlock()
        XCTAssertFalse(allowed, "degraded 状态下应拒绝解锁")
        XCTAssertEqual(sm.currentState, .degraded, "degraded 状态不应改变")
    }

    func testAttemptUnlockCooldownBlocks() {
        _ = sm.attemptUnlock()
        let second = sm.attemptUnlock()
        XCTAssertFalse(second, "5 秒冷却内应拒绝第二次解锁")
        XCTAssertEqual(sm.currentState, .unlocking, "第二次尝试被拒后状态不应改变")
    }

    func testAttemptUnlockAfterCooldownExpires() {
        // 注入时间源模拟冷却流逝，替代真实等待 5.1s（同文件 *TimeSourceTests 的示范做法）
        var currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        let sm = FUnlockStateMachine(nowProvider: { currentTime })

        XCTAssertTrue(sm.attemptUnlock(), "首次应允许解锁")
        // 真实流程：解锁尝试后会经成功/失败处理离开 unlocking（.unlocking→.unlocking 自转移已被拒绝）
        sm.handleUnlockSuccess()

        // 模拟时间推进 5.1 秒（超过 5 秒冷却）
        currentTime = currentTime.addingTimeInterval(5.1)
        XCTAssertTrue(sm.attemptUnlock(), "冷却期过后应允许解锁")
    }

    func testThreeFailuresTriggerDegraded() {
        sm.handleUnlockFailure()
        sm.handleUnlockFailure()
        sm.handleUnlockFailure()
        XCTAssertEqual(sm.currentState, .degraded, "3 次失败后应进入 degraded")
        XCTAssertEqual(sm.consecutiveFailures, 3)
    }

    func testAttemptUnlockRejectedAfterDegraded() {
        sm.handleUnlockFailure()
        sm.handleUnlockFailure()
        sm.handleUnlockFailure()
        let allowed = sm.attemptUnlock()
        XCTAssertFalse(allowed, "degraded 状态下 attemptUnlock 应返回 false")
    }

    // MARK: - handleUnlockFailure

    func testFailureSetsCooldown() {
        sm.handleUnlockFailure()
        XCTAssertTrue(sm.isInCooldown, "失败后应进入冷却期")
    }

    func testThreeFailuresTransitionToDegraded() {
        sm.handleUnlockFailure()
        XCTAssertEqual(sm.currentState, .cooldown, "1 次失败后应为 cooldown")
        sm.handleUnlockFailure()
        XCTAssertEqual(sm.currentState, .cooldown, "2 次失败后仍为 cooldown")
        sm.handleUnlockFailure()
        XCTAssertEqual(sm.currentState, .degraded, "3 次失败后应为 degraded")
    }

    // MARK: - handleUnlockSuccess

    func testSuccessResetsFailures() {
        sm.handleUnlockFailure()
        sm.handleUnlockFailure()
        sm.handleUnlockSuccess()
        XCTAssertEqual(sm.consecutiveFailures, 0, "成功后应清零连续失败次数")
    }

    func testSuccessTransitionsToActive() {
        sm.handleUnlockFailure()
        sm.transition(to: .unlocking)
        sm.handleUnlockSuccess()
        XCTAssertEqual(sm.currentState, .active, "成功后应转为 active")
    }

    // MARK: - resetToActive

    func testResetToActiveFromDegraded() {
        sm.handleUnlockFailure()
        sm.handleUnlockFailure()
        sm.handleUnlockFailure()
        XCTAssertEqual(sm.currentState, .degraded)
        sm.resetToActive()
        XCTAssertEqual(sm.currentState, .active, "resetToActive 后应回到 active")
        XCTAssertEqual(sm.consecutiveFailures, 0, "resetToActive 应清零失败次数")
    }

    // MARK: - canAttemptUnlock 综合场景

    func testCanAttemptUnlockBlockedByDegraded() {
        sm.handleUnlockFailure()
        sm.handleUnlockFailure()
        sm.handleUnlockFailure()
        XCTAssertFalse(sm.canAttemptUnlock, "degraded 状态 canAttemptUnlock 应为 false")
    }

    func testCanAttemptUnlockBlockedByCooldown() {
        sm.handleUnlockFailure()
        XCTAssertFalse(sm.canAttemptUnlock, "冷却期 canAttemptUnlock 应为 false")
    }

    func testCanAttemptUnlockAllowedAfterSuccess() {
        sm.handleUnlockFailure()
        sm.handleUnlockSuccess()
        XCTAssertTrue(sm.canAttemptUnlock, "成功后 canAttemptUnlock 应恢复为 true")
    }

    func testCanAttemptUnlockBlockedWhileUnlocking() {
        // P0-4：注入在途（.unlocking）时必须拒绝再次尝试——否则 0.5s 快轮询重入
        // 会触发 attemptAutoUnlock 取消在途解锁任务，误判失败连续 3 次即 degraded
        XCTAssertTrue(sm.attemptUnlock(), "防抖窗口外首次尝试应进入 unlocking")
        XCTAssertEqual(sm.currentState, .unlocking)
        XCTAssertFalse(sm.canAttemptUnlock, "unlocking 状态 canAttemptUnlock 应为 false")
        sm.handleUnlockSuccess()
        XCTAssertTrue(sm.canAttemptUnlock, "成功回到 active 后恢复")
    }
}

// MARK: - FUnlockStateMachine 可测试时间源测试

/// 验证 FUnlockStateMachine 的 nowProvider 注入能力
@MainActor
class FUnlockStateMachineTimeSourceTests: XCTestCase {

    func testAttemptUnlockUsesInjectedTime() {
        var currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        let sm = FUnlockStateMachine(nowProvider: { currentTime })

        let allowed = sm.attemptUnlock()
        XCTAssertTrue(allowed, "首次应允许解锁")
        // 真实流程：解锁尝试后经成功处理离开 unlocking（.unlocking→.unlocking 自转移已被拒绝）
        sm.handleUnlockSuccess()

        // 模拟时间推进 3 秒（未超过 5 秒冷却）
        currentTime = currentTime.addingTimeInterval(3.0)
        let blocked = sm.attemptUnlock()
        XCTAssertFalse(blocked, "3 秒内应被冷却阻止")

        // 模拟时间推进到 6 秒（超过 5 秒冷却）
        currentTime = currentTime.addingTimeInterval(3.0)
        let allowedAgain = sm.attemptUnlock()
        XCTAssertTrue(allowedAgain, "6 秒后冷却应过期，允许解锁")
    }

    func testFailureCooldownUsesInjectedTime() {
        var currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        let sm = FUnlockStateMachine(nowProvider: { currentTime })

        sm.handleUnlockFailure()
        XCTAssertTrue(sm.isInCooldown, "失败后应进入冷却")

        // 9 秒后仍在冷却
        currentTime = currentTime.addingTimeInterval(9.0)
        XCTAssertTrue(sm.isInCooldown, "9 秒后应仍在冷却（10 秒冷却期）")

        // 11 秒后冷却结束
        currentTime = currentTime.addingTimeInterval(2.0)
        XCTAssertFalse(sm.isInCooldown, "11 秒后冷却应结束")
    }

    func testAttemptUnlockBlockedByFailureCooldown() {
        var currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        let sm = FUnlockStateMachine(nowProvider: { currentTime })

        sm.handleUnlockFailure()
        // 5 秒防抖已过，但 10 秒失败冷却期内 attemptUnlock 仍应拒绝（与 canAttemptUnlock 门控内聚）
        currentTime = currentTime.addingTimeInterval(6.0)
        XCTAssertFalse(sm.attemptUnlock(), "失败冷却期内 attemptUnlock 应被拒绝")
    }

    func testAttemptUnlockFromCooldownAfterFailureCooldownExpires() {
        var currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        let sm = FUnlockStateMachine(nowProvider: { currentTime })

        sm.handleUnlockFailure()
        XCTAssertEqual(sm.currentState, .cooldown, "1 次失败后应为 cooldown")

        // 11 秒后失败冷却结束，cooldown → unlocking 转移应成功
        currentTime = currentTime.addingTimeInterval(11.0)
        XCTAssertTrue(sm.attemptUnlock(), "失败冷却结束后应允许解锁")
        XCTAssertEqual(sm.currentState, .unlocking, "冷却结束后 attemptUnlock 应转入 unlocking")
    }
}

// MARK: - 连续失败降级通知测试

/// 测试连续失败降级通知发送和状态机重置
@MainActor
class DegradedNotificationTests: XCTestCase {

    func testDegradedNotificationIDConstant() {
        XCTAssertEqual(FUnlockStateMachine.degradedNotificationID, "funlock-degraded",
                       "降级通知标识符应为 funlock-degraded")
    }

    func testThreeFailuresTriggersDegradedAndNotification() {
        let sm = FUnlockStateMachine()

        sm.handleUnlockFailure()
        XCTAssertEqual(sm.currentState, .cooldown, "1 次失败后应为 cooldown")
        sm.handleUnlockFailure()
        XCTAssertEqual(sm.currentState, .cooldown, "2 次失败后仍为 cooldown")
        sm.handleUnlockFailure()
        XCTAssertEqual(sm.currentState, .degraded, "3 次失败后应为 degraded")
        XCTAssertEqual(sm.consecutiveFailures, 3, "连续失败次数应为 3")
    }

    func testResetFromDegradedRestoresCanAttemptUnlock() {
        let sm = FUnlockStateMachine()

        // 触发降级
        sm.handleUnlockFailure()
        sm.handleUnlockFailure()
        sm.handleUnlockFailure()
        XCTAssertEqual(sm.currentState, .degraded)
        XCTAssertFalse(sm.canAttemptUnlock, "degraded 时 canAttemptUnlock 应为 false")

        // 模拟用户点击通知后重置
        sm.resetToActive()
        XCTAssertEqual(sm.currentState, .active, "重置后应为 active")
        XCTAssertEqual(sm.consecutiveFailures, 0, "重置后失败次数应为 0")
        XCTAssertTrue(sm.canAttemptUnlock, "重置后 canAttemptUnlock 应为 true")
    }

    func testDegradedBlocksAttemptUnlock() {
        let sm = FUnlockStateMachine()

        sm.handleUnlockFailure()
        sm.handleUnlockFailure()
        sm.handleUnlockFailure()
        XCTAssertEqual(sm.currentState, .degraded)

        let allowed = sm.attemptUnlock()
        XCTAssertFalse(allowed, "degraded 状态下 attemptUnlock 应被拒绝")
    }

    func testPartialFailuresDoNotTriggerDegraded() {
        let sm = FUnlockStateMachine()

        sm.handleUnlockFailure()
        sm.handleUnlockFailure()
        XCTAssertEqual(sm.currentState, .cooldown, "2 次失败后应为 cooldown，非 degraded")
        XCTAssertTrue(sm.consecutiveFailures < 3, "2 次失败未达上限")
    }
}

/// 测试心跳兜底用的时间衰减计算（getEffectiveRSSI 的静态实现）
@MainActor
class TimeDecayTests: XCTestCase {

    func testNoGapHasNoPenalty() {
        let eff = FUn.decayedEffectiveRSSI(effectiveRSSI: -65, elapsedSinceLastReceive: 0)
        XCTAssertEqual(eff, -65, "无采样间隔不应施加衰减")
    }

    func testGapUnderSixSecondsHasNoPenalty() {
        let eff = FUn.decayedEffectiveRSSI(effectiveRSSI: -65, elapsedSinceLastReceive: 5.5)
        XCTAssertEqual(eff, -65, "5.5s 采样间隔处于缓冲区，不应衰减")
    }

    func testShortGapDoesNotCrossLockThreshold() {
        // 用户场景复现：信号 -65，短暂 BLE 采样间隙 8s，threshold=-70
        let eff = FUn.decayedEffectiveRSSI(effectiveRSSI: -65, elapsedSinceLastReceive: 8)
        XCTAssertGreaterThanOrEqual(eff, -70, "8s 间隙不应把 -65 衰减到锁阈值 -70 以下（误锁）")
    }

    func testVeryShortGapNearlyUnchanged() {
        let eff = FUn.decayedEffectiveRSSI(effectiveRSSI: -65, elapsedSinceLastReceive: 7)
        XCTAssertEqual(eff, -65.75, accuracy: 0.01)
    }

    func testRealDepartureStillLocks() {
        // 真实离场：50s 无采样，应衰减到锁阈值 -70 以下
        let eff = FUn.decayedEffectiveRSSI(effectiveRSSI: -65, elapsedSinceLastReceive: 50)
        XCTAssertLessThan(eff, -70, "50s 无采样应仍能触发锁定")
    }

    func testPenaltyIsCapped() {
        // 封顶 20 dB：久无采样不应无限下探，避免把算法值衰减至极值
        let effShort = FUn.decayedEffectiveRSSI(effectiveRSSI: -65, elapsedSinceLastReceive: 100)
        let effLong = FUn.decayedEffectiveRSSI(effectiveRSSI: -65, elapsedSinceLastReceive: 1000)
        XCTAssertEqual(effShort, -85, "100s 无采样衰减应封顶在 20 dB")
        XCTAssertEqual(effLong, -85, "超长无采样衰减也应封顶在 20 dB")
    }

    func testCapCombinedWithVeryLowEffectiveFloor() {
        // 极低信号 + 长间隙应被 -100 截断，不产生荒谬值
        let eff = FUn.decayedEffectiveRSSI(effectiveRSSI: -95, elapsedSinceLastReceive: 500)
        XCTAssertEqual(eff, -100.0, "衰减后应被 -100 下限截断")
    }
}

// MARK: - attemptUnlock 失败预算耗尽分支（FUnlockStateMachine.swift L110-113）

/// 非 degraded 但 consecutiveFailures ≥ 3 时 attemptUnlock 的行为：
/// 不走 degraded 短路（L95），而是主动触发降级转移后拒绝（L110-113 分支）。
@MainActor
final class AttemptUnlockFailureBudgetTests: XCTestCase {

    /// 可变时间盒：闭包不能捕获 inout，以引用类型注入 nowProvider
    private final class TimeBox {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    /// 构造「状态已回 active、失败计数保留 3」的唯一公共路径：
    /// 3 次失败进入 degraded 后 resetToActive(clearFailures: false)。
    private func makeExhaustedStateMachine(box: TimeBox) -> FUnlockStateMachine {
        let sm = FUnlockStateMachine(nowProvider: { box.now })
        XCTAssertTrue(sm.attemptUnlock(), "t0: 首次解锁应成功")          // active→unlocking
        sm.handleUnlockFailure()                                        // failures=1 → cooldown
        box.now = box.now.addingTimeInterval(11)
        XCTAssertTrue(sm.attemptUnlock(), "失败冷却(10s)结束后应可重试") // cooldown→unlocking
        sm.handleUnlockFailure()                                        // failures=2 → cooldown
        box.now = box.now.addingTimeInterval(11)
        XCTAssertTrue(sm.attemptUnlock())                               // 第 3 次尝试
        sm.handleUnlockFailure()                                        // failures=3 → degraded
        sm.resetToActive(clearFailures: false)                          // active，保留 failures=3 与失败冷却
        return sm
    }

    func testAttemptUnlockWithExhaustedFailureBudgetTransitionsToDegraded() {
        let box = TimeBox(Date(timeIntervalSince1970: 1_700_000_000))
        let sm = makeExhaustedStateMachine(box: box)

        XCTAssertEqual(sm.currentState, .active)
        XCTAssertEqual(sm.consecutiveFailures, 3)

        box.now = box.now.addingTimeInterval(11)  // 失败冷却(deadline=t+32)与防抖(上次尝试+5)均已过
        let allowed = sm.attemptUnlock()
        XCTAssertFalse(allowed, "失败预算耗尽（非 degraded 状态）应拒绝解锁")
        XCTAssertEqual(sm.currentState, .degraded, "该分支应由 attemptUnlock 主动触发降级转移")
        XCTAssertEqual(sm.consecutiveFailures, 3)
    }

    func testAttemptUnlockRecoversAfterUserResetClearingFailures() {
        // 对照：同一路径但 clearFailures: true —— 用户干预后解锁能力恢复，
        // 证明上一用例的拒绝确实由保留的失败计数触发
        let box = TimeBox(Date(timeIntervalSince1970: 1_700_000_000))
        let sm = makeExhaustedStateMachine(box: box)
        sm.resetToActive(clearFailures: true)

        box.now = box.now.addingTimeInterval(11)
        XCTAssertTrue(sm.attemptUnlock(), "清零失败计数后 attemptUnlock 应恢复")
        XCTAssertEqual(sm.currentState, .unlocking)
    }
}

// MARK: - 降级通知实发验证

/// handleUnlockFailure 达到上限经 sendLocalNotification() 真实调用
/// UNUserNotificationCenter.add（identifier = degradedNotificationID）。
/// UNUserNotificationCenter 无注入 seam；授权环境下经 delivered 列表验证实发，
/// 未授权环境显式 XCTSkip（授权状态取决于宿主 FUnlock.app 的 TCC 记录）。
@MainActor
final class DegradedNotificationDeliveryTests: XCTestCase {

    func testHandleUnlockFailureDegradePathPostsLocalNotification() throws {
        let center = UNUserNotificationCenter.current()
        // 清理历史投递，避免旧残留造成假阳性
        center.removeDeliveredNotifications(withIdentifiers: [FUnlockStateMachine.degradedNotificationID])

        let sm = FUnlockStateMachine()
        sm.handleUnlockFailure()
        sm.handleUnlockFailure()
        sm.handleUnlockFailure()
        XCTAssertEqual(sm.currentState, .degraded, "前置：3 次失败进入降级路径")

        let settingsExp = expectation(description: "notification settings")
        var status: UNAuthorizationStatus?
        center.getNotificationSettings { settings in
            status = settings.authorizationStatus
            settingsExp.fulfill()
        }
        wait(for: [settingsExp], timeout: 5)
        guard let status, [.authorized, .provisional].contains(status) else {
            throw XCTSkip("通知未授权(\(String(describing: status)))，无法验证系统投递；授权环境下运行此用例")
        }

        let deliveredExp = expectation(description: "degraded notification delivered")
        center.getDeliveredNotifications { notifications in
            let ids = notifications.map(\.request.identifier)
            XCTAssertTrue(
                ids.contains(FUnlockStateMachine.degradedNotificationID),
                "降级路径应真实投递 identifier=\(FUnlockStateMachine.degradedNotificationID) 的本地通知，实际: \(ids)")
            deliveredExp.fulfill()
        }
        wait(for: [deliveredExp], timeout: 5)

        center.removeDeliveredNotifications(withIdentifiers: [FUnlockStateMachine.degradedNotificationID])
    }
}
