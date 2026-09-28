import XCTest
@testable import FUnlock

/// 测试 FUnManager 的预备唤醒与阶梯解锁行为
@MainActor
class PreWakeStaircaseTests: XCTestCase {

    private var manager: FUnManager!

    override func setUp() async throws {
        try await super.setUp()
        let fun = FUn()
        manager = FUnManager(fun: fun)
        // 快照生产域原值并注册恢复（FUnManager 硬编码读 ConfigStore.shared），再写入测试值
        let snapshot = ConfigKeySnapshot(keys: ["wakeOnProximity", "enabled", "wakeAdvance", "preUnlockTrigger"])
        addTeardownBlock { snapshot.restore() }
        // 设置必要的 UserDefaults 开关（预备唤醒测试需要）
        ConfigStore.shared.defaults.set(true, forKey: "wakeOnProximity")
        ConfigStore.shared.defaults.set(true, forKey: "enabled")
        // 阶梯参数显式固定，保证派生阈值确定性（wake 提前 20dB、预解锁触发 10dB）
        ConfigStore.shared.defaults.set(20, forKey: "wakeAdvance")
        ConfigStore.shared.defaults.set(10, forKey: "preUnlockTrigger")
    }

    // MARK: - smoothedRSSI 集成

    func testFUnExposesSmoothedRSSIMethod() {
        let fun = FUn()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let result = fun.smoothedRSSI(-55, now: t0)
        XCTAssertEqual(result, -55.0, accuracy: 0.01,
                       "FUn.smoothedRSSI 首样本应直接初始化为输入值")
    }

    func testFUnExposesResetSmoothedRSSI() {
        let fun = FUn()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        _ = fun.smoothedRSSI(-50, now: t0)
        fun.resetSmoothedRSSI()
        XCTAssertEqual(fun.currentSmoothedRSSI, -100.0,
                       "resetSmoothedRSSI 应将平滑值重置为 -100")
        let afterReset = fun.smoothedRSSI(-60, now: t0.addingTimeInterval(1.0))
        XCTAssertEqual(afterReset, -60.0, accuracy: 0.01,
                       "重置后首次调用应重新作为首样本初始化")
    }

    // MARK: - onRSSIUpdated 预备唤醒门控

    func testOnRSSIUpdatedBelowThresholdNoPreWake() {
        // 信号 -90dBm（首样本直接初始化为 -90 < preWakeThreshold -80），不应触发预备唤醒
        manager.fun.unlockRSSI = -60
        manager.fun.lockRSSI = -80
        manager.onDisplaySleep()

        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        manager.fun.smoothedRSSI(-90, now: t0)
        manager.onRSSIUpdated(rssi: -90, active: false)

        XCTAssertFalse(manager.state.wake == .pending,
                       "低于 preWakeThreshold 时不应触发预备唤醒")
    }

    func testOnRSSIUpdatedAboveThresholdTriggersPreWake() {
        // 输入 -50dBm（> preWakeThreshold = 解锁阈值 -60 - 唤醒提前 20 = -80）
        manager.fun.unlockRSSI = -60
        manager.fun.lockRSSI = -80
        manager.onDisplaySleep()

        // 单驱动语义：bleQueue 采样经 smoothedRSSI 驱动 EMA 到 -50
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        manager.fun.smoothedRSSI(-50, now: t0)

        // onRSSIUpdated 仅读 currentSmoothedRSSI 并触发预备唤醒
        manager.onRSSIUpdated(rssi: -50, active: false)

        // smoothedRSSI 应 > preWakeThreshold（动态读取派生值）
        let current = manager.fun.currentSmoothedRSSI
        XCTAssertGreaterThan(current, Double(manager.fun.preWakeThreshold),
                             "平滑值应超过唤醒阈值（-80）")
        XCTAssertEqual(manager.state.wake, .pending,
                       "平滑值达到唤醒阈值时应触发预备唤醒进入 pending 状态")
    }

    // MARK: - onDeviceApproached 阶梯解锁门控

