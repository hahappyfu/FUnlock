import XCTest
@testable import FUnlock

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
}

// MARK: - 方案 A/C：解锁/锁屏效率优化测试

class LockUnlockEfficiencyTests: XCTestCase {

    // MARK: 方案 A：接近窗口判定（isNearThreshold）

    func testNearThreshold_windowEntry() {
        // threshold = -60，窗口 15dBm：[-75, -60) 内视为接近
        XCTAssertTrue(FUn.isNearThreshold(-61, threshold: -60))
        XCTAssertTrue(FUn.isNearThreshold(-74.9, threshold: -60))
        XCTAssertFalse(FUn.isNearThreshold(-75.1, threshold: -60))
        XCTAssertFalse(FUn.isNearThreshold(-60, threshold: -60), "已达阈值不算接近窗口")
        XCTAssertFalse(FUn.isNearThreshold(-59, threshold: -60), "已越过阈值不算接近窗口")
    }

    func testNearThreshold_windowEdge() {
        XCTAssertTrue(FUn.isNearThreshold(-75, threshold: -60), "窗口下边界含等号")
        XCTAssertTrue(FUn.isNearThreshold(-60.0001, threshold: -60))
    }

    func testNearThreshold_differentThresholds() {
        // lockRSSI = -80 时窗口为 [-95, -80)
        XCTAssertTrue(FUn.isNearThreshold(-85, threshold: -80))
        XCTAssertFalse(FUn.isNearThreshold(-96, threshold: -80))
        XCTAssertFalse(FUn.isNearThreshold(-80, threshold: -80))
    }

    func testIsNearThresholdUsesStairWindow() {
        // 接近窗口 = [stair - 15, stair)，与轮询加速触发一致
        XCTAssertTrue(FUn.isNearThreshold(-71.0, threshold: -70.0),
                      "-71 落在 [stair-15, stair) 窗口内")
        XCTAssertTrue(FUn.isNearThreshold(-84.9, threshold: -70.0),
                      "窗口下界含 -84.9")
        XCTAssertFalse(FUn.isNearThreshold(-70.0, threshold: -70.0),
                       "达到阈值本身不算接近窗口")
        XCTAssertFalse(FUn.isNearThreshold(-85.1, threshold: -70.0),
                       "窗口外（-85.1，下界 -85 含等号）不算接近")
    }

    // MARK: 方案 C：锁屏超时随斜率自适应（lockTimeout）

    func testLockTimeout_steepSlopeUsesFastTimeout() {
        XCTAssertEqual(FUn.lockTimeout(slope: -20), fastLockTimeout)
        XCTAssertEqual(FUn.lockTimeout(slope: -8.0), fastLockTimeout, "边界值 -8 归入快速档")
        XCTAssertEqual(FUn.lockTimeout(slope: -50), fastLockTimeout)
    }

    func testLockTimeout_mildSlopeUsesBase() {
        XCTAssertEqual(FUn.lockTimeout(slope: 0), 5.0)
        XCTAssertEqual(FUn.lockTimeout(slope: -1.0), 5.0, "边界值 -1 归入缓降档")
        XCTAssertEqual(FUn.lockTimeout(slope: 10), 5.0, "上升斜率按缓降处理")
    }

    func testLockTimeout_linearInterpolation() {
        // 修复 P0-6 插值方向：t 以快速档边界为 0（slope=-8）、缓降边界为 1（slope=-1），
        // -1 ~ -8 线性映射 5s ~ 2.5s，中点 -4.5 应为 3.75
        let mid = FUn.lockTimeout(slope: -4.5)
        XCTAssertEqual(mid, 3.75, accuracy: 0.001)
        // -2.5 处 t = (slope + 8) / 7 = 5.5/7 → fastLockTimeout + 2.5 * 5.5/7 ≈ 4.464
        // （旧实现 t = (-slope - 1) / 7 方向反了：陡降拿长超时、缓降拿短超时）
        let low = FUn.lockTimeout(slope: -2.5)
        let expected = fastLockTimeout + (5.0 - fastLockTimeout) * (5.5 / 7.0)
        XCTAssertEqual(low, expected, accuracy: 0.001)
    }

