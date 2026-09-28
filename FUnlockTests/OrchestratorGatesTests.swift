// OrchestratorGatesTests.swift
// attemptAutoUnlock 门控 SKIP 矩阵、锁屏事件乱序序列、阈值漂移端到端、
// 以及 ConfigStore 全量往返之外的门控配套(Wave 2 Agent D,重派接手)。
// SKIP 可观测信号:注入隔离 DecisionLogger 后断言 logger.events 的
// (category == .unlock, reason) 记录,以及 orchestrator.unlockTask 是否被调度。

import XCTest
@testable import FUnlock

/// attemptAutoUnlock 全守卫链矩阵 + 锁屏事件乱序序列 + 阈值漂移端到端。
/// 门控顺序(语义见 UnlockOrchestrator+AutoUnlock.swift 头注释):
/// presence → unlockDisabled → signalBelowThreshold → stateMachine → lockBuffer →
/// unlockCooldown → pauseOnWiFi → manualLock → (displaySleeping 并行唤醒) →
/// wakeWithoutUnlocking → stillDisplaySleeping → screenAlreadyUnlocked → 0.3s 延迟 tryUnlock
@MainActor
class OrchestratorGatesTests: XCTestCase {

    private var currentTime: Date!
    private var logger: DecisionLogger!
    private var manager: FUnManager!

    override func setUp() async throws {
        try await super.setUp()
        currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fut-gates-\(UUID().uuidString)")
        logger = DecisionLogger(testLogDirectory: tmp)
        let fun = FUn()
        manager = FUnManager(fun: fun, nowProvider: { [unowned self] in self.currentTime },
                             decisionLogger: logger)
        fun.unlockRSSI = -60
        fun.lockRSSI = -80
    }

    override func tearDown() async throws {
        manager?.orchestrator.cancelPendingTasks()
        manager = nil
        logger = nil
        currentTime = nil
        try await super.tearDown()
    }

    // MARK: 脚手架

    /// 快照生产域指定 key 并注册恢复(FUnManager 硬编码读 ConfigStore.shared)
    private func snapshotKeys(_ keys: [String]) {
        let snapshot = ConfigKeySnapshot(keys: keys)
        addTeardownBlock { snapshot.restore() }
    }

    /// 屏幕锁定为「FUnlock 自动锁屏」语义:intent = autoLock、零锁屏缓冲,
    /// 用于隔离 manualLock / lockBuffer 门控,直测其后的分支
    private func lockAsAutoLock() {
        manager.lockBufferDuration = 0
        manager.isSelfLocking = true
        manager.onSystemScreenLocked()
    }

    private func unlockEvents(reason: DecisionReason) -> [DecisionEvent] {
        logger.events.filter { $0.category == .unlock && $0.reason == reason }
    }

    /// 宿主 GUI 会话锁定/屏保运行时 isScreenLocked 的真实查询返回 true，
    /// 「屏幕已解锁静默早退」分支不可达（环境敏感）：跳过，在未锁定会话中验证
    /// （与 DegradedNotificationDeliveryTests 的授权守卫同模式）
    private func skipIfHostSessionLocked() throws {
        let dict = CGSessionCopyCurrentDictionary() as? [String: Any]
        let sessionLocked = dict?["CGSSessionScreenIsLocked"] as? Int == 1
        let screensaverRunning = !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.ScreenSaver.Engine").isEmpty
        if sessionLocked || screensaverRunning {
            throw XCTSkip("宿主会话处于锁定/屏保状态，屏幕解锁早退用例需未锁定会话")
        }
    }

    // MARK: - SKIP 守卫矩阵(前段门控,决策记录在先,先于屏幕状态早退)

    /// 设备不在场(新实例 presence 默认 false)→ SKIP noPresence,不调度任务
    func testNoPresenceSkipsAndRecordsNoPresence() {
        lockAsAutoLock()
        manager.fun.presence = false
        manager.fun.effectiveRSSI = -50  // 信号伪造达标,presence 才是拦截点

        manager.attemptAutoUnlock()

        XCTAssertEqual(unlockEvents(reason: .noPresence).count, 1,
                       "无在场标志应记录 noPresence 决策")
        XCTAssertNil(manager.orchestrator.unlockTask, "noPresence 分支不得调度解锁任务")
        XCTAssertEqual(manager.state.screen, .locked(reason: .manual), "SKIP 不得改写屏幕状态")
    }

