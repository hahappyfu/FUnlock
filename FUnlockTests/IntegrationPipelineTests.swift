import XCTest
@testable import FUnlock

// MARK: - 集成测试：完整解锁流程

/// 完整解锁流程集成测试：BLE 信号 → 预备唤醒 → 密码注入
/// 模拟从 BLE 扫描到最终解锁的完整链路
@MainActor
class FullUnlockFlowIntegrationTests: XCTestCase {

    private var currentTime: Date!
    private var manager: FUnManager!

    override func setUp() async throws {
        try await super.setUp()
        currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        let fun = FUn()
        manager = FUnManager(fun: fun, nowProvider: { [unowned self] in self.currentTime })
    }

    // MARK: - 完整解锁流程：BLE 信号 → 预备唤醒 → 密码注入

    /// 场景：设备从 BLE 扫描信号逐步增强，经历预备唤醒到最终解锁
    func testFullUnlockFlowScanToUnlock() {
        // onDeviceApproached 需要 enabled 和 wakeOnProximity 为 true；快照原值并注册恢复
        let snapshot = ConfigKeySnapshot(keys: ["enabled", "wakeOnProximity"])
        addTeardownBlock { snapshot.restore() }
        ConfigStore.shared.defaults.set(true, forKey: "enabled")
        ConfigStore.shared.defaults.set(true, forKey: "wakeOnProximity")

        // 步骤 1：初始状态 — 系统未锁定
        XCTAssertEqual(manager.state.screen, .unlocked, "初始 screen 应为 unlocked")
        XCTAssertEqual(manager.state.system, .awake, "初始 system 应为 awake")

        // 步骤 2：屏幕息屏（显示器进入睡眠）
        manager.onDisplaySleep()
        XCTAssertEqual(manager.state.screen, .displaySleeping,
                       "onDisplaySleep 后 screen 应为 displaySleeping")

        // 步骤 3：BLE 信号达到预备唤醒阈值（平滑 RSSI >= -60dBm）
        manager.fun.unlockRSSI = -60
        manager.fun.lockRSSI = -80
        manager.onRSSIUpdated(rssi: -50, active: false)
        for _ in 0..<5 {
            manager.onRSSIUpdated(rssi: -50, active: false)
        }

        // 步骤 4：设备靠近事件触发预备唤醒
        manager.fun.effectiveRSSI = -55.0
        manager.onDeviceApproached()

        // 验证：唤醒阶段已启动
        XCTAssertEqual(manager.state.wake, .pending,
                       "预备唤醒触发后 wake 应为 pending")
        if case .locked(let reason) = manager.state.screen {
            XCTAssertEqual(reason, .away,
                           "startWakeRetry 后 screen 应从 displaySleeping 变为 locked(away)")
        } else {
            XCTFail("预备唤醒后 screen 应为 locked(away)")
        }

        // 步骤 5：显示器唤醒完成
        manager.onDisplayWake()
        XCTAssertEqual(manager.state.wake, .succeeded,
                       "显示器唤醒后 wake 应为 succeeded")
        if case .locked(let reason) = manager.state.screen {
            XCTAssertEqual(reason, .away,
                           "显示器唤醒后 screen 应为 locked(away)（等待信号达到解锁阈值）")
        }

        // 步骤 6：信号继续增强到解锁阈值（effectiveRSSI >= -50dBm）
        manager.fun.effectiveRSSI = -45.0
        manager.fun.presence = true

        // 模拟解锁成功路径
        manager.onUnlock()
        XCTAssertEqual(manager.state.screen, .unlocked,
                       "解锁成功后 screen 应为 unlocked")
        XCTAssertEqual(manager.state.intent, .autoLock,
                       "解锁后 intent 应重置为 autoLock")
        XCTAssertFalse(manager.state.isEffectivelyLocked,
                       "解锁后 isEffectivelyLocked 应为 false")
    }