    func testLockTimeout_customBase() {
        XCTAssertEqual(FUn.lockTimeout(slope: -20, base: 8.0), fastLockTimeout)
        XCTAssertEqual(FUn.lockTimeout(slope: 0, base: 8.0), 8.0)
    }
}

/// 所测静态方法（signalBars / signalLevel / signalText）为 MainActor 隔离，整个测试类需主线程隔离
@MainActor
final class MenuBarPopoverViewTests: XCTestCase {
    func testSignalBars_bounds() {
        XCTAssertEqual(MenuBarPopoverView.signalBars(for: -95), 1)
        XCTAssertEqual(MenuBarPopoverView.signalBars(for: -100), 1)
        XCTAssertEqual(MenuBarPopoverView.signalBars(for: -91), 1)
        XCTAssertEqual(MenuBarPopoverView.signalBars(for: -82), 1, "边界 -82 归入 1 格档")
    }

    func testSignalBars_steps() {
        XCTAssertEqual(MenuBarPopoverView.signalBars(for: -81), 2)
        XCTAssertEqual(MenuBarPopoverView.signalBars(for: -75), 2, "边界 -75 归入较弱档")
        XCTAssertEqual(MenuBarPopoverView.signalBars(for: -68), 3)
        XCTAssertEqual(MenuBarPopoverView.signalBars(for: -67), 3, "边界 -67 归入 3 格档")
        XCTAssertEqual(MenuBarPopoverView.signalBars(for: -66), 4)
        XCTAssertEqual(MenuBarPopoverView.signalBars(for: -60), 4, "边界 -60 归入良好档")
        XCTAssertEqual(MenuBarPopoverView.signalBars(for: -55), 5)
    }

    func testSignalBars_strongSignalMax() {
        XCTAssertEqual(MenuBarPopoverView.signalBars(for: -30), 5)
        XCTAssertEqual(MenuBarPopoverView.signalBars(for: -59), 5, "-59 高于 -60 满格")
    }

    func testSignalLevel_buckets() {
        XCTAssertEqual(MenuBarPopoverView.signalLevel(for: -45), .excellent)
        XCTAssertEqual(MenuBarPopoverView.signalLevel(for: -60), .good)
        XCTAssertEqual(MenuBarPopoverView.signalLevel(for: -74), .good)
        XCTAssertEqual(MenuBarPopoverView.signalLevel(for: -75), .weak, "边界 -75 归入较弱档")
        XCTAssertEqual(MenuBarPopoverView.signalLevel(for: -90), .weak)
    }

    // MARK: - 信号丢失显示（与总览「无信号」判据一致：manager.rssi == nil）

    func testSignalTextWhenLostShowsDash() {
        let s = MenuBarPopoverView.signalText(effectiveRSSI: -75, hasSignal: false)
        XCTAssertEqual(s, "-- dBm", "失联后不得显示冻结的旧信号值 -75")
    }

    func testSignalTextFloorShowsDash() {
        XCTAssertEqual(MenuBarPopoverView.signalText(effectiveRSSI: -100, hasSignal: true), "-- dBm")
    }

    func testSignalTextValidShowsValue() {
        XCTAssertEqual(MenuBarPopoverView.signalText(effectiveRSSI: -75, hasSignal: true), "-75 dBm")
    }
}

// MARK: - StatsCalculator 统计口径

class StatsCalculatorTests: XCTestCase {