    func testOnDeviceApproachedBelowUnlockThresholdNoUnlock() {
        // effectiveRSSI = -75（低于 unlockStairThreshold -70，但高于 preWake -80）
        // 新语义：stair 比解锁阈值更远（-70），-75 处于 preWake 与 stair 之间，只预唤醒、不解锁
        manager.fun.unlockRSSI = -60
        manager.fun.lockRSSI = -80
        manager.fun.effectiveRSSI = -75.0
        manager.onSystemScreenLocked()

        manager.onDeviceApproached()

        // effectiveRSSI (-75) < unlockStairThreshold (-70)
        // 由于 state.screen = .locked (不是 displaySleeping)，唤醒分支也不触发
        // 关键：attemptAutoUnlock 不应被调用（因为 effectiveRSSI 未达 stair）
        if case .locked = manager.state.screen {
            // OK — screen 保持 locked，没有被解锁
        } else {
            XCTFail("effectiveRSSI < unlockStairThreshold 时 screen 应保持 locked")
        }
    }

    func testOnDeviceApproachedBelowUnlockThresholdDoesNotAttemptUnlock() {
        let snapshot = ConfigKeySnapshot(keys: ["enabled"])
        addTeardownBlock { snapshot.restore() }
        ConfigStore.shared.defaults.set(true, forKey: "enabled")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fut-\(UUID().uuidString)")
        let logger = DecisionLogger(testLogDirectory: tmp)
        let fun = FUn()
        let manager = FUnManager(fun: fun, decisionLogger: logger)
        fun.unlockRSSI = -60
        fun.lockRSSI = -80
        fun.effectiveRSSI = -65.0  // ≥ 旧 stair(-70)，但 < 解锁阈值 -60
        fun.presence = true
        manager.onSystemScreenLocked()
        manager.onDeviceApproached()

        XCTAssertTrue(manager.state.isEffectivelyLocked,
                      "信号低于解锁阈值（-60）应保持锁定")
        XCTAssertFalse(logger.events.contains { $0.category == .unlock },
                       "-70~-60 预热带不应产生任何解锁决策记录")
    }

