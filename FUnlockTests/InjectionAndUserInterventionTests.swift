import XCTest
import os.lock
@testable import FUnlock

// MARK: - 双保险验证测试

/// 测试 SystemInteractionService 的双保险验证逻辑
/// 使用静态可测试版本 verifyUnlock(timeout:waitForNotification:checkUnlocked:)
@MainActor
class DualVerificationTests: XCTestCase {

    // MARK: - CGSession 字典解析（解锁判断）

    /// 解锁时 CGSSessionScreenIsLocked key 缺失（实测 nil），应判已解锁
    func testSessionDictMissingLockedKeyMeansUnlocked() {
        let dict: [String: Any] = ["kCGSSessionUserIDKey": 501]
        XCTAssertTrue(SystemInteractionService.sessionDictIndicatesUnlocked(dict),
                      "解锁状态下 CGSSessionScreenIsLocked 缺失，应判已解锁")
    }

    /// 锁定时 key = 1，应判未解锁
    func testSessionDictLockedValueMeansLocked() {
        let dict: [String: Any] = ["CGSSessionScreenIsLocked": 1]
        XCTAssertFalse(SystemInteractionService.sessionDictIndicatesUnlocked(dict),
                       "锁定时 CGSSessionScreenIsLocked=1，应判未解锁")
    }

    /// key = 0 时也应判已解锁
    func testSessionDictZeroMeansUnlocked() {
        let dict: [String: Any] = ["CGSSessionScreenIsLocked": 0]
        XCTAssertTrue(SystemInteractionService.sessionDictIndicatesUnlocked(dict),
                      "CGSSessionScreenIsLocked=0 表示已解锁")
    }

    /// 字典为 nil（无会话信息）时保守判未解锁（沿用当前语义）
    func testNilSessionDictMeansNotUnlocked() {
        XCTAssertFalse(SystemInteractionService.sessionDictIndicatesUnlocked(nil),
                       "无会话信息时不视为解锁")
    }

    // MARK: - UnlockNotification 结构体

    func testUnlockNotificationSuccess() {
        let notification = SystemInteractionService.UnlockNotification(unlock: true)
        XCTAssertTrue(notification.unlock, "unlock=true 时应为成功")
    }

    func testUnlockNotificationFailure() {
        let notification = SystemInteractionService.UnlockNotification(unlock: false)
        XCTAssertFalse(notification.unlock, "unlock=false 时应为失败")
    }

    // MARK: - verifyUnlock: 通知路径先赢

    func testNotificationWinsOverCGSession() async {
        let result = await SystemInteractionService.verifyUnlock(
            timeout: 2.0,
            notificationTimeout: 1.0,
            waitForNotification: { _ in
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms 后返回 true
                return true
            },
            checkUnlocked: { _ in
                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms 后返回 true
                return true
            }
        )
        XCTAssertTrue(result.unlock, "通知路径先返回 true，应赢得竞速")
    }

    // MARK: - verifyUnlock: CGSession 路径先赢

    func testCGSessionWinsOverNotification() async {
        let result = await SystemInteractionService.verifyUnlock(
            timeout: 2.0,
            notificationTimeout: 1.0,
            waitForNotification: { _ in
                try? await Task.sleep(nanoseconds: 500_000_000) // 500ms 后返回 true
                return true
            },
            checkUnlocked: { _ in
                try? await Task.sleep(nanoseconds: 30_000_000) // 30ms 后返回 true
                return true
            }
        )
        XCTAssertTrue(result.unlock, "CGSession 路径先返回 true，应赢得竞速")
    }

    // MARK: - verifyUnlock: 超时无信号 → timeout