    // 固定时区 + 固定时刻构造全部事件与 now：消除午夜翻日 / DST 边界翻动。
    // 生产签名 todayUnlocks(_:now:calendar:) 已支持注入，无需改源码。
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }()
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func event(_ cat: DecisionCategory, _ out: DecisionOutcome, dayOffset: Int = 0) -> DecisionEvent {
        DecisionEvent(
            timestamp: calendar.date(byAdding: .day, value: dayOffset, to: now)!,
            category: cat, outcome: out, reason: nil,
            rssi: nil, device: nil, screen: nil, detail: "")
    }

    func testTodayUnlocksCountsOnlySuccess() {
        let events = [event(.unlock, .success), event(.unlock, .skipped),
                      event(.unlock, .failed), event(.lock, .success)]
        XCTAssertEqual(StatsCalculator.todayUnlocks(events, now: now, calendar: calendar), 1,
                       "今日解锁只计解锁成功")
    }

    func testTodayLocksCountsOnlySuccess() {
        let events = [event(.lock, .success), event(.lock, .skipped), event(.unlock, .success)]
        XCTAssertEqual(StatsCalculator.todayLocks(events, now: now, calendar: calendar), 1,
                       "今日锁定只计锁定成功")
    }

    func testYesterdayEventsNotCounted() {
        let events = [event(.unlock, .success, dayOffset: -1), event(.lock, .success, dayOffset: -1)]
        XCTAssertEqual(StatsCalculator.todayUnlocks(events, now: now, calendar: calendar), 0,
                       "昨日解锁不计入今日")
        XCTAssertEqual(StatsCalculator.todayLocks(events, now: now, calendar: calendar), 0,
                       "昨日锁定不计入今日")
    }

    func testThisWeekUnlocksCountsSuccess() {
        let events = [event(.unlock, .success), event(.unlock, .skipped), event(.unlock, .failed)]
        XCTAssertEqual(StatsCalculator.thisWeekUnlocks(events, now: now, calendar: calendar), 1,
                       "本周解锁只计成功")
    }
}

// MARK: - 配置文件导入导出

@MainActor
class ProfileImportExportTests: XCTestCase {
    private var manager: ProfileManager!

    override func setUp() async throws {
        try await super.setUp()
        // 快照生产域 profiles/activeProfileID 原值并注册恢复（ProfileManager 硬编码读写
        // ConfigStore.shared），再清空保证测试从空档位出发；此前 tearDown 直接 removeObject
        // 会永久抹掉用户真实档位数据
        let snapshot = ConfigKeySnapshot(keys: ["profiles", "activeProfileID"])
        addTeardownBlock { snapshot.restore() }
        ConfigStore.shared.defaults.removeObject(forKey: "profiles")
        ConfigStore.shared.defaults.removeObject(forKey: "activeProfileID")
        manager = ProfileManager()
    }

    private func profile(_ id: String, _ name: String, lock: Int) -> Profile {
        Profile(id: id, name: name, lockRSSI: lock, unlockRSSI: -60, enabled: true)
    }

    func testExportImportRoundTrip() {
        manager.addProfile(profile("a", "家", lock: -70))
        manager.addProfile(profile("b", "公司", lock: -75))
        guard let json = manager.exportJSON() else {
            return XCTFail("导出应成功")
        }
        ConfigStore.shared.defaults.removeObject(forKey: "profiles")
        ConfigStore.shared.defaults.removeObject(forKey: "activeProfileID")
        let fresh = ProfileManager()
        guard let stats = fresh.importFrom(json: json) else {
            return XCTFail("导入应成功")
        }
        XCTAssertEqual(stats.added, 2, "往返后新增 2 个配置")
        XCTAssertEqual(stats.updated, 0)
        XCTAssertEqual(stats.skipped, 0)
        XCTAssertTrue(fresh.profiles.contains { $0.id == "a" && $0.name == "家" })
        XCTAssertTrue(fresh.profiles.contains { $0.id == "b" && $0.lockRSSI == -75 })
    }

    func testImportOverwritesSameID() {
        manager.addProfile(profile("a", "家", lock: -70))
        let json = "[{\"id\":\"a\",\"name\":\"家新版\",\"lockRSSI\":-65,\"unlockRSSI\":-60,\"enabled\":true}]"
        guard let stats = manager.importFrom(json: json) else {
            return XCTFail("导入应成功")
        }
        XCTAssertEqual(stats.updated, 1, "同 id 应覆盖")
        XCTAssertEqual(manager.profiles.first { $0.id == "a" }?.lockRSSI, -65)
        XCTAssertEqual(manager.profiles.first { $0.id == "a" }?.name, "家新版")
    }

