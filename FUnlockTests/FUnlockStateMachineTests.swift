// FUnlockTests/FUnlockStateMachineTests.swift
import XCTest
@testable import FUnlock

class FUnlockStateMachineTests: XCTestCase {

    func testInitialStateIsActive() async {
        let stateMachine = FUnlockStateMachine()
        let state = await stateMachine.currentState
        XCTAssertEqual(state, .active)
    }

    func testTransitionFromActiveToDisplayAsleep() async {
        let stateMachine = FUnlockStateMachine()
        await stateMachine.transition(to: .displayAsleep)
        let state = await stateMachine.currentState
        XCTAssertEqual(state, .displayAsleep)
    }

    func testAttemptUnlockWhenReadyToUnlock() async {
        let stateMachine = FUnlockStateMachine()
        // 按照合法路径：active -> displayAsleep -> preWaking -> readyToUnlock
        await stateMachine.transition(to: .displayAsleep)
        await stateMachine.transition(to: .preWaking)
        await stateMachine.transition(to: .readyToUnlock)
        let canUnlock = await stateMachine.attemptUnlock()
        XCTAssertTrue(canUnlock)
        let state = await stateMachine.currentState
        XCTAssertEqual(state, .unlocking)
    }

    func testAttemptUnlockFailsWhenInCooldown() async {
        let stateMachine = FUnlockStateMachine()
        // 先进入 unlocking 状态，然后触发失败进入 cooldown
        await stateMachine.transition(to: .displayAsleep)
        await stateMachine.transition(to: .preWaking)
        await stateMachine.transition(to: .readyToUnlock)
        _ = await stateMachine.attemptUnlock()  // 进入 unlocking
        await stateMachine.handleUnlockFailure()  // 进入 cooldown
        let canUnlock = await stateMachine.attemptUnlock()
        XCTAssertFalse(canUnlock)
    }

    func testConsecutiveFailuresTriggersDegradation() async {
        let stateMachine = FUnlockStateMachine()
        await stateMachine.transition(to: .displayAsleep)
        await stateMachine.transition(to: .preWaking)
        await stateMachine.transition(to: .readyToUnlock)
        _ = await stateMachine.attemptUnlock()  // 进入 unlocking
        await stateMachine.handleUnlockFailure()
        await stateMachine.handleUnlockFailure()
        await stateMachine.handleUnlockFailure()
        let state = await stateMachine.currentState
        XCTAssertEqual(state, .degraded)
    }
}