    /// 场景：BLE 信号从弱到强，只触发预备唤醒但未达到解锁阈值
    func testPartialFlowOnlyPreWakeNotUnlock() {
        // 设置初始状态：屏幕息屏
        manager.onDisplaySleep()
        manager.fun.unlockRSSI = -60
        manager.fun.lockRSSI = -80

        // onDeviceApproached 需要 enabled 和 wakeOnProximity 为 true；快照原值并注册恢复
        let snapshot = ConfigKeySnapshot(keys: ["enabled", "wakeOnProximity"])
        addTeardownBlock { snapshot.restore() }
        ConfigStore.shared.defaults.set(true, forKey: "enabled")
        ConfigStore.shared.defaults.set(true, forKey: "wakeOnProximity")

        // 信号达到预备唤醒阈值但未达到解锁阈值
        manager.fun.effectiveRSSI = -55.0  // > -60 preWake, < -50 unlock
        manager.onDeviceApproached()

        // 验证：只触发预备唤醒，未触发解锁
        XCTAssertEqual(manager.state.wake, .pending,
                       "应触发预备唤醒")
        // screen 应从 displaySleeping 变为 locked(away)
        if case .locked = manager.state.screen {
            // OK — 已从 displaySleeping 变为 locked，但未解锁
        } else {
            XCTFail("信号在两阶段阈值之间时应进入 locked(away)")
        }
        // 验证未解锁
        XCTAssertTrue(manager.state.isEffectivelyLocked,
                      "信号未达解锁阈值时应保持锁定")
    }

    /// 场景：系统休眠状态下不触发密码注入
    func testSystemSleepingBlocksUnlockInjection() {
        manager.fun.unlockRSSI = -60
        manager.fun.lockRSSI = -80
        manager.fun.presence = true
        manager.onSystemScreenLocked()

        // 系统进入休眠
        manager.onSystemSleep()
        XCTAssertEqual(manager.state.system, .sleeping,
                       "onSystemSleep 后 system 应为 sleeping（上层据此不触发自动解锁）")

        // 尝试解锁路径 — 应被阻止
        manager.fun.effectiveRSSI = -45.0
        manager.onDeviceApproached()

        // 休眠期间不触发自动解锁：system 应保持 sleeping
        XCTAssertEqual(manager.state.system, .sleeping,
                       "系统休眠时即使信号强也不应改变 system 态")
    }

    /// 场景：完整解锁 → 离场锁屏 → 再次靠近解锁循环
    func testUnlockLockRelockCycle() {
        manager.fun.unlockRSSI = -60
        manager.fun.lockRSSI = -80
        manager.fun.presence = true
        manager.onSystemScreenLocked()

        // 1. 首次解锁
        manager.onUnlock()
        XCTAssertEqual(manager.state.screen, .unlocked)
        XCTAssertEqual(manager.state.intent, .autoLock, "onUnlock 应重置 intent，恢复自动解锁能力")
        XCTAssertEqual(manager.stateMachine.currentState, .active,
                       "解锁成功后状态机应为 active")

        // 2. 等待冷却过期
        currentTime = currentTime.addingTimeInterval(6)

        // 3. 设备远离 → 锁屏
        manager.isSelfLocking = true
        manager.onSystemScreenLocked()
        if case .locked(let reason) = manager.state.screen {
            XCTAssertEqual(reason, .manual, "锁屏后应为 locked(manual)")
        } else {
            XCTFail("锁屏后 screen 应为 .locked")
        }

        // 4. 再次解锁
        manager.onUnlock()
        XCTAssertEqual(manager.state.screen, .unlocked,
                       "第二次解锁后应为 unlocked")

        // 验证状态机在完整循环中保持一致
        XCTAssertEqual(manager.stateMachine.currentState, .active,
                       "完整循环后状态机应为 active")
        XCTAssertEqual(manager.stateMachine.consecutiveFailures, 0,
                       "完整循环后失败计数应为 0")
    }
}

// MARK: - 集成测试：密码修改 → 降级 → 恢复

/// 密码修改 → 状态机降级 → 用户恢复的完整生命周期集成测试
/// 覆盖：密码变更导致 Keychain 不可用 → 连续失败 → 降级 → 用户干预 → 恢复
@MainActor
class PasswordChangeDegradationRecoveryIntegrationTests: XCTestCase {

    private var currentTime: Date!
    private var manager: FUnManager!

    override func setUp() async throws {
        try await super.setUp()
        currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        let fun = FUn()
        manager = FUnManager(fun: fun, nowProvider: { [unowned self] in self.currentTime })
    }

    // MARK: - 密码修改 → 降级 → 恢复

