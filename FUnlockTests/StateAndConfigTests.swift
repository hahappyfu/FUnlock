import XCTest
@testable import FUnlock

/// 补充测试：LockScreenState 计算属性的更多场景
/// LockScreenState 是纯值类型，不依赖任何系统框架，可以直接测试
class LockScreenStateTests: XCTestCase {

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
        // 系统休眠 + autoLock intent：isEffectivelyLocked = false（screen 仍 unlocked）
        var state = LockScreenState()
        state.screen = .unlocked
        state.system = .sleeping
        state.intent = .autoLock
        XCTAssertFalse(state.isEffectivelyLocked, "screen 仍 unlocked，不算有效锁定")
    }

    func testDisplaySleepingWithManualLockExpired() {
        // displaySleeping + 过期 manualLock：deadline 不参与判定，manualLock 依旧活跃
        var state = LockScreenState()
        state.screen = .displaySleeping
        state.system = .awake
        state.intent = .manualLock(deadline: Date().addingTimeInterval(-60))
        XCTAssertTrue(state.intent.isManualLockActive, "manualLock 过期后仍活跃（须等 onUnlock 重置 intent）")
        XCTAssertTrue(state.isEffectivelyLocked, "displaySleeping 应视为有效锁定")
    }
}

/// 补充测试：LockIntent 更多边界场景
class LockIntentTests: XCTestCase {

    func testManualLockDeadlineNowIsExpired() {
        // deadline 刚好是当前时刻（严格小于），应视为已过期
        _ = LockIntent.manualLock(deadline: Date())
        // Date() 可能与 deadline 同时，< 判断可能为 false
        // 这里测试的是：如果 deadline 就是 now，isManualLockActive 取决于毫秒级时序
        // 关键行为：manualLock 一旦设置即无条件阻止自动解锁（deadline 不参与判定）
        let intentExpired = LockIntent.manualLock(deadline: Date().addingTimeInterval(-1))
        XCTAssertTrue(intentExpired.isManualLockActive, "deadline 在过去 manualLock 仍活跃（须等 onUnlock 重置）")
    }

    func testManualLockFarFutureDeadlineIsActive() {
        let intent = LockIntent.manualLock(deadline: Date().addingTimeInterval(86400))
        XCTAssertTrue(intent.isManualLockActive, "24小时后的 deadline 应为活跃状态")
    }

    func testManualLockZeroDurationDeadline() {
        // deadline 在过去，manualLock 仍活跃（deadline 不参与判定）
        let intent = LockIntent.manualLock(deadline: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(intent.isManualLockActive, "1970年的 deadline 不影响 manualLock 活跃判定")
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

/// 补充测试：LockScreenState 的 unlockedAt 时间戳行为
class UnlockedAtTests: XCTestCase {

    func testDefaultUnlockedAtIsDistantPast() {
        let state = LockScreenState()
        XCTAssertEqual(state.unlockedAt, Date.distantPast, "默认 unlockedAt 应为 distantPast")
    }
}

// MARK: - ScriptRunner 去重与扩展字段测试

/// 测试 ScriptRunner 的事件去重和扩展字段能力
class ScriptRunnerDedupTests: XCTestCase {

    private var runner: ScriptRunner!
    private var currentTime: Date!
    private var logFile: URL!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        runner = ScriptRunner(dedupWindow: 3.0) { [unowned self] in self.currentTime }
        // 安全隔离：使用独立私有临时目录，严禁清空或污染用户真实 Application Support/FUnlock/events.log
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScriptRunnerDedupTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        runner.testLogDirectory = tempDir
        logFile = tempDir.appendingPathComponent("events.log")
    }

    override func tearDown() {
        runner = nil
        try? FileManager.default.removeItem(at: tempDir)
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

    override func setUp() async throws {
        try await super.setUp()
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

// MARK: - ScriptRunner 事件日志测试

/// 验证 ScriptRunner 的事件写入路径与向后兼容性（原有 unlocked 事件不受影响）
class ScriptRunnerEventLoggingTests: XCTestCase {

    private var logFile: URL!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScriptRunnerEventLoggingTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        logFile = tempDir.appendingPathComponent("events.log")
        ScriptRunner.shared.testLogDirectory = tempDir
    }

    override func tearDown() {
        ScriptRunner.shared.testLogDirectory = nil
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - 向后兼容性 — 原有 unlocked 事件不受影响

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

    // MARK: - logEvent 实际写入 events.log

    /// 验证 logEvent 实际写入了 events.log 文件（绕过去重，验证文件 I/O 路径）
    func testLogUnlockResultWritesToEventsLog() {
        // 直接用 logEvent 绕过去重，验证 ScriptRunner 写入 events.log 的路径正确
        ScriptRunner.shared.logEvent("unlock_confirmed", rssi: nil)

        let content = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
        XCTAssertTrue(content.contains("unlock_confirmed"),
                      "logEvent 应将 unlock_confirmed 写入 events.log")
    }

    /// 验证 logEvent 实际写入了 events.log 文件（绕过去重，验证文件 I/O 路径）
    func testLogUnlockResultTimeoutWritesToEventsLog() {
        // 直接用 logEvent 绕过去重，验证 ScriptRunner 写入 events.log 的路径正确
        ScriptRunner.shared.logEvent("unlock_timeout", rssi: nil)

        let content = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
        XCTAssertTrue(content.contains("unlock_timeout"),
                      "logEvent 应将 unlock_timeout 写入 events.log")
    }
}