    func testAttemptAutoUnlockBelowUnlockThresholdRecordsSignalBelowThreshold() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fut-\(UUID().uuidString)")
        let logger = DecisionLogger(testLogDirectory: tmp)
        let fun = FUn()
        let manager = FUnManager(fun: fun, decisionLogger: logger)
        fun.unlockRSSI = -60
        fun.lockRSSI = -80
        fun.effectiveRSSI = -65.0
        fun.presence = true
        manager.onSystemScreenLocked()
        manager.attemptAutoUnlock()
        XCTAssertTrue(logger.events.contains { $0.reason == .signalBelowThreshold },
                      "低于解锁阈值（-60）应被信号门控拦截并记录 signalBelowThreshold")
    }

    func testOnDeviceApproachedPreWakeWhenDisplaySleeping() {
        // effectiveRSSI = -75（> preWakeThreshold -80，且低于 stair -70），显示器休眠中
        manager.fun.unlockRSSI = -60
        manager.fun.lockRSSI = -80
        manager.fun.effectiveRSSI = -75.0
        manager.onDisplaySleep()

        manager.onDeviceApproached()

        // startWakeRetry() 同步设置 state.wake = .pending 和 state.screen = .locked(reason: .away)
        XCTAssertEqual(manager.state.wake, .pending,
                       "预备唤醒触发后 wake 应为 pending")
        if case .locked(let reason) = manager.state.screen {
            XCTAssertEqual(reason, .away,
                           "startWakeRetry 同步将 screen 设为 locked(away)")
        } else {
            XCTFail("startWakeRetry 应将 screen 从 displaySleeping 切换为 locked(away)")
        }
    }

    func testOnDeviceApproachedNoPreWakeWhenAlreadyAwake() {
        // 已经不是 displaySleeping → 不应触发预备唤醒（即使 effectiveRSSI=-75 已达 preWake）
        manager.fun.unlockRSSI = -60
        manager.fun.lockRSSI = -80
        manager.fun.effectiveRSSI = -75.0
        manager.onSystemScreenLocked()

        manager.onDeviceApproached()

        // 验证：state.wake 保持 idle
        if case .idle = manager.state.wake {
            // OK
        } else {
            XCTFail("非 displaySleeping 状态下不应触发预备唤醒，wake 应保持 idle")
        }
    }

    // MARK: - 阶梯唤醒日志验证

    func testPreWakeThresholdConstantsAreExposed() {
        let fun = FUn()
        // 验证常量通过 FUn 实例可访问（用于日志和调试）
        XCTAssertNotNil(fun.preWakeThreshold as Int)
        XCTAssertNotNil(fun.unlockStairThreshold as Int)
        XCTAssertTrue(fun.preWakeThreshold < fun.unlockStairThreshold,
                      "preWakeThreshold 应 < unlockStairThreshold")
    }

    // MARK: - 手动锁屏保护端到端

    /// 手动锁屏 → 自动解锁被 manualLock 拦截 → 手动解锁 → 恢复自动解锁能力
    func testManualLockBlocksAutoUnlockUntilManualUnlock() {
        manager.fun.unlockRSSI = -60   // stair = -70（预解锁触发量 10）
        manager.fun.lockRSSI = -80
        manager.lockBufferDuration = 0  // 跳过锁屏缓冲，直测 manualLock 门

        // 1. 手动锁屏（系统通知，非 FUnlock 自锁）
        manager.onSystemScreenLocked()
        XCTAssertTrue(manager.state.intent.isManualLockActive,
                      "手动锁屏后应进入 manualLock（自动解锁被拦截）")

        // 2. 设备靠近且信号已达阶梯解锁阈值 → 自动解锁被 manualLockActive 拦下
        manager.fun.presence = true
        manager.fun.effectiveRSSI = -65.0  // ≥ stair -70
        manager.onDeviceApproached()
        XCTAssertTrue(manager.state.intent.isManualLockActive,
                      "手动锁屏后即便信号达标也不应改变 manualLock")
        if case .locked = manager.state.screen {
            // OK — 屏幕保持锁定
        } else {
            XCTFail("manualLock 拦截下屏幕应保持锁定")
        }

        // 3. 用户手动解锁 → intent 重置，恢复自动解锁能力
        manager.onUnlock()
        XCTAssertFalse(manager.state.intent.isManualLockActive,
                       "手动解锁后应清除 manualLock，恢复自动解锁能力")

        // 4. 再次靠近 → manualLock 不应复发（后续由冷却/屏幕状态门控接管）
        manager.onDeviceApproached()
        XCTAssertFalse(manager.state.intent.isManualLockActive,
                       "手动解锁后 manualLock 不应复发")
    }

    /// FUnlock 自动锁屏不应被误标为 manualLock（否则设备回来无法自动解锁）
    func testAutoLockNotMarkedAsManualLock() {
        manager.isSelfLocking = true  // 模拟 FUnlock 自动锁屏前置标志
        manager.onSystemScreenLocked()
        XCTAssertEqual(manager.state.intent, .autoLock,
                       "FUnlock 自动锁屏不应标记为 manualLock")
    }

    // MARK: - 信号丢失复位：UI 显示一致性

    /// 失联 3 次超时 → 有效信号复位到无信号档（-100），在场标志清除，
    /// 菜单栏不得再显示冻结的旧信号值（如 -75）
    func testSignalLostResetsEffectiveRSSIAndPresence() {
        manager.fun.effectiveRSSI = -65
        manager.fun.presence = true
        manager.fun.markSignalLost()
        XCTAssertEqual(manager.fun.effectiveRSSI, -100.0,
                       "失联后有效信号应复位到无信号档（-100）")
        XCTAssertFalse(manager.fun.presence,
                       "失联后应清除在场标志")
    }
}

// MARK: - 集成测试：电源状态变化与扫描控制

/// 电源状态变化 → 扫描控制集成测试
/// 模拟系统休眠/唤醒循环对 BLE 扫描和解锁能力的影响
@MainActor
class PowerStateScanControlIntegrationTests: XCTestCase {

    private var currentTime: Date!
    private var manager: FUnManager!

    override func setUp() async throws {
        try await super.setUp()
        currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        let fun = FUn()
        manager = FUnManager(fun: fun, nowProvider: { [unowned self] in self.currentTime })
        // 加速系统唤醒的蓝牙栈等待（生产默认 1s 不变；测试注入小延迟消除硬等）
        manager.systemWakeDelay = 0.01
    }

    // MARK: - 电源状态变化 → 扫描控制