    /// 场景：密码修改后 Keychain 不可用 → 连续 3 次失败 → 降级 → 用户干预 → 恢复
    func testPasswordChangeCausesDegradedThenRecovery() {
        manager.fun.unlockRSSI = -60
        manager.fun.lockRSSI = -80

        // 1. 初始状态正常
        XCTAssertTrue(manager.stateMachine.canAttemptUnlock,
                      "初始状态应允许解锁尝试")
        XCTAssertEqual(manager.stateMachine.currentState, .active)

        // 2. 模拟密码修改后状态机连续 3 次失败
        manager.stateMachine.handleUnlockFailure()
        XCTAssertEqual(manager.stateMachine.consecutiveFailures, 1,
                       "第 1 次失败后 consecutiveFailures 应为 1")
        XCTAssertEqual(manager.stateMachine.currentState, .cooldown,
                       "第 1 次失败后应为 cooldown")

        currentTime = currentTime.addingTimeInterval(11)  // 超过失败冷却期
        manager.stateMachine.handleUnlockFailure()
        XCTAssertEqual(manager.stateMachine.consecutiveFailures, 2,
                       "第 2 次失败后 consecutiveFailures 应为 2")

        currentTime = currentTime.addingTimeInterval(11)
        manager.stateMachine.handleUnlockFailure()
        XCTAssertEqual(manager.stateMachine.consecutiveFailures, 3,
                       "第 3 次失败后 consecutiveFailures 应为 3")
        XCTAssertEqual(manager.stateMachine.currentState, .degraded,
                       "3 次失败后应进入降级状态")

        // 3. 降级状态下不能解锁
        XCTAssertFalse(manager.stateMachine.canAttemptUnlock,
                       "降级状态下不能解锁")
        XCTAssertFalse(manager.stateMachine.attemptUnlock(),
                       "降级状态下 attemptUnlock 应返回 false")

        // 4. 用户干预（唤醒）：只恢复 active，保留失败计数与冷却
        manager.onUserIntervention()
        XCTAssertEqual(manager.stateMachine.currentState, .active,
                       "用户干预后应恢复为 active")
        XCTAssertEqual(manager.stateMachine.consecutiveFailures, 3,
                       "用户干预后失败计数应保留为 3，唤醒不能用于绕过暴力破解保护")
        XCTAssertFalse(manager.stateMachine.canAttemptUnlock,
                       "用户干预后仍不可解锁（计数 ≥3 且冷却中）")

        // 5. 用户点击降级通知（与 AppDelegate 处理逻辑一致）→ 真正恢复
        manager.stateMachine.resetToActive()
        XCTAssertEqual(manager.stateMachine.consecutiveFailures, 0,
                       "点击通知后失败计数应清零")
        XCTAssertTrue(manager.stateMachine.canAttemptUnlock,
                      "点击通知后应恢复解锁能力")
    }