    func testImportSkipsDefault() {
        let json = "[{\"id\":\"default\",\"name\":\"恶意默认\",\"lockRSSI\":-30,\"unlockRSSI\":-20,\"enabled\":true}]"
        guard let stats = manager.importFrom(json: json) else {
            return XCTFail("导入应成功")
        }
        XCTAssertEqual(stats.skipped, 1, "default 应被跳过保护")
        XCTAssertEqual(manager.profiles.first { $0.id == "default" }?.name, Profile.default.name, "内置默认不得被覆盖")
    }

    func testImportAppendsNew() {
        manager.addProfile(profile("a", "家", lock: -70))
        let json = "[{\"id\":\"a\",\"name\":\"家\",\"lockRSSI\":-70,\"unlockRSSI\":-60,\"enabled\":true},{\"id\":\"c\",\"name\":\"新\",\"lockRSSI\":-78,\"unlockRSSI\":-55,\"enabled\":true}]"
        guard let stats = manager.importFrom(json: json) else {
            return XCTFail("导入应成功")
        }
        XCTAssertEqual(stats.updated, 1)
        XCTAssertEqual(stats.added, 1, "全新 id 应追加")
        XCTAssertTrue(manager.profiles.contains { $0.id == "c" })
    }

    func testImportInvalidJSONReturnsNil() {
        XCTAssertNil(manager.importFrom(json: "not json"))
        XCTAssertNil(manager.importFrom(json: "{\"wrong\":\"shape\"}"), "非数组结构应失败")
    }

    func testExportProducesValidJSONArray() {
        manager.addProfile(profile("a", "家", lock: -70))
        guard let json = manager.exportJSON(), let data = json.data(using: .utf8) else {
            return XCTFail("导出应成功")
        }
        let array = try? JSONSerialization.jsonObject(with: data) as? [Any]
        XCTAssertNotNil(array, "导出内容应为合法 JSON 数组")
    }
}

// MARK: - FUnManager 锁定阈值联动测试

/// 测试 FUnManager 调解解锁阈值时自动联动锁定阈值（解锁-10 迟滞，钳制到滑杆下界）
@MainActor
class FUnManagerThresholdLinkTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // setUnlockRSSI/setLockRSSI 在组件内硬编码写 ConfigStore.shared（生产域）；
        // 快照用户真实阈值（unlockRSSI/lockRSSI）并注册恢复，测试后原样还原
        let snapshot = ConfigKeySnapshot(keys: ["unlockRSSI", "lockRSSI"])
        addTeardownBlock { snapshot.restore() }
    }

    func testSetUnlockRSSIAutoAdjustsLock() {
        let fun = FUn()
        let manager = FUnManager(fun: fun)
        manager.setUnlockRSSI(-55)
        XCTAssertEqual(manager.lockRSSI, -65, "调解解锁阈值后锁定应自动设为解锁-10")
        XCTAssertEqual(fun.lockRSSI, -65)
        XCTAssertEqual(ConfigStore.shared.defaults.integer(forKey: "lockRSSI"), -65)
    }

    func testSetUnlockRSSIDisabledDoesNotAdjustLock() {
        let fun = FUn()
        let manager = FUnManager(fun: fun)
        manager.setLockRSSI(-80)
        manager.setUnlockRSSI(FUn.UNLOCK_DISABLED)  // = 1
        XCTAssertEqual(manager.lockRSSI, -80, "解锁禁用时不联动锁定")
    }

    func testSetUnlockRSSIClampToRangeMin() {
        let fun = FUn()
        let manager = FUnManager(fun: fun)
        manager.setUnlockRSSI(-95)
        // 审计修复：联动值钳制时必须保证 lock < unlock（-96 < -95），防止两阈值重合导致迟滞死循环
        XCTAssertEqual(manager.lockRSSI, -96, "联动值在下界时必须严格小于解锁阈值（-96 < -95），防止反向迟滞/死锁循环")
    }
}