    /// 解锁开关关闭(unlockRSSI == UNLOCK_DISABLED 哨兵)→ SKIP unlockDisabled
    func testUnlockDisabledSkipsAndRecordsUnlockDisabled() {
        lockAsAutoLock()
        manager.fun.presence = true
        manager.fun.unlockRSSI = FUn.UNLOCK_DISABLED

        manager.attemptAutoUnlock()

        XCTAssertEqual(unlockEvents(reason: .unlockDisabled).count, 1,
                       "解锁禁用应记录 unlockDisabled 决策")
        XCTAssertNil(manager.orchestrator.unlockTask)
    }

    /// 有效信号低于解锁阈值 → SKIP signalBelowThreshold
    func testSignalBelowThresholdSkipsAndRecords() {
        lockAsAutoLock()
        manager.fun.presence = true
        manager.fun.effectiveRSSI = -70  // < unlockRSSI -60

        manager.attemptAutoUnlock()

        XCTAssertEqual(unlockEvents(reason: .signalBelowThreshold).count, 1,
                       "信号低于阈值应记录 signalBelowThreshold 决策")
        XCTAssertNil(manager.orchestrator.unlockTask)
    }

    /// 状态机注入中(.unlocking)→ canAttemptUnlock false → SKIP stateMachineBlocked
    func testStateMachineUnlockingBlocksAndRecords() {
        lockAsAutoLock()
        manager.fun.presence = true
        manager.fun.effectiveRSSI = -50
        XCTAssertTrue(manager.stateMachine.attemptUnlock(), "前置:状态机进入 unlocking")
        XCTAssertEqual(manager.stateMachine.currentState, .unlocking)

        manager.attemptAutoUnlock()

        XCTAssertEqual(unlockEvents(reason: .stateMachineBlocked).count, 1,
                       "注入在途应记录 stateMachineBlocked 决策")
        XCTAssertEqual(manager.stateMachine.currentState, .unlocking,
                       "SKIP 不得改写状态机注入中状态")
        XCTAssertNil(manager.orchestrator.unlockTask)
    }

    /// 状态机连续 3 次失败降级(.degraded)→ SKIP stateMachineBlocked
    func testStateMachineDegradedBlocksAndRecords() {
        lockAsAutoLock()
        manager.fun.presence = true
        manager.fun.effectiveRSSI = -50
        for _ in 0..<3 {
            manager.stateMachine.handleUnlockFailure()
            currentTime = currentTime.addingTimeInterval(11)  // 越过 10s 失败冷却
        }
        XCTAssertEqual(manager.stateMachine.currentState, .degraded)
        XCTAssertFalse(manager.stateMachine.canAttemptUnlock)

        manager.attemptAutoUnlock()

        XCTAssertEqual(unlockEvents(reason: .stateMachineBlocked).count, 1,
                       "降级状态应记录 stateMachineBlocked 决策")
        XCTAssertEqual(manager.stateMachine.currentState, .degraded,
                       "SKIP 不得改写降级状态")
    }

    /// 刚自动锁屏 0 秒(< 0.8s 锁屏缓冲)→ SKIP lockBufferActive
    func testLockBufferActiveSkipsAndRecords() {
        manager.lockBufferDuration = 0.8  // 保持默认缓冲
        manager.isSelfLocking = true
        manager.onSystemScreenLocked()    // lastLockTime = now,sinceLock = 0
        manager.fun.presence = true
        manager.fun.effectiveRSSI = -50

        manager.attemptAutoUnlock()

        XCTAssertEqual(unlockEvents(reason: .lockBufferActive).count, 1,
                       "锁屏缓冲期内应记录 lockBufferActive 决策")
        XCTAssertNil(manager.orchestrator.unlockTask)

        // 对照:缓冲过期后通过该门,到达延迟解锁调度
        currentTime = currentTime.addingTimeInterval(1)
        manager.attemptAutoUnlock()
        XCTAssertNotNil(manager.orchestrator.unlockTask,
                        "缓冲过期后应调度 0.3s 延迟解锁任务")
        manager.orchestrator.cancelPendingTasks()
    }