    /// 场景：系统休眠 → 唤醒 → 扫描恢复 → 解锁
    func testSystemSleepWakeScanResume() {
        manager.fun.unlockRSSI = -60
        manager.fun.lockRSSI = -80

        // 1. 系统休眠
        manager.onSystemSleep()
        XCTAssertEqual(manager.state.system, .sleeping,
                       "系统休眠后 system 应为 sleeping（休眠期间上层不触发自动解锁）")

        // 2. 系统唤醒 — 验证 system 恢复为 awake（通过 Task 异步）
        manager.onSystemWake()
        // 谓词等待：以状态本身为完成信号（注入延迟 0.01s，2s 预算裕度充足）
        let woke = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in self.manager.state.system == .awake },
            object: nil)
        wait(for: [woke], timeout: 2.0)
        XCTAssertEqual(manager.state.system, .awake,
                       "系统唤醒后 system 应为 awake")
        XCTAssertFalse(manager.state.intent.isManualLockActive,
                       "唤醒后 intent 不应停留在 manualLock")
    }

    /// 场景：显示器休眠 → 唤醒 → 状态正确传递
    func testDisplaySleepWakeCycle() {
        // 1. 显示器息屏
        manager.onDisplaySleep()
        XCTAssertEqual(manager.state.screen, .displaySleeping,
                       "显示器息屏后 screen 应为 displaySleeping")
        XCTAssertTrue(manager.state.isEffectivelyLocked,
                      "显示器息屏时应视为有效锁定")

        // 2. 显示器唤醒
        manager.onDisplayWake()
        XCTAssertEqual(manager.state.wake, .succeeded,
                       "唤醒后 wake 应为 succeeded")
        if case .locked(let reason) = manager.state.screen {
            XCTAssertEqual(reason, .away,
                           "显示器唤醒后 screen 应为 locked(away)")
        }
    }

    /// 场景：系统休眠 → 显示器息屏 → 系统唤醒 → 显示器唤醒 完整电源循环
    func testFullPowerCycle() {
        manager.fun.unlockRSSI = -60
        manager.fun.lockRSSI = -80

        // 1. 系统休眠
        manager.onSystemSleep()
        XCTAssertEqual(manager.state.system, .sleeping)

        // 2. 系统休眠时显示器息屏
        manager.onDisplaySleep()
        XCTAssertEqual(manager.state.screen, .displaySleeping)
        XCTAssertEqual(manager.state.system, .sleeping,
                       "显示器息屏时系统仍应为 sleeping")

        // 3. 系统唤醒（异步延迟生效）
        manager.onSystemWake()

        // 立即验证：system 仍为 sleeping（同步代码先于 MainActor Task 执行）
        XCTAssertEqual(manager.state.system, .sleeping,
                       "onSystemWake 立即调用后 system 仍应为 sleeping")

        // 4. 等待系统唤醒完成（谓词等待：状态本身为完成信号）
        let woke = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in self.manager.state.system == .awake },
            object: nil)
        wait(for: [woke], timeout: 2.0)
        XCTAssertEqual(manager.state.system, .awake,
                       "延迟后 system 应恢复为 awake")

        // 5. 显示器唤醒
        manager.onDisplayWake()
        XCTAssertEqual(manager.state.wake, .succeeded)
        XCTAssertFalse(manager.state.intent.isManualLockActive,
                       "完整电源循环后 intent 仍为 autoLock，应恢复解锁能力")
    }

    /// 场景：系统休眠时设备靠近不应触发解锁
    func testDeviceApproachDuringSystemSleep() {
        manager.fun.unlockRSSI = -60
        manager.fun.lockRSSI = -80
        manager.fun.presence = true
        manager.onSystemScreenLocked()

        // 系统休眠
        manager.onSystemSleep()
        XCTAssertEqual(manager.state.system, .sleeping)

        // 设备靠近 — 由于 enabled 取决于 UserDefaults，先设置；快照原值并注册恢复
        let snapshot = ConfigKeySnapshot(keys: ["enabled"])
        addTeardownBlock { snapshot.restore() }
        ConfigStore.shared.defaults.set(true, forKey: "enabled")
        manager.fun.effectiveRSSI = -45.0
        manager.onDeviceApproached()

        // 验证：休眠态未被设备靠近打破（上层据此不触发自动解锁）
        XCTAssertEqual(manager.state.system, .sleeping,
                       "系统休眠时设备靠近不应改变 system 态")
    }

    /// 场景：蓝牙状态属性验证
    /// 注意：CBCentralManager.state 为只读，无法在测试中直接模拟蓝牙开关。
    /// 验证 FUn 蓝牙相关属性在初始化后可访问且不崩溃。
    func testBluetoothPropertiesAccessibleAfterInit() {
        // 验证 FUn 的蓝牙相关属性在初始化后可正常访问
        XCTAssertNotNil(manager.fun.centralMgr, "centralMgr 不应为 nil")
        XCTAssertFalse(manager.fun.presence, "初始 presence 应为 false")

        // 验证 invalidateAllTimers 不崩溃（蓝牙关闭时也会调用）
        manager.fun.invalidateAllTimers()
        // 无崩溃即通过
    }
}