// MARK: - FUn 锁冷静期（解锁后 5 秒禁止锁定）测试

/// 测试 FUn.refreshProximityGrace / isWithinLockGracePeriod 与 onUnlock 刷新联动
@MainActor
class FUnProximityGraceTests: XCTestCase {

    func testRefreshProximityGraceWindow() {
        let fun = FUn()
        XCTAssertFalse(fun.isWithinLockGracePeriod(now: Date()),
                       "默认（从未解锁）不应在冷静期")
        fun.refreshProximityGrace()
        XCTAssertTrue(fun.isWithinLockGracePeriod(now: Date()),
                      "刷新后应进入 5 秒冷静期")
        XCTAssertFalse(fun.isWithinLockGracePeriod(now: Date().addingTimeInterval(6)),
                       "超过 5 秒冷静期后应允许锁定")
    }

    func testOnUnlockRefreshesProximityGrace() {
        let fun = FUn()
        let manager = FUnManager(fun: fun)
        manager.onUnlock()
        XCTAssertTrue(fun.isWithinLockGracePeriod(now: Date()),
                      "任何解锁成功路径应刷新锁冷静基准")
    }
}

// MARK: - manualLockActive 节流测试

/// 诊断时间线 manualLockActive 事件 30 秒节流：同一 reason 30s 内只记录一次
@MainActor
final class ManualLockThrottleTests: XCTestCase {
    private var logger: DecisionLogger!
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThrottleTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        logger = DecisionLogger(testLogDirectory: tempDir)
    }

    override func tearDown() async throws {
        logger.clear()
        logger = nil
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        try await super.tearDown()
    }

    func testManualLockActiveThrottled30s() {
        let fun = FUn()
        let manager = FUnManager(fun: fun, nowProvider: { Date() }, decisionLogger: logger)

        // 通过系统锁屏通知进入手动锁屏状态（state.intent = .manualLock）
        manager.isSelfLocking = false
        manager.onSystemScreenLocked()
        // onSystemScreenLocked 设置了 lastLockTime = now，会先命中 lockBufferActive 分支；
        // 手动拨回过去，确保走到 manualLockActive 分支
        manager.lastLockTime = .distantPast
        fun.presence = true

        // 关闭 DecisionLogger 自身的 3s 同因合并，隔离验证本任务的 30s 节流层
        // （否则两次毫秒级连续调用会被 3s 合并吞掉，测试无法区分 3s 合并与 30s 节流）
        logger.coalescingWindow = 0

        // 两次 attemptAutoUnlock：第一次记录，第二次（30s 内）应被节流
        manager.attemptAutoUnlock()
        manager.attemptAutoUnlock()

        let count = logger.events.filter { $0.reason == .manualLockActive }.count
        XCTAssertEqual(count, 1, "30 秒内 manualLockActive 只记录一次")
    }
}

// MARK: - resetScanTimer 超时移除派发测试

/// 回归验证：resetScanTimer 的 Timer 超时回调必须先把 device 从 devices 原子取出，
/// 并在锁内转成不可变 DeviceSnapshot 快照后经主线程派发 removeDevice。
/// （修复背景：曾因回调内同步 removeValue 抢在 Task { @MainActor } 之前执行，
/// 导致闭包内按 uuid 取快照恒为 nil，delegate.removeDevice 永不触发）
@MainActor
final class FUnResetScanTimerTests: XCTestCase {

    /// 捕获 removeDevice 调用的 delegate spy
    private final class DelegateSpy: FUnDelegate {
        var removedDevices: [DeviceSnapshot] = []
        var onRemove: (() -> Void)?

        func newDevice(device: DeviceSnapshot) {}
        func updateDevice(device: DeviceSnapshot) {}
        func removeDevice(device: DeviceSnapshot) {
            removedDevices.append(device)
            onRemove?()
        }
        func updateRSSI(rssi: Int?, active: Bool) {}
        func updatePresence(presence: Bool, reason: String) {}
        func bluetoothPowerWarn() {}
        func onDeviceApproached() {}
    }