    /// 解锁成功后 5s 冷却期内 → SKIP unlockCooldownActive
    func testUnlockCooldownSkipsAndRecords() {
        lockAsAutoLock()
        manager.fun.presence = true
        manager.fun.effectiveRSSI = -50
        manager.lastUnlockTime = currentTime  // 刚解锁

        manager.attemptAutoUnlock()

        XCTAssertEqual(unlockEvents(reason: .unlockCooldownActive).count, 1,
                       "解锁冷却期内应记录 unlockCooldownActive 决策")
        XCTAssertNil(manager.orchestrator.unlockTask)
    }

    /// pauseOnWiFi 开启但目标 SSID 不匹配 → 不拦截,继续走到延迟解锁调度。
    /// 正路径(SSID 命中)依赖真实 CoreWLAN 当前 SSID(WiFiMonitor.currentSSID 直读
    /// CWWiFiClient,无注入点),无法确定性构造,故不覆盖;负路径用 UUID 拼接的
    /// 目标 SSID 保证与任何真实环境都不匹配,判定确定。
    func testWiFiPauseNonMatchingSSIDDoesNotBlock() {
        snapshotKeys(["pauseOnWiFi", "pauseOnWiFiSSID"])
        ConfigStore.shared.defaults.set(true, forKey: "pauseOnWiFi")
        ConfigStore.shared.defaults.set("no-such-ssid-\(UUID().uuidString)",
                                        forKey: "pauseOnWiFiSSID")
        lockAsAutoLock()
        manager.fun.presence = true
        manager.fun.effectiveRSSI = -50

        manager.attemptAutoUnlock()

        XCTAssertTrue(unlockEvents(reason: .wifiPaused).isEmpty,
                      "SSID 不匹配时不得记录 wifiPaused")
        XCTAssertNotNil(manager.orchestrator.unlockTask,
                        "WiFi 门不匹配应放行到延迟解锁调度")
        manager.orchestrator.cancelPendingTasks()
    }

    /// 用户手动锁屏(manualLock intent)→ SKIP manualLockActive
    func testManualLockActiveSkipsAndRecords() {
        manager.lockBufferDuration = 0
        manager.onSystemScreenLocked()  // 手动锁屏:intent = manualLock
        manager.fun.presence = true
        manager.fun.effectiveRSSI = -50

        manager.attemptAutoUnlock()

        XCTAssertEqual(unlockEvents(reason: .manualLockActive).count, 1,
                       "手动锁定期间应记录 manualLockActive 决策")
        XCTAssertTrue(manager.state.intent.isManualLockActive, "SKIP 不得改写 manualLock")
        XCTAssertNil(manager.orchestrator.unlockTask)
    }

    // MARK: - SKIP 守卫矩阵(后段门控:显示器/系统状态与屏幕早退)

    /// 系统休眠 + 显示器休眠:并行唤醒分支要求 system == .awake 不成立 →
    /// 落到 stillDisplaySleeping 出口记录 .displaySleeping,且不启动唤醒
    func testSystemSleepingWithDisplaySleepingSkipsWithoutWake() {
        snapshotKeys(["wakeOnProximity", "wakeWithoutUnlocking"])
        ConfigStore.shared.defaults.set(false, forKey: "wakeOnProximity")
        ConfigStore.shared.defaults.set(false, forKey: "wakeWithoutUnlocking")
        manager.fun.presence = true
        manager.fun.effectiveRSSI = -50
        manager.onDisplaySleep()
        manager.onSystemSleep()
        XCTAssertEqual(manager.state.system, .sleeping)

        manager.attemptAutoUnlock()

        XCTAssertEqual(unlockEvents(reason: .displaySleeping).count, 1,
                       "休眠+息屏应经 stillDisplaySleeping 出口记录 displaySleeping")
        XCTAssertEqual(manager.state.wake, .idle, "系统休眠中不得启动显示器唤醒")
        XCTAssertEqual(manager.state.system, .sleeping, "SKIP 不得改写系统电源状态")
        XCTAssertNil(manager.orchestrator.unlockTask)
    }