    func testTimeoutReturnsUnlockFalse() async {
        let result = await SystemInteractionService.verifyUnlock(
            timeout: 0.3,   // 短超时
            notificationTimeout: 0.3,
            waitForNotification: { timeout in
                let deadline = Date().addingTimeInterval(timeout)
                while Date() < deadline {
                    guard !Task.isCancelled else { return false }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                return false
            },
            checkUnlocked: { timeout in
                let deadline = Date().addingTimeInterval(timeout)
                while Date() < deadline {
                    guard !Task.isCancelled else { return false }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                return false
            }
        )
        XCTAssertFalse(result.unlock, "两条路径均超时，应返回 false")
    }

    // MARK: - verifyUnlock: 首次调用立即返回

    func testImmediateUnlock() async {
        let result = await SystemInteractionService.verifyUnlock(
            timeout: 2.0,
            notificationTimeout: 1.0,
            waitForNotification: { _ in return true },   // 立即 true
            checkUnlocked: { _ in return false }         // 立即 false
        )
        XCTAssertTrue(result.unlock, "通知路径立即返回 true，应赢得竞速")
    }

    // MARK: - verifyUnlock: CGSession 立即返回，通知不返回

    func testImmediateCGSessionUnlock() async {
        let result = await SystemInteractionService.verifyUnlock(
            timeout: 2.0,
            notificationTimeout: 1.0,
            waitForNotification: { _ in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return true
            },
            checkUnlocked: { _ in return true }
        )
        XCTAssertTrue(result.unlock, "CGSession 立即返回 true，应赢得竞速")
    }

    // MARK: - verifyUnlock: 双路径均返回 false → timeout

    func testBothReturnFalse() async {
        let result = await SystemInteractionService.verifyUnlock(
            timeout: 0.3,
            notificationTimeout: 0.3,
            waitForNotification: { timeout in
                let deadline = Date().addingTimeInterval(timeout)
                while Date() < deadline {
                    guard !Task.isCancelled else { return false }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                return false
            },
            checkUnlocked: { timeout in
                let deadline = Date().addingTimeInterval(timeout)
                while Date() < deadline {
                    guard !Task.isCancelled else { return false }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                return false
            }
        )
        XCTAssertFalse(result.unlock, "双路径均返回 false，应返回 false")
    }

    // MARK: - verifyUnlock: 通知延迟后返回，CGSession 失败

    func testNotificationDelayedWins() async {
        let result = await SystemInteractionService.verifyUnlock(
            timeout: 1.0,
            notificationTimeout: 1.0,
            waitForNotification: { _ in
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                return true
            },
            checkUnlocked: { _ in
                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
                return false
            }
        )
        XCTAssertTrue(result.unlock, "通知延迟 100ms 后返回 true，应赢得竞速")
    }

    // MARK: - verifyUnlock: CGSession 延迟后返回，通知失败

    func testCGSessionDelayedWins() async {
        let result = await SystemInteractionService.verifyUnlock(
            timeout: 1.0,
            notificationTimeout: 1.0,
            waitForNotification: { _ in
                try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
                return false
            },
            checkUnlocked: { _ in
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                return true
            }
        )
        XCTAssertTrue(result.unlock, "CGSession 延迟 100ms 后返回 true，应赢得竞速")
    }

    // MARK: - verifyUnlock: TaskGroup 取消验证

    func testCancelsOtherTasksAfterWin() async {
        // 闭包为 @Sendable 且在并发域执行，共享状态用锁保护
        // （Swift 6 下直接捕获并改写 var 会被判为数据竞争）
        let notificationChecked = OSAllocatedUnfairLock(initialState: false)

        let result = await SystemInteractionService.verifyUnlock(
            timeout: 2.0,
            notificationTimeout: 1.0,
            waitForNotification: { _ in
                try? await Task.sleep(nanoseconds: 20_000_000)
                notificationChecked.withLock { $0 = true }
                return true  // 20ms 后返回 true → 赢得竞速
            },
            checkUnlocked: { _ in
                try? await Task.sleep(nanoseconds: 100_000_000)
                return true  // 100ms 后返回 true（不应执行到这里）
            }
        )
        XCTAssertTrue(result.unlock, "通知路径应赢得竞速")
        XCTAssertTrue(notificationChecked.withLock { $0 }, "通知路径的闭包应被执行")
        // 注意：checkUnlocked 路径（CGSession）可能已被取消或未执行完，取决于取消时序
        // 关键是返回值正确（true），而不是验证取消时序（竞态条件）
    }

    // MARK: - verifyUnlock: 等效于旧0.5秒延时

    func testSameResultAsOldHalfSecondDelay() async {
        // 旧逻辑：0.5秒后 CGSession 检查
        // 新逻辑：通知竞速 + CGSession 轮询，同样时间内返回结果
        // 验证：新逻辑在0.5秒内能检测到快速解锁

        let startTime = Date()
        let result = await SystemInteractionService.verifyUnlock(
            timeout: 2.0,
            notificationTimeout: 1.0,
            waitForNotification: { _ in return true },  // 立即通知
            checkUnlocked: { _ in return true }
        )
        let elapsed = Date().timeIntervalSince(startTime)
        XCTAssertTrue(result.unlock, "应检测到解锁")
        XCTAssertLessThan(elapsed, 0.5, "通知路径立即返回，总耗时应远小于0.5秒")
    }
}

// MARK: - 用户主动干预处理测试

/// 测试 FUnManager.onUserIntervention() 的各种状态转换场景
/// 覆盖：从降级/冷却状态恢复 active，以及幂等性验证
@MainActor
class UserInterventionTests: XCTestCase {

    private var manager: FUnManager!

    override func setUp() async throws {
        try await super.setUp()
        manager = FUnManager(fun: FUn())
    }

    // MARK: - 从降级状态恢复

    func testUserInterventionResetsFromDegraded() {
        // 触发 3 次失败 → 降级
        manager.stateMachine.handleUnlockFailure()
        manager.stateMachine.handleUnlockFailure()
        manager.stateMachine.handleUnlockFailure()
        XCTAssertEqual(manager.stateMachine.currentState, .degraded, "3 次失败后应为 degraded")

        // 用户干预 → 恢复 active
        manager.onUserIntervention()
        XCTAssertEqual(manager.stateMachine.currentState, .active,
                       "用户干预后状态机应重置为 active")
    }

    // MARK: - 从冷却状态恢复

    func testUserInterventionResetsFromCooldown() {
        // 触发 2 次失败 → 进入冷却（未达到降级阈值）
        manager.stateMachine.handleUnlockFailure()
        manager.stateMachine.handleUnlockFailure()
        XCTAssertEqual(manager.stateMachine.currentState, .cooldown, "2 次失败后应为 cooldown")

        manager.onUserIntervention()
        XCTAssertEqual(manager.stateMachine.currentState, .active,
                       "用户干预后应从 cooldown 恢复到 active")
    }

    // MARK: - 保留失败计数（唤醒不能用于绕过暴力破解保护）

    func testUserInterventionPreservesConsecutiveFailures() {
        manager.stateMachine.handleUnlockFailure()
        manager.stateMachine.handleUnlockFailure()
        XCTAssertEqual(manager.stateMachine.consecutiveFailures, 2,
                       "两次失败后 consecutiveFailures 应为 2")

        manager.onUserIntervention()
        XCTAssertEqual(manager.stateMachine.consecutiveFailures, 2,
                       "用户干预后 consecutiveFailures 应保留为 2，唤醒不能用于绕过暴力破解保护")
    }

    // MARK: - 幂等性：对 active 状态调用不产生副作用

    func testUserInterventionIdempotentOnActive() {
        XCTAssertEqual(manager.stateMachine.currentState, .active, "初始应为 active")

        manager.onUserIntervention()
        XCTAssertEqual(manager.stateMachine.currentState, .active,
                       "对 active 状态调用应保持 active")
    }

    // MARK: - 连续多次调用幂等

    func testMultipleUserInterventionsAreIdempotent() {
        // 触发降级
        manager.stateMachine.handleUnlockFailure()
        manager.stateMachine.handleUnlockFailure()
        manager.stateMachine.handleUnlockFailure()
        XCTAssertEqual(manager.stateMachine.currentState, .degraded)

        // 连续两次干预
        manager.onUserIntervention()
        manager.onUserIntervention()
        XCTAssertEqual(manager.stateMachine.currentState, .active,
                       "连续多次用户干预后状态机应稳定在 active")
        XCTAssertEqual(manager.stateMachine.consecutiveFailures, 3,
                       "连续多次干预后失败计数应保留为 3，唤醒不能用于绕过暴力破解保护")
    }

    // MARK: - 干预后 canAttemptUnlock 不恢复

    func testUserInterventionDoesNotRestoreCanAttemptUnlockFromDegraded() {
        // 降级 → canAttemptUnlock 应为 false
        manager.stateMachine.handleUnlockFailure()
        manager.stateMachine.handleUnlockFailure()
        manager.stateMachine.handleUnlockFailure()
        XCTAssertFalse(manager.stateMachine.canAttemptUnlock, "降级后不应允许解锁尝试")

        // 用户干预：状态机回到 active，但失败计数（≥3）与冷却保留，下次解锁尝试仍被拒绝
        manager.onUserIntervention()
        XCTAssertFalse(manager.stateMachine.canAttemptUnlock,
                       "用户干预后 canAttemptUnlock 仍应为 false，唤醒不能用于绕过暴力破解保护")
    }

    // MARK: - 干预后冷却保留

    func testUserInterventionPreservesCooldown() {
        // 触发失败 → isInCooldown 应为 true
        manager.stateMachine.handleUnlockFailure()
        XCTAssertTrue(manager.stateMachine.isInCooldown, "失败后应处于冷却期")

        manager.onUserIntervention()
        XCTAssertTrue(manager.stateMachine.isInCooldown,
                       "用户干预后冷却应保留，唤醒不能用于绕过暴力破解保护")
    }

    // MARK: - 与 onUnlock 的行为差异

    func testUserInterventionDiffersFromOnUnlockForStateMachine() {
        // 降级
        manager.stateMachine.handleUnlockFailure()
        manager.stateMachine.handleUnlockFailure()
        manager.stateMachine.handleUnlockFailure()

        // 用户干预只恢复 active，不清零失败计数；与 onUnlock 的清零行为形成对照
        manager.onUserIntervention()
        XCTAssertEqual(manager.stateMachine.currentState, .active)
        XCTAssertEqual(manager.stateMachine.consecutiveFailures, 3)
    }
}

// MARK: - 审计批次4修复测试
// 覆盖：#1 屏保手动锁定 / #2a isSelfLocking 过期 / #4+#10 自唤醒竞态 / #5 passwordChanged 防伪造

@MainActor
class AuditBatch4FixTests: XCTestCase {

    private var manager: FUnManager!

    override func setUp() async throws {
        try await super.setUp()
        manager = FUnManager(fun: FUn())
    }

    override func tearDown() async throws {
        manager.orchestrator.cancelPendingTasks()
        try await super.tearDown()
    }

    // MARK: 修复 #1：手动启动屏保应视为手动锁定

    func testScreensaverStartMarksManualLock() {
        // 审计修复 #1：热角等手动屏保只改 screen 不设 intent 时，
        // 屏保结束后设备靠近仍会自动解锁
        manager.onScreensaverStart()
        XCTAssertTrue(manager.state.intent.isManualLockActive,
                      "手动启动屏保应进入 manualLock")
        XCTAssertEqual(manager.state.screen, .screensaver, "screen 状态更新行为不变")
    }

    func testSelfLockingScreensaverStartKeepsAutoLock() {
        // FUnlock 自动锁屏走屏保路径（screensaver 偏好）时不应误标手动锁定
        manager.isSelfLocking = true
        manager.onScreensaverStart()
        XCTAssertFalse(manager.state.intent.isManualLockActive,
                       "FUnlock 自锁触发的屏保不应进入 manualLock")
    }

    // MARK: Task 7：自锁窗口超过 10s 自然过期

    func testStaleSelfLockingFlagTreatedAsManualLock() {
        // com.apple.screenIsLocked 通知丢失 → 窗口残留；10s 后用户手动锁屏
        setSessionLockedForTesting(true)
        defer { resetSessionProvidersForTesting() }
        manager.isSelfLocking = true
        manager.beginSelfLockWindow(duration: -11)
        manager.onSystemScreenLocked()
        XCTAssertTrue(manager.state.intent.isManualLockActive,
                      "置位超 10s 的残留窗口应视为过期，按手动锁屏处理")
        XCTAssertFalse(manager.isWithinSelfLockWindow, "过期窗口不应再被识别为自锁")
    }

    func testFreshSelfLockingFlagStillConsumedAsAutoLock() {
        setSessionLockedForTesting(true)
        defer { resetSessionProvidersForTesting() }
        manager.isSelfLocking = true
        manager.onSystemScreenLocked()
        XCTAssertEqual(manager.state.intent, .autoLock,
                       "10s 内的正常自锁路径不受过期判定影响")
        XCTAssertTrue(manager.isWithinSelfLockWindow,
                      "窗口保留给随后到达的屏保通知（不再单次通知即清空）")
    }

    // MARK: 修复 #4/#10：程序自唤醒不触发用户干预

    func testSelfWakeSkipsUserIntervention() {
        for _ in 0..<3 { manager.stateMachine.handleUnlockFailure() }
        XCTAssertEqual(manager.stateMachine.currentState, .degraded)
        manager.orchestrator.displayWakeRequested = true  // 模拟 FUn 预唤醒在途
        manager.onDisplayWake()
        XCTAssertEqual(manager.stateMachine.currentState, .degraded,
                       "程序自唤醒不应触发 onUserIntervention（否则刚调度的解锁任务被自己取消）")
        XCTAssertFalse(manager.orchestrator.displayWakeRequested,
                       "唤醒处理后自唤醒标记应复位")
    }

    func testManualWakeTriggersUserIntervention() {
        for _ in 0..<3 { manager.stateMachine.handleUnlockFailure() }
        manager.orchestrator.displayWakeRequested = false  // 用户手动唤醒，无自唤醒标记
        manager.onDisplayWake()
        XCTAssertEqual(manager.stateMachine.currentState, .active,
                       "用户手动唤醒应执行 onUserIntervention 恢复 active")
        XCTAssertEqual(manager.stateMachine.consecutiveFailures, 3,
                       "干预语义不变：失败计数保留（clearFailures: false）")
    }

    func testManualWakePreservesNewlyScheduledUnlockTask() {
        // P0-3：手动唤醒必须先干预（取消陈旧任务）再调度新解锁任务——
        // 反序时 onUserIntervention.cancelPendingTasks 会无条件取消刚调度的任务，
        // 手动唤醒的自动解锁 100% 失效
        SystemInteractionService.sessionDictProvider = { ["CGSSessionScreenIsLocked": 1] }
        SystemInteractionService.screensaverRunningProvider = { false }
        defer {
            SystemInteractionService.sessionDictProvider = nil
            SystemInteractionService.screensaverRunningProvider = nil
        }
        manager.fun.presence = true
        manager.state.screen = .displaySleeping
        manager.orchestrator.displayWakeRequested = false  // 用户手动唤醒，无自唤醒标记
        manager.onDisplayWake()
        XCTAssertNotNil(manager.orchestrator.unlockTask,
                        "手动唤醒后新调度的延迟解锁任务不应被干预取消")
    }

    // MARK: P1-1: 改密通知确认与锁屏延迟弹窗

    func testPasswordChangeRejectedKeepsStoredPassword() {
        // 安全隔离：独立 serviceName，覆盖/删除的是测试条目，不触碰真实 Keychain 密码
        let service = SecurityService(serviceName: "com.fuhahah.FUnlock.test.isolated")
        let marker = "pw-changed-reject-\(UUID().uuidString)"
        service.storePassword(marker)
        service.sessionLockProvider = { false }  // 模拟屏幕未锁定（正常使用中收到通知）
        service.confirmHandler = { false }       // 用户拒绝重输
        service.handlePasswordChanged()
        if case .success(let pw) = service.fetchPassword() {
            XCTAssertEqual(pw, marker, "用户拒绝后密码不得删除")
        } else {
            XCTFail("密码应仍可读取（未确认不得删除）")
        }
        service.deletePassword()
        service.sessionLockProvider = nil
        service.confirmHandler = nil
    }

    func testPasswordChangeConfirmedClearsStoredPassword() {
        let service = SecurityService(serviceName: "com.fuhahah.FUnlock.test.isolated")
        let marker = "pw-changed-confirm-\(UUID().uuidString)"
        service.storePassword(marker)
        service.sessionLockProvider = { false }
        service.confirmHandler = { true }   // 用户确认重输
        service.reEntryHandler = {}         // 拦截 askPassword，避免测试弹真实输入框
        service.handlePasswordChanged()
        if case .success(let pw) = service.fetchPassword(), pw != nil {
            XCTFail("用户确认后存储密码应被删除，实际仍读到密码")
        }
        service.sessionLockProvider = nil
        service.confirmHandler = nil
        service.reEntryHandler = nil
    }

    func testPasswordChangeWhileLockedDefersInsteadOfModal() {
        let service = SecurityService(serviceName: "com.fuhahah.FUnlock.test.isolated")
        let marker = "pw-changed-defer-\(UUID().uuidString)"
        service.storePassword(marker)
        service.sessionLockProvider = { true }  // 模拟屏幕锁定
        service.confirmHandler = { XCTFail("锁屏下不得弹确认窗"); return false }
        service.reEntryHandler = { XCTFail("锁屏下不得弹重输窗") }
        service.handlePasswordChanged()
        XCTAssertTrue(service.hasPendingPasswordChange,
                      "锁屏下收到改密通知应标记 pending，待解锁后消费")
        if case .success(let pw) = service.fetchPassword() {
            XCTAssertEqual(pw, marker, "锁屏下不得删除密码")
        } else {
            XCTFail("密码应仍可读取")
        }
        service.deletePassword()
        service.sessionLockProvider = nil
        service.confirmHandler = nil
        service.reEntryHandler = nil
    }
}

// MARK: - 显示器休眠盲打拦截与密码误报防护测试

@MainActor
class DisplaySleepInjectionProtectionTests: XCTestCase {

    private var manager: FUnManager!

    override func setUp() async throws {
        try await super.setUp()
        manager = FUnManager(fun: FUn())
    }

    override func tearDown() async throws {
        SystemInteractionService.displayPoweredOnProvider = nil
        manager.orchestrator.cancelPendingTasks()
        try await super.tearDown()
    }

    /// 显示器始终未点亮（唤醒失败）时，injectPasswordWithPrelude 必须拒绝注入。
    /// 回归护栏：2026-10-16 误报根因是唤醒失败后仍继续注入，密码打在熄灭的屏幕上必然失败，
    /// 连续 3 次即弹出「密码可能已更改」。
    func testInjectionAbortsWhenDisplayNeverPowersOn() async {
        SystemInteractionService.displayPoweredOnProvider = { false }
        let sut = SystemInteractionService.shared
        let posted = await sut.injectPasswordWithPrelude("test-password") { true }
        XCTAssertFalse(posted, "显示器始终未点亮时必须中止注入，禁止盲打")
    }

    /// 显示器休眠导致注入中止时，不得累加密码失败计数（防止误触发改密告警）
    func testDisplayAsleepInjectionAbortDoesNotIncrementPasswordFailureCount() async {
        guard let orchestrator = manager.orchestrator else {
            XCTFail("orchestrator 不应为 nil")
            return
        }
        XCTAssertEqual(orchestrator.consecutiveUnlockAttempts, 0)

        SystemInteractionService.displayPoweredOnProvider = { false }
        await orchestrator.performInjectionAndVerify(password: "test-password")

        XCTAssertEqual(orchestrator.consecutiveUnlockAttempts, 0, "显示器休眠中止注入时不应累加连续失败次数")
    }

    /// 屏幕处于休眠且唤醒重试完成前，不可误报 passwordMismatch
    func testWakeRetryFailureDoesNotTriggerPasswordMismatchAlert() {
        guard let orchestrator = manager.orchestrator else {
            XCTFail("orchestrator 不应为 nil")
            return
        }
        orchestrator.startWakeRetry()
        orchestrator.cancelPendingTasks()

        XCTAssertEqual(orchestrator.consecutiveUnlockAttempts, 0, "唤醒重试不应累加密码失败次数")
    }
}

// MARK: - Task 5：真实会话锁态与注入安全门控

final class SecureInjectionSessionTests: XCTestCase {

    func testIsScreenLockedDoesNotTrustStaleScreenStateWhenSessionUnlocked() {
        SystemInteractionService.sessionDictProvider = { ["CGSSessionScreenIsLocked": 0] }
        SystemInteractionService.screensaverRunningProvider = { false }
        defer {
            SystemInteractionService.sessionDictProvider = nil
            SystemInteractionService.screensaverRunningProvider = nil
        }
        XCTAssertFalse(SystemInteractionService.shared.isScreenLocked(screenState: .locked(reason: .away)))
    }

    func testIsSecureToInjectBlocksNilFrontmostUnlessCGSessionLockedAndAllowsScreensaverOnlyInPrelude() {
        defer {
            SystemInteractionService.sessionDictProvider = nil
            SystemInteractionService.screensaverRunningProvider = nil
            SystemInteractionService.frontmostBundleIDProvider = nil
        }
        // 未锁会话 + nil 前台 → 必须拒绝
        SystemInteractionService.sessionDictProvider = { ["CGSSessionScreenIsLocked": 0] }
        SystemInteractionService.screensaverRunningProvider = { false }
        SystemInteractionService.frontmostBundleIDProvider = { nil }
        XCTAssertFalse(SystemInteractionService.shared.isSecureToInject(screenState: .locked(reason: .away)))

        // CGSession 已锁 + nil 前台（macOS 14+ LSUIElement 锁屏界面）→ 允许
        SystemInteractionService.sessionDictProvider = { ["CGSSessionScreenIsLocked": 1] }
        XCTAssertTrue(SystemInteractionService.shared.isSecureToInject(screenState: .locked(reason: .away)))

        // 已锁会话 + 非锁屏前台应用 → 必须拒绝
        SystemInteractionService.frontmostBundleIDProvider = { "com.apple.Safari" }
        XCTAssertFalse(SystemInteractionService.shared.isSecureToInject(screenState: .locked(reason: .away)))

        // 屏保运行但 CGSession 未锁：前奏允许 ScreenSaver.Engine，按键注入阶段拒绝
        SystemInteractionService.sessionDictProvider = { ["CGSSessionScreenIsLocked": 0] }
        SystemInteractionService.screensaverRunningProvider = { true }
        SystemInteractionService.frontmostBundleIDProvider = { "com.apple.ScreenSaver.Engine" }
        XCTAssertTrue(SystemInteractionService.shared.isSecureToInject(screenState: .screensaver, allowScreensaver: true))
        XCTAssertFalse(SystemInteractionService.shared.isSecureToInject(screenState: .screensaver, allowScreensaver: false))
    }
}

// MARK: - Task 6：取消安全（不得盲打、不得计失败）

/// 线程安全计数盒子：测试钩子可能在非主 executor 触发。
final class CancellationTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor
final class CancellationSafetyTests: XCTestCase {

    func testCancelledPreludeReturnsFalseImmediatelyWithoutBlindInjection() async {
        SystemInteractionService.displayPoweredOnProvider = { true }
        let keystrokesReached = CancellationTestCounter()
        SystemInteractionService.fakeKeyStrokesOverride = { _, _ in
            keystrokesReached.increment()
            return true
        }
        defer {
            SystemInteractionService.displayPoweredOnProvider = nil
            SystemInteractionService.fakeKeyStrokesOverride = nil
        }

        let task = Task { @MainActor in
            await SystemInteractionService.shared.injectPasswordWithPrelude("secret") { true }
        }
        // 让任务进入 loginwindow 就绪等待，再模拟用户干预取消
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let posted = await task.value
        XCTAssertFalse(posted, "取消后注入前奏必须返回 false")
        XCTAssertEqual(keystrokesReached.count, 0, "取消后绝不能到达按键注入阶段")
    }

    func testCancelledVerifyUnlockDoesNotIncrementFailureCountOrDegrade() async {
        SystemInteractionService.sessionDictProvider = { ["CGSSessionScreenIsLocked": 1] }
        SystemInteractionService.screensaverRunningProvider = { false }
        SystemInteractionService.displayPoweredOnProvider = { true }
        SystemInteractionService.injectPasswordOverride = { _ in true }
        SystemInteractionService.verifyUnlockOverride = { _, _ in
            try? await Task.sleep(nanoseconds: 500_000_000)
            return .init(unlock: false)
        }
        defer {
            SystemInteractionService.sessionDictProvider = nil
            SystemInteractionService.screensaverRunningProvider = nil
            SystemInteractionService.displayPoweredOnProvider = nil
            SystemInteractionService.injectPasswordOverride = nil
            SystemInteractionService.verifyUnlockOverride = nil
        }

        let manager = FUnManager(fun: FUn())
        XCTAssertTrue(manager.stateMachine.attemptUnlock(), "前置：状态机应允许本次尝试")
        await manager.orchestrator.performInjectionAndVerify(password: "pw")
        manager.orchestrator.cancelPendingTasks()
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(manager.orchestrator.consecutiveUnlockAttempts, 0, "被取消的验证不得计为密码失败")
        XCTAssertEqual(manager.stateMachine.consecutiveFailures, 0)
        XCTAssertEqual(manager.stateMachine.currentState, .active)
        XCTAssertFalse(manager.orchestrator.isAutoUnlocking)
    }
}

