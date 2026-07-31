// FUnlockTests/FUnlockStateMachineTests.swift
import XCTest
@testable import FUnlock

/// 测试 FUnlockStateMachine 的状态转换、冷却、降级逻辑
@MainActor
class FUnlockStateMachineTests: XCTestCase {

    private var sm: FUnlockStateMachine!

    override func setUp() {
        super.setUp()
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

    func testTransitionActiveToDisplayAsleep() {
        sm.transition(to: .displayAsleep)
        XCTAssertEqual(sm.currentState, .displayAsleep, "active → displayAsleep 应成功")
    }

    func testTransitionDisplayAsleepToPreWaking() {
        sm.transition(to: .displayAsleep)
        sm.transition(to: .preWaking)
        XCTAssertEqual(sm.currentState, .preWaking, "displayAsleep → preWaking 应成功")
    }

    func testTransitionPreWakingToReadyToUnlock() {
        sm.transition(to: .displayAsleep)
        sm.transition(to: .preWaking)
        sm.transition(to: .readyToUnlock)
        XCTAssertEqual(sm.currentState, .readyToUnlock, "preWaking → readyToUnlock 应成功")
    }

    func testTransitionReadyToUnlockToUnlocking() {
        sm.transition(to: .displayAsleep)
        sm.transition(to: .preWaking)
        sm.transition(to: .readyToUnlock)
        sm.transition(to: .unlocking)
        XCTAssertEqual(sm.currentState, .unlocking, "readyToUnlock → unlocking 应成功")
    }

    func testTransitionUnlockingToActive() {
        sm.transition(to: .displayAsleep)
        sm.transition(to: .preWaking)
        sm.transition(to: .readyToUnlock)
        sm.transition(to: .unlocking)
        sm.transition(to: .active)
        XCTAssertEqual(sm.currentState, .active, "unlocking → active 应成功")
    }

    func testTransitionUnlockingToCooldown() {
        sm.transition(to: .displayAsleep)
        sm.transition(to: .preWaking)
        sm.transition(to: .readyToUnlock)
        sm.transition(to: .unlocking)
        sm.transition(to: .cooldown)
        XCTAssertEqual(sm.currentState, .cooldown, "unlocking → cooldown 应成功")
    }

    func testTransitionCooldownToActive() {
        sm.transition(to: .displayAsleep)
        sm.transition(to: .preWaking)
        sm.transition(to: .readyToUnlock)
        sm.transition(to: .unlocking)
        sm.transition(to: .cooldown)
        sm.transition(to: .active)
        XCTAssertEqual(sm.currentState, .active, "cooldown → active 应成功")
    }

    func testTransitionActiveToPreWaking() {
        sm.transition(to: .preWaking)
        XCTAssertEqual(sm.currentState, .preWaking, "active → preWaking 应成功")
    }

    func testTransitionPreWakingToActive() {
        sm.transition(to: .preWaking)
        sm.transition(to: .active)
        XCTAssertEqual(sm.currentState, .active, "preWaking → active 应成功")
    }

    func testAnyStateCanTransitionToDegraded() {
        sm.transition(to: .displayAsleep)
        sm.transition(to: .degraded)
        XCTAssertEqual(sm.currentState, .degraded, "任意状态 → degraded 应成功")
    }

    func testAnyStateCanTransitionToActive() {
        sm.transition(to: .displayAsleep)
        sm.transition(to: .degraded)
        sm.transition(to: .active)
        XCTAssertEqual(sm.currentState, .active, "degraded → active 应成功（用户干预）")
    }

    func testInvalidTransitionIsRejected() {
        sm.transition(to: .displayAsleep)
        sm.transition(to: .unlocking)
        XCTAssertEqual(sm.currentState, .displayAsleep, "displayAsleep → unlocking 应被拒绝")
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
        _ = sm.attemptUnlock()
        let expectation = XCTestExpectation(description: "cooldown expires")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.1) {
            let allowed = self.sm.attemptUnlock()
            XCTAssertTrue(allowed, "冷却期过后应允许解锁")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 6.0)
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
}