    /// 系统休眠 + 屏幕锁定:主链放行并调度 0.3s 延迟任务,任务内
    /// isSystemReadyForUnlock(system != .awake)拦截 → 记录 systemNotReady,不注入
    func testSystemSleepingBlocksDelayedUnlockInjection() {
        lockAsAutoLock()
        manager.fun.presence = true
        manager.fun.effectiveRSSI = -50
        manager.onSystemSleep()

        manager.attemptAutoUnlock()
        XCTAssertNotNil(manager.orchestrator.unlockTask, "前置:延迟解锁任务已调度")

        let fired = expectation(description: "delayed unlock task fires after 0.3s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { fired.fulfill() }
        wait(for: [fired], timeout: 3.0)

        XCTAssertEqual(unlockEvents(reason: .systemNotReady).count, 1,
                       "系统休眠中延迟任务应记录 systemNotReady 并终止")
        let postGateReasons: [DecisionReason] = [.noPassword, .keychainColdBoot,
                                                 .notSecureForInjection, .unlockSuccess]
        XCTAssertFalse(logger.events.contains {
            $0.category == .unlock && $0.reason.map(postGateReasons.contains) == true
        }, "systemNotReady 门控之后不得再走到密码获取/注入")
        XCTAssertEqual(manager.state.system, .sleeping)
    }

    /// 「只唤醒不解锁」开关开启(屏幕非息屏)→ SKIP wakeWithoutUnlocking
    func testWakeWithoutUnlockingSkipsAndRecords() {
        snapshotKeys(["wakeWithoutUnlocking"])
        ConfigStore.shared.defaults.set(true, forKey: "wakeWithoutUnlocking")
        lockAsAutoLock()
        manager.fun.presence = true
        manager.fun.effectiveRSSI = -50

        manager.attemptAutoUnlock()

        XCTAssertEqual(unlockEvents(reason: .wakeWithoutUnlocking).count, 1,
                       "只唤醒不解锁开启应记录 wakeWithoutUnlocking 决策")
        XCTAssertNil(manager.orchestrator.unlockTask)
    }

    /// 显示器休眠 + 未开预备唤醒 → 主链落到 stillDisplaySleeping 出口记录 .displaySleeping
    func testDisplaySleepingWithoutWakeOnProximitySkipsStillSleeping() {
        snapshotKeys(["wakeOnProximity", "wakeWithoutUnlocking"])
        ConfigStore.shared.defaults.set(false, forKey: "wakeOnProximity")
        ConfigStore.shared.defaults.set(false, forKey: "wakeWithoutUnlocking")
        manager.fun.presence = true
        manager.fun.effectiveRSSI = -50
        manager.onDisplaySleep()

        manager.attemptAutoUnlock()

        XCTAssertEqual(unlockEvents(reason: .displaySleeping).count, 1,
                       "显示器休眠中应记录 displaySleeping 决策")
        XCTAssertEqual(manager.state.wake, .idle, "未开预备唤醒不得启动唤醒")
        XCTAssertEqual(manager.state.screen, .displaySleeping, "SKIP 不得改写屏幕状态")
        XCTAssertNil(manager.orchestrator.unlockTask)
    }

    /// 显示器休眠 + 系统清醒 + 预备唤醒开启 + 信号达标:并行路径 —
    /// 启动唤醒重试(同步置 wake=pending / screen=locked(away))并调度 0.8s 并行解锁任务
    func testParallelWakePathSchedulesWakeAndDelayedUnlock() {
        snapshotKeys(["wakeOnProximity"])
        ConfigStore.shared.defaults.set(true, forKey: "wakeOnProximity")
        manager.fun.presence = true
        manager.fun.effectiveRSSI = -50
        manager.onDisplaySleep()

        manager.attemptAutoUnlock()

        XCTAssertEqual(manager.state.wake, .pending, "并行路径应同步启动唤醒重试")
        XCTAssertEqual(manager.state.screen, .locked(reason: .away),
                       "startWakeRetry 应把 screen 从 displaySleeping 切到 locked(away)")
        XCTAssertNotNil(manager.orchestrator.unlockTask, "并行路径应调度 0.8s 延迟解锁任务")
        manager.orchestrator.cancelPendingTasks()
    }

    /// 屏幕已解锁:所有决策记录之后的静默早退 — 无解锁决策、无任务调度
    func testScreenAlreadyUnlockedEarlyExitSilently() throws {
        try skipIfHostSessionLocked()
        manager.lockBufferDuration = 0
        manager.fun.presence = true
        manager.fun.effectiveRSSI = -50  // 全部门控均通过,唯一出口是 screenLocked 检查

        manager.attemptAutoUnlock()

        XCTAssertTrue(logger.events.filter { $0.category == .unlock }.isEmpty,
                      "屏幕已解锁应静默早退,不产生任何解锁决策记录(防轮询噪音)")
        XCTAssertNil(manager.orchestrator.unlockTask)
        XCTAssertEqual(manager.state.screen, .unlocked)
    }

    // MARK: - 锁屏事件乱序序列

    /// ① 解锁通知先于 onDeviceApproached:用户已手动解锁,后到的靠近事件
    /// 在冷却期内被冷却门控拦截;冷却过期后屏幕已解锁,静默早退不调度注入
    func testUnlockNotificationArrivingBeforeDeviceApproach() throws {
        try skipIfHostSessionLocked()
        snapshotKeys(["enabled"])
        ConfigStore.shared.defaults.set(true, forKey: "enabled")
        manager.lockBufferDuration = 0
        manager.isSelfLocking = true
        manager.onSystemScreenLocked()
        manager.onUnlock()  // 解锁通知先到
        XCTAssertEqual(manager.state.screen, .unlocked)
        XCTAssertEqual(manager.state.intent, .autoLock)

        // 后到的靠近事件(冷却期内):不得重复解锁
        manager.fun.presence = true
        manager.fun.effectiveRSSI = -50
        manager.onDeviceApproached()
        XCTAssertTrue(logger.events.contains { $0.category == .unlock && $0.reason == .unlockCooldownActive },
                      "解锁冷却期内后到的靠近事件应被冷却门控拦截")
        XCTAssertNil(manager.orchestrator.unlockTask)

        // 冷却过期后:屏幕已解锁 → 静默早退(无新增解锁决策)
        let unlockEventsBeforeSilentExit = logger.events.filter { $0.category == .unlock }.count
        currentTime = currentTime.addingTimeInterval(6)
        manager.onDeviceApproached()
        XCTAssertNil(manager.orchestrator.unlockTask,
                     "屏幕已解锁时靠近事件不得调度解锁任务")
        XCTAssertEqual(logger.events.filter { $0.category == .unlock }.count, unlockEventsBeforeSilentExit,
                       "屏幕已解锁时靠近事件不得产生新的解锁决策记录")
        XCTAssertEqual(manager.state.screen, .unlocked)
        XCTAssertFalse(manager.state.isEffectivelyLocked)
    }

    /// ② onSystemScreenLocked 与 onDisplaySleep 乱序:两种顺序下 manualLock
    /// 语义都成立,且锁屏后息屏不得清除 manualLock、不得触发唤醒
    func testScreenLockAndDisplaySleepOutOfOrderBothEndings() {
        // 顺序 A:先息屏,后用户锁屏 → 视为手动锁定
        manager.onDisplaySleep()
        manager.onSystemScreenLocked()
        XCTAssertEqual(manager.state.screen, .locked(reason: .manual),
                       "息屏后用户锁屏,屏幕状态应为 locked(manual)")
        XCTAssertTrue(manager.state.intent.isManualLockActive,
                      "息屏后用户锁屏应进入 manualLock")

        // 顺序 B:先用户锁屏,后息屏 → manualLock 不被息屏覆盖
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fut-seq-b-\(UUID().uuidString)")
        let loggerB = DecisionLogger(testLogDirectory: tmp)
        let funB = FUn()
        funB.unlockRSSI = -60
        funB.lockRSSI = -80
        let managerB = FUnManager(fun: funB, nowProvider: { [unowned self] in self.currentTime },
                                  decisionLogger: loggerB)
        managerB.lockBufferDuration = 0
        managerB.onSystemScreenLocked()
        managerB.onDisplaySleep()
        XCTAssertTrue(managerB.state.intent.isManualLockActive,
                      "锁屏后息屏不得清除 manualLock(否则设备回来会自动解锁)")
        XCTAssertEqual(managerB.state.screen, .displaySleeping)
        XCTAssertTrue(managerB.state.isEffectivelyLocked)

        // 乱序终态下强信号靠近:自动解锁仍被 manualLock 拦下,且不启动唤醒
        funB.presence = true
        funB.effectiveRSSI = -50
        managerB.attemptAutoUnlock()
        XCTAssertTrue(loggerB.events.contains { $0.category == .unlock && $0.reason == .manualLockActive },
                      "manualLock 乱序终态下强信号不得通过自动解锁门控")
        XCTAssertEqual(managerB.state.wake, .idle, "manualLock 拦截下不得启动显示器唤醒")
        XCTAssertNil(managerB.orchestrator.unlockTask)
        managerB.orchestrator.cancelPendingTasks()
    }

    /// ③ 手动锁定后紧跟 BLE away:屏幕非 unlocked,离开路径守卫直接返回,
    /// 不改写状态、不置自锁标志、不产生锁屏记录
    func testManualLockFollowedByDeviceLeftIsNoOp() {
        snapshotKeys(["enabled"])
        ConfigStore.shared.defaults.set(true, forKey: "enabled")
        manager.onSystemScreenLocked()
        let lockTime = manager.lastLockTime
        manager.fun.presence = false

        manager.onDeviceLeft(reason: "away")

        XCTAssertEqual(manager.state.screen, .locked(reason: .manual),
                       "手动锁定后 BLE away 不得改写屏幕状态")
        XCTAssertTrue(manager.state.intent.isManualLockActive)
        XCTAssertFalse(manager.isSelfLocking, "锁屏动作未执行,自锁标志不得置位")
        XCTAssertEqual(manager.lastLockTime, lockTime, "no-op 的 away 事件不得改写 lastLockTime")
        XCTAssertTrue(logger.events.filter { $0.category == .lock }.isEmpty,
                      "离开路径被守卫拦截,不得产生 lockedAway/lockedLost 锁屏记录")
    }

    /// ④ 蓝牙断连紧跟 onSystemScreenLocked:断连只清在场标志与信号档位,
    /// 不改写手动锁定状态;断连后残留的解锁尝试被 noPresence 门控拦截
    func testBluetoothLossRightAfterManualLock() {
        manager.onSystemScreenLocked()
        let lockTime = manager.lastLockTime
        manager.fun.presence = true
        manager.fun.effectiveRSSI = -50

        manager.fun.markSignalLost()  // 3 次 BLE 超时收敛路径

        XCTAssertFalse(manager.fun.presence, "断连应清除在场标志")
        XCTAssertEqual(manager.fun.effectiveRSSI, -100.0, "断连后有效信号应复位到无信号档")
        XCTAssertEqual(manager.state.screen, .locked(reason: .manual), "断连不得改写手动锁定状态")
        XCTAssertTrue(manager.state.intent.isManualLockActive)
        XCTAssertEqual(manager.lastLockTime, lockTime, "断连不得触发锁屏路径改写 lastLockTime")

        // 断连后伪造信号残留的解锁尝试:presence 已清除,noPresence 拦截
        manager.fun.effectiveRSSI = -50
        manager.attemptAutoUnlock()
        XCTAssertTrue(logger.events.contains { $0.category == .unlock && $0.reason == .noPresence },
                      "断连后解锁尝试必须被 noPresence 门控拦截")
        XCTAssertNil(manager.orchestrator.unlockTask)
    }

    // MARK: - 阈值漂移端到端

    /// 信号管线 → 解锁决策端到端:缓慢漂移的 RSSI 序列(-50 起每 0.5s 衰减 1dB 至 -95)
    /// 经 Kalman 管线平滑后,effectiveRSSI 滞后于原始信号地穿过「靠近 / 保持 / 离开」三区,
    /// 迟滞判定与 attemptAutoUnlock 决策在漂移全程保持正确。
    /// 深至 -95 是因为 Kalman 平滑使 effectiveRSSI 滞后原始信号数 dB,需足够深
    /// 才能保证终段 effectiveRSSI 跌破锁定阈值 -70。
    func testPipelineDriftKeepsProximityAndUnlockDecisionsCorrect() {
        let fun = manager.fun
        fun.unlockRSSI = -65
        fun.lockRSSI = -70
        manager.lockBufferDuration = 0
        manager.isSelfLocking = true
        manager.onSystemScreenLocked()  // intent = autoLock,隔离 manualLock 门控
        fun.presence = true

        var pipeline = SignalPipeline()
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        /// 复刻 FUn.processSignal 摄入语义:先追加样本再 process(P1 #5),
        /// 并按 processSignal 同款规则裁剪时间窗(保底 iqrSampleCount 个样本)
        func feed(_ raw: Int, _ i: Int) -> SignalDecision {
            let t = base.addingTimeInterval(Double(i) * 0.5)
            pipeline.latestRSSIs.append(Double(raw))
            pipeline.rssiTimestamps.append(t)
            let cutoff = t.addingTimeInterval(-pipeline.effectiveWindowDuration())
            while let first = pipeline.rssiTimestamps.first, first < cutoff,
                  pipeline.rssiTimestamps.count > pipeline.iqrSampleCount {
                pipeline.rssiTimestamps.removeFirst()
                pipeline.latestRSSIs.removeFirst()
            }
            return pipeline.process(rssi: raw, source: .connected, now: t)
        }

        // 预热:6 个稳定 -50,Kalman 收敛到场内
        var eff = -100.0
        for i in 0..<6 { eff = feed(-50, i).effectiveRSSI }
        XCTAssertGreaterThanOrEqual(eff, -65.0, "预热后管线输出应判靠近(eff=\(eff))")

        // 靠近相位:管线输出 → FUn 共享状态 → 解锁决策通过信号门并调度延迟解锁
        fun.effectiveRSSI = eff
        manager.attemptAutoUnlock()
        XCTAssertTrue(logger.events.filter {
            $0.category == .unlock && $0.reason == .signalBelowThreshold
        }.isEmpty, "靠近相位不得记录 signalBelowThreshold")
        XCTAssertNotNil(manager.orchestrator.unlockTask, "靠近相位应调度延迟解锁任务")
        manager.orchestrator.cancelPendingTasks()

        // 漂移全程:每步校验迟滞判定一致性、Kalman 平滑滞后与单调性;
        // 首次进入保持区/离开区时校验 manager 级解锁决策
        var assertedBand = false
        var assertedAway = false
        for step in 1...45 {
            let raw = -50 - step
            let decision = feed(raw, 5 + step)
            let newEff = decision.effectiveRSSI
            XCTAssertLessThan(newEff, eff, "稳定下行漂移中 effectiveRSSI 应单调不升(平滑无跳变)")
            if step <= 3 {
                XCTAssertGreaterThan(newEff, Double(raw),
                                     "下降沿 Kalman 应滞后于原始信号(漂移平滑)")
            }
            eff = newEff

            let proximity = SignalHysteresisEngine.checkProximity(
                effectiveRSSI: eff, unlockRSSI: -65, lockRSSI: -70)
            XCTAssertFalse(proximity.isClose && proximity.isAway,
                           "迟滞判定不得同时报靠近与离开(eff=\(eff))")
            XCTAssertEqual(proximity.isClose, eff >= -65.0, "isClose 应等价于 eff ≥ 解锁阈值")
            XCTAssertEqual(proximity.isAway, eff < -70.0, "isAway 应等价于 eff < 锁定阈值")

            // 保持区(-70 ≤ eff < -65):信号不足以解锁 → signalBelowThreshold
            if !assertedBand, eff < -65.0, eff >= -70.0 {
                assertedBand = true
                fun.effectiveRSSI = eff
                manager.attemptAutoUnlock()
                XCTAssertTrue(logger.events.contains {
                    $0.category == .unlock && $0.reason == .signalBelowThreshold
                }, "漂移穿过保持区时应记录 signalBelowThreshold")
                XCTAssertNil(manager.orchestrator.unlockTask,
                             "保持区信号不得调度解锁任务")
            }
            // 离开区(eff < -70):真实流程由 away 清除 presence → noPresence 拦截
            if !assertedAway, eff < -70.0 {
                assertedAway = true
                fun.effectiveRSSI = eff
                fun.markSignalLost()
                XCTAssertFalse(fun.presence, "离开相位 markSignalLost 应清除在场标志")
                manager.attemptAutoUnlock()
                XCTAssertTrue(logger.events.contains {
                    $0.category == .unlock && $0.reason == .noPresence
                }, "漂移跌破锁定阈值后,解锁尝试应被 noPresence 拦截")
            }
        }

        XCTAssertTrue(assertedBand, "漂移过程应穿过迟滞保持区(-70 ≤ eff < -65)")
        XCTAssertTrue(assertedAway, "漂移终段 effectiveRSSI 应跌破锁定阈值(eff < -70)")
        XCTAssertLessThan(eff, -70.0, "漂移终态应处于离开区(eff=\(eff))")
    }
}