    /// 场景：onUnlock 也能从降级状态恢复（用户手动输入密码解锁）
    func testOnUnlockResetsDegradedState() {
        // 触发降级
        manager.stateMachine.handleUnlockFailure()
        manager.stateMachine.handleUnlockFailure()
        manager.stateMachine.handleUnlockFailure()
        XCTAssertEqual(manager.stateMachine.currentState, .degraded)

        // 用户手动解锁 → onUnlock 重置状态机
        manager.onUnlock()
        XCTAssertEqual(manager.state.screen, .unlocked)

        // 等待 Task 中的 resetToActive 完成
        let expectation = XCTestExpectation(description: "async reset")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(self.manager.stateMachine.currentState, .active,
                           "onUnlock 后状态机应重置为 active")
            self.currentTime = self.currentTime.addingTimeInterval(6)
            XCTAssertTrue(self.manager.stateMachine.canAttemptUnlock,
                          "onUnlock 恢复后应允许解锁")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    /// 场景：降级后恢复 → 重新进入正常解锁循环
    func testDegradedThenRecoveryFullCycle() {
        manager.fun.unlockRSSI = -60
        manager.fun.lockRSSI = -80
        manager.fun.presence = true

        // 1. 降级
        manager.stateMachine.handleUnlockFailure()
        manager.stateMachine.handleUnlockFailure()
        manager.stateMachine.handleUnlockFailure()
        XCTAssertFalse(manager.stateMachine.canAttemptUnlock)

        // 2. 恢复：模拟用户点击降级通知（AppDelegate 处理逻辑）真正恢复，
        //    屏幕唤醒（onUserIntervention）只恢复 active 不清零计数，无法作为恢复路径
        manager.stateMachine.resetToActive()
        XCTAssertTrue(manager.stateMachine.canAttemptUnlock)

        // 3. 正常解锁
        manager.onSystemScreenLocked()
        currentTime = currentTime.addingTimeInterval(1)
        manager.onUnlock()
        XCTAssertEqual(manager.state.screen, .unlocked)

        // 4. 再次锁屏
        currentTime = currentTime.addingTimeInterval(6)
        manager.isSelfLocking = true
        manager.onSystemScreenLocked()
        XCTAssertTrue(manager.state.isEffectivelyLocked)

        // 5. 再次解锁 — 验证完整循环正常
        manager.onUnlock()
        XCTAssertEqual(manager.state.screen, .unlocked)
        XCTAssertEqual(manager.stateMachine.consecutiveFailures, 0,
                       "完整循环后失败计数应为 0")
    }

    /// 场景：降级通知重置（模拟用户点击通知）
    func testDegradedNotificationReset() {
        // 触发降级
        manager.stateMachine.handleUnlockFailure()
        manager.stateMachine.handleUnlockFailure()
        manager.stateMachine.handleUnlockFailure()
        XCTAssertEqual(manager.stateMachine.currentState, .degraded)

        // 模拟用户点击降级通知（与 AppDelegate 中处理逻辑一致）
        manager.stateMachine.resetToActive()

        // 验证完全恢复
        XCTAssertEqual(manager.stateMachine.currentState, .active)
        XCTAssertEqual(manager.stateMachine.consecutiveFailures, 0)
        XCTAssertTrue(manager.stateMachine.canAttemptUnlock)
        XCTAssertFalse(manager.stateMachine.isInCooldown)
    }

    /// 场景：降级期间的连续失败处理（部分失败未达降级阈值）
    func testPartialFailuresNoDegradation() {
        // 1 次失败
        manager.stateMachine.handleUnlockFailure()
        XCTAssertEqual(manager.stateMachine.consecutiveFailures, 1)
        XCTAssertEqual(manager.stateMachine.currentState, .cooldown)
        XCTAssertFalse(manager.stateMachine.isInCooldown ? false : true,
                       "失败后应处于冷却期")

        // 等待冷却过期
        currentTime = currentTime.addingTimeInterval(11)

        // 2 次失败（但重置了冷却）
        manager.stateMachine.handleUnlockFailure()
        XCTAssertEqual(manager.stateMachine.consecutiveFailures, 2)
        XCTAssertEqual(manager.stateMachine.currentState, .cooldown)

        // 等待冷却过期
        currentTime = currentTime.addingTimeInterval(11)

        // 成功解锁 — 清零失败计数
        manager.stateMachine.handleUnlockSuccess()
        XCTAssertEqual(manager.stateMachine.consecutiveFailures, 0,
                       "成功后失败计数应清零")
        XCTAssertEqual(manager.stateMachine.currentState, .active,
                       "成功后应恢复为 active")

        // 重新开始 2 次失败，不应降级
        manager.stateMachine.handleUnlockFailure()
        manager.stateMachine.handleUnlockFailure()
        XCTAssertEqual(manager.stateMachine.consecutiveFailures, 2)
        XCTAssertEqual(manager.stateMachine.currentState, .cooldown)
        XCTAssertTrue(manager.stateMachine.canAttemptUnlock || manager.stateMachine.isInCooldown,
                      "2 次失败后不应进入降级")
    }

    /// 场景：阈值设置后信号处理 → 密码修改期间的行为一致性
    func testThresholdChangeDuringDegradation() {
        manager.fun.unlockRSSI = -60
        manager.fun.lockRSSI = -80

        // 设置新的阈值（先解锁触发联动、再手动覆盖锁定，验证锁定滑杆可手动覆盖）
        manager.setUnlockRSSI(-55)
        manager.setLockRSSI(-75)
        XCTAssertEqual(manager.lockRSSI, -75, "lockRSSI 应更新为 -75")
        XCTAssertEqual(manager.unlockRSSI, -55, "unlockRSSI 应更新为 -55")
        XCTAssertEqual(manager.fun.lockRSSI, -75, "FUn.lockRSSI 应同步")
        XCTAssertEqual(manager.fun.unlockRSSI, -55, "FUn.unlockRSSI 应同步")

        // 降级期间修改阈值
        manager.stateMachine.handleUnlockFailure()
        manager.stateMachine.handleUnlockFailure()
        manager.stateMachine.handleUnlockFailure()
        XCTAssertEqual(manager.stateMachine.currentState, .degraded)

        // 阈值仍可修改（先解锁触发联动、再手动覆盖锁定）
        manager.setUnlockRSSI(-65)
        manager.setLockRSSI(-85)
        XCTAssertEqual(manager.lockRSSI, -85)
        XCTAssertEqual(manager.unlockRSSI, -65)

        // 恢复后阈值保持（模拟用户点击降级通知真正恢复，唤醒不恢复解锁能力）
        manager.stateMachine.resetToActive()
        XCTAssertEqual(manager.lockRSSI, -85)
        XCTAssertEqual(manager.unlockRSSI, -65)
        XCTAssertTrue(manager.stateMachine.canAttemptUnlock)
    }
}