    func testScanTimerTimeoutDispatchesRemoveDevice() {
        let fun = FUn()
        fun.signalTimeout = 0.05  // 50ms 加速超时
        let device = Device(uuid: UUID())
        let spy = DelegateSpy()
        fun.delegate = spy
        fun.devices[device.uuid] = device

        let removed = expectation(description: "removeDevice 派发")
        spy.onRemove = { removed.fulfill() }

        fun.resetScanTimer(device: device)
        wait(for: [removed], timeout: 2.0)

        XCTAssertEqual(spy.removedDevices.count, 1, "超时应派发一次 removeDevice")
        XCTAssertEqual(spy.removedDevices.first?.uuid, device.uuid, "派发的快照应对应原设备 uuid（DeviceSnapshot 为纯值类型，不再持有堆引用）")
        XCTAssertNil(fun.devices[device.uuid], "device 应已从 devices 移除")
    }
}

// MARK: - 解锁禁用时 presence 翻转不产生假解锁事件（审计 B5 #13）

/// 回归验证：unlockRSSI == UNLOCK_DISABLED 时 checkProximity 仍按 lockRSSI 维持
/// presence 翻转语义，但不记 unlocked 事件、不派发 onDeviceApproached
/// （此前会记假 unlocked 事件并触发假解锁/假唤醒链）。
/// 经由公开入口 updateMonitoredPeripheral 驱动（checkProximity 为私有方法）。
@MainActor
final class FUnUnlockDisabledPresenceTests: XCTestCase {

    /// 捕获 presence 与 approach 派发的 delegate spy
    private final class DelegateSpy: FUnDelegate {
        var approachedCount = 0
        var presenceUpdates: [(Bool, String)] = []
        var onUpdate: (() -> Void)?

        func newDevice(device: DeviceSnapshot) {}
        func updateDevice(device: DeviceSnapshot) {}
        func removeDevice(device: DeviceSnapshot) {}
        func updateRSSI(rssi: Int?, active: Bool) {}
        func updatePresence(presence: Bool, reason: String) {
            presenceUpdates.append((presence, reason))
            onUpdate?()
        }
        func bluetoothPowerWarn() {}
        func onDeviceApproached() {
            approachedCount += 1
            onUpdate?()
        }
    }

    func testUnlockDisabledPresenceFlipDoesNotRecordUnlockedOrDispatchApproach() {
        let fun = FUn()
        fun.unlockRSSI = FUn.UNLOCK_DISABLED  // = 1，解锁禁用
        fun.lockRSSI = -80
        let spy = DelegateSpy()
        fun.delegate = spy
        let unlockedBefore = SignalDataStore.shared.samples.filter { $0.isUnlockEvent }.count

        let flipped = expectation(description: "presence 翻转派发")
        spy.onUpdate = { [weak fun] in
            if fun?.presence == true { flipped.fulfill() }
        }
        fun.updateMonitoredPeripheral(-50)  // effectiveRSSI 必然 >= -80

        wait(for: [flipped], timeout: 2.0)

        XCTAssertTrue(fun.presence, "解锁禁用时 presence 仍应按 lockRSSI 判定翻转")
        XCTAssertTrue(spy.presenceUpdates.contains { $0.0 && $0.1 == "close" },
                      "presence UI 仍应派发 close 更新")
        XCTAssertEqual(SignalDataStore.shared.samples.filter { $0.isUnlockEvent }.count,
                       unlockedBefore, "解锁禁用时不应记录 unlocked 事件（假解锁）")

        // 让可能排队的 approach 派发落定后再断言（Task { @MainActor } 派发在 runloop 上串行排空）
        let settle = expectation(description: "排空待派发 Task")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settle.fulfill() }
        wait(for: [settle], timeout: 2.0)
        XCTAssertEqual(spy.approachedCount, 0, "解锁禁用时不应派发 onDeviceApproached（假解锁）")
    }
}
