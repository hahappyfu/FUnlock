// UnlockOrchestrator.swift
// 解锁流水线协调器（自 FUnManager.swift 抽离，保持单文件 <300 行）：
// 前置门控后的密码读取（guardFetchPassword）→ 注入与双保险验证（performInjectionAndVerify）
// → 异常频率检测。自动解锁入口 attemptAutoUnlock 与显示器唤醒重试（startWakeRetry）
// 见 UnlockOrchestrator+AutoUnlock.swift。
//
// 线程契约：全类 @MainActor 隔离，与 FUnManager 的状态交互全部在主线程串行执行；
// 延迟/并行 Task 闭包显式标注 @MainActor 且弱捕获 self，不依赖隐式 actor 继承。
// 安全检查严禁削弱：isSecureToInject 注入前校验、钥匙串冷启动错误处理、状态机
// 降级/冷却门控均按原 FUnManager 语义逐条保留。

import Foundation
import Cocoa

@MainActor
final class UnlockOrchestrator {

    // MARK: - 依赖与时间源

    /// 调用方（生命周期 ⊆ FUnManager：仅由其强持有）
    unowned let manager: FUnManager
    /// 时间源（与 FUnlockStateMachine 共用，可测试注入）
    let nowProvider: () -> Date
    var now: Date { nowProvider() }

    // MARK: - 任务与流程状态

    var wakeTask: Task<Void, Never>?
    var unlockTask: Task<Void, Never>?
    /// FUn 是否正在执行自动解锁（用于区分手动解锁入侵）
    private(set) var isAutoUnlocking = false
    /// 是否已请求显示器唤醒（防止重复启动唤醒重试任务）
    var displayWakeRequested = false
    private var consecutiveUnlockAttempts = 0
    private let maxUnlockAttempts = 3
    private var lastAXRevokedAlertTime: Date = .distantPast

    // MARK: - 异常解锁频率检测（滑动窗口）

    private var unlockAttemptTimestamps: [Date] = []
    private let maxAttemptsInWindow = 10          // 窗口内最多允许 10 次
    private let detectionWindow: TimeInterval = 300  // 5 分钟窗口
    private var lastAbnormalAlertTime: Date = .distantPast

    // MARK: - 决策记录节流

    /// 节流：同一 reason 在窗口内只记录一次（防止诊断时间线刷屏）
    private var lastRecordTime: [DecisionReason: Date] = [:]

    init(manager: FUnManager, nowProvider: @escaping () -> Date) {
        self.manager = manager
        self.nowProvider = nowProvider
    }

    deinit {
        wakeTask?.cancel()
        unlockTask?.cancel()
    }

    // MARK: - 任务生命周期（供 FUnManager 清理路径调用）

    /// 取消唤醒重试与延迟解锁任务（用户干预 / 退出清理）
    func cancelPendingTasks() {
        wakeTask?.cancel()
        wakeTask = nil
        unlockTask?.cancel()
        unlockTask = nil
    }

    /// 取消唤醒重试任务（显示器已唤醒）
    func cancelWakeRetry() {
        wakeTask?.cancel()
        wakeTask = nil
    }

    /// 用户解锁后的流程状态复位：自动解锁尝试计数与异常检测窗口清零
    func resetAfterUserUnlock() {
        consecutiveUnlockAttempts = 0
        unlockAttemptTimestamps.removeAll()
    }

    // MARK: - 密码获取与注入

    /// 注入前奏：检查系统是否处于适合解锁的状态（系统休眠时禁止注入）
    func isSystemReadyForUnlock() -> Bool {
        manager.state.system == .awake
    }

    /// 抽取解锁逻辑（被 attemptAutoUnlock 和并行唤醒共用）
    func tryUnlock() {
        timingLog("tryUnlock enter")
        guard let password = guardFetchPassword() else { return }
        performInjectionAndVerify(password: password)
    }

    /// 前置门控 + 密码获取：任一检查失败即记录原因并返回 nil
    func guardFetchPassword() -> String? {
        let m = manager
        let sys = SystemInteractionService.shared
        let locked = sys.isScreenLocked(screenState: m.state.screen)
        timingLog("guardFetchPassword | locked=\(locked) frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")")
        logDebug(component: "FUnManager", "tryUnlock() START - screen=\(m.state.screen), locked=\(locked)")
        Log.sm.debug("screen locked check: \(locked)")
        guard locked else { Log.sm.debug("SKIP: screen not locked"); recordUnlock(.info, reason: .screenNotLocked, detail: "屏幕已解锁"); return nil }

        // 状态机门控：通过状态机确认解锁冷却和降级状态
        let smAllowed = m.stateMachine.attemptUnlock()
        guard smAllowed else { Log.sm.info("SKIP: state machine denied unlock attempt"); recordUnlock(reason: .stateMachineBlocked); return nil }

        let sinceUnlock = now.timeIntervalSince(m.state.unlockedAt)
        guard sinceUnlock > 3 else {
            Log.sm.debug("SKIP: recently unlocked (\(String(format:"%.1f", sinceUnlock))s ago)")
            recordUnlock(reason: .recentlyUnlocked, detail: "\(String(format: "%.1f", sinceUnlock)) 秒前解锁过")
            return nil
        }
        let fetchResult = SecurityService.shared.fetchPassword(warn: true)
        guard case .success(let password) = fetchResult, let password = password else {
            if case .failure(let error) = fetchResult {
                Log.sm.debug("SKIP: Keychain error - \(error)")
                recordUnlock(reason: .keychainColdBoot, detail: "\(error)")
            } else {
                Log.sm.debug("SKIP: no password")
                recordUnlock(reason: .noPassword)
            }
            return nil
        }
        logDebug(component: "FUnManager", "tryUnlock() password fetched")

        // #6: 最后一次检查，防止等待期间指纹/Apple Watch 解锁
        let secure = sys.isSecureToInject(screenState: m.state.screen)
        logDebug(component: "FUnManager", "tryUnlock() isSecureToInject = \(secure), screen=\(m.state.screen)")
        guard secure else { Log.sm.debug("SKIP: screen no longer secure for injection"); recordUnlock(reason: .notSecureForInjection); return nil }
        return password
    }

    /// 密码注入 + 乐观确认 + 双保险验证
    func performInjectionAndVerify(password: String) {
        let m = manager
        let sys = SystemInteractionService.shared
        let snap = m.fun.signalSnapshot()
        timingLog("performInjectionAndVerify | injecting password")
        Log.sm.debug("typing password with Shift prelude")
        m.state.unlockedAt = now
        m.lastUnlockTime = now
        // 标记 FUn 正在自动解锁，onUnlock 据此区分手动解锁（入侵）
        isAutoUnlocking = true
        logDebug(component: "FUnManager", "tryUnlock() calling injectPasswordWithPrelude")
        let posted = sys.injectPasswordWithPrelude(password) {
            m.state.screen != .unlocked
            && sys.isSecureToInject(screenState: m.state.screen)
        }
        logDebug(component: "FUnManager", "tryUnlock() injectPasswordWithPrelude returned posted=\(posted)")
        Log.sm.debug("fakeKeyStrokes done — posted=\(posted)")
        guard posted else {
            Log.sm.error("WARN: CGEvent post failed — Accessibility permission likely revoked")
            // 注入失败，本次不算自动解锁，立即复位标记
            isAutoUnlocking = false
            recordUnlock(.blocked, reason: .axRevoked, detail: "事件注入失败")
            sys.showAXRevokedAlertIfNeeded(lastAlertTime: &lastAXRevokedAlertTime)
            return
        }
        Log.sm.debug("unlock attempt posted, waiting for dual verification")
        // 双保险验证：通知 + CGSession 竞速（withTaskGroup）
        // iMessage / unlock_success / 遥测 / 自定义脚本 必须等验证通过后再执行，避免密码还在输入框就误报解锁
        Task { @MainActor [weak self] in
            let sys = SystemInteractionService.shared
            let verification = await sys.verifyUnlock(timeout: 2.0, notificationTimeout: 1.0)
            guard let self else { return }
            timingLog("verifyUnlock done | unlock=\(verification.unlock)")
            // 验证完成（无论成败）后恢复自动解锁标记，defer 覆盖所有出口
            defer { self.isAutoUnlocking = false }
            if verification.unlock {
                // 通知或 CGSession 确认解锁成功
                Log.sm.debug("dual verify: unlock confirmed")
                self.consecutiveUnlockAttempts = 0
                logDebug(component: "FUnManager", "tryUnlock() - dual verify passed, counter reset")
                self.recordUnlock(.success, reason: .unlockSuccess)
                iMessageNotifier.shared.send(.unlocked(rssi: snap.effectiveRSSI, deviceName: self.manager.monitoredDeviceName))
                self.manager.resumeMediaIfNeeded()
                ScriptRunner.shared.logEventIfNeeded("unlock_confirmed", rssi: self.manager.rssi, extraFields: self.unlockEventExtras(result: "success"))
                ScriptRunner.shared.runScript("unlocked", rssi: self.manager.rssi, deviceName: self.manager.monitoredDeviceName)
                ScriptRunner.shared.logEvent("unlocked", rssi: self.manager.rssi)
                TelemetryLogger.shared.log(
                    event: .autoUnlock, deviceModel: self.manager.monitoredDeviceName,
                    rawRSSI: self.manager.rssi ?? -100, kalmanRSSI: snap.kalmanEstimate,
                    effectiveRSSI: snap.effectiveRSSI, slope: snap.smoothedSlope,
                    isAnomalous: snap.lastSignalAnomalous
                )
                Log.sm.debug("unlock complete")
                // 状态机在 @MainActor 上串行更新（本 Task 已标注 @MainActor），无需再包 Task
                self.manager.stateMachine.handleUnlockSuccess()
            } else {
                // 通知和 CGSession 都未确认解锁 → 可能密码错误
                if sys.isScreenLocked(screenState: self.manager.state.screen) {
                    self.consecutiveUnlockAttempts += 1
                    self.recordUnlockAttempt()
                    Log.sm.debug("dual verify: still locked → #\(self.consecutiveUnlockAttempts)/\(self.maxUnlockAttempts)")
                    self.recordUnlock(.failed, reason: .unlockFailed, detail: "第 \(self.consecutiveUnlockAttempts)/\(self.maxUnlockAttempts) 次尝试")
                    logDebug(component: "FUnManager", "tryUnlock() - dual verify failed, attempts=\(self.consecutiveUnlockAttempts)/\(self.maxUnlockAttempts)")
                    self.manager.stateMachine.handleUnlockFailure()
                    ScriptRunner.shared.logEventIfNeeded("unlock_failed", rssi: self.manager.rssi, extraFields: self.unlockEventExtras(result: "fail"))
                    logDebug(component: "FUnManager", "tryUnlock() - unlock_failed recorded, attempts=\(self.consecutiveUnlockAttempts)/\(self.maxUnlockAttempts)")
                    if self.consecutiveUnlockAttempts >= self.maxUnlockAttempts {
                        self.recordUnlock(.blocked, reason: .passwordMismatch, detail: "失败次数过多")
                        sys.showPasswordMismatchAlert()
                        self.consecutiveUnlockAttempts = 0
                    }
                } else {
                    // CGSession 也显示已解锁（竞态下可能延迟发现）
                    Log.sm.debug("dual verify: timeout but CGSession says unlocked")
                    self.consecutiveUnlockAttempts = 0
                    logDebug(component: "FUnManager", "tryUnlock() - dual verify timeout but screen unlocked, counter reset")
                    self.manager.stateMachine.handleUnlockSuccess()
                }
            }
        }
    }

    /// 解锁事件扩展字段（乐观确认 / 双保险验证共用）
    private func unlockEventExtras(result: String) -> [String: String] {
        let snap = manager.fun.signalSnapshot()
        return [
            "result": result,
            "latencyMs": "0",
            "source": "proximity",
            "effectiveRSSI": String(format: "%.1f", snap.effectiveRSSI),
            "device": manager.monitoredDeviceName ?? "unknown"
        ]
    }

    // MARK: - 决策记录（解锁类；锁/系统/用户记录见 FUnManager）

    func recordUnlock(_ outcome: DecisionOutcome = .skipped, reason: DecisionReason?, detail: String = "") {
        let snap = manager.fun.signalSnapshot()
        let effDetail = "信号 \(String(format: "%.1f", snap.effectiveRSSI)) dBm（解锁阈值 \(manager.fun.unlockRSSI) dBm）"
        let combinedDetail = detail.isEmpty ? effDetail : "\(detail)（\(effDetail)）"
        manager.decisionLogger.record(category: .unlock, outcome: outcome, reason: reason,
                                      rssi: manager.rssi, device: manager.monitoredDeviceName,
                                      screen: manager.state.screen.description, detail: combinedDetail)
    }

    /// 节流版记录：同一 reason 在 throttle 秒内只记录一次，超时或首次记录
    func recordUnlockThrottled(_ reason: DecisionReason, detail: String = "", throttle: TimeInterval = 30) {
        let now = nowProvider()
        if let last = lastRecordTime[reason], now.timeIntervalSince(last) < throttle {
            return
        }
        lastRecordTime[reason] = now
        recordUnlock(reason: reason, detail: detail)
    }

    // MARK: - 异常解锁频率检测

    /// 记录一次解锁尝试（失败时调用），滑动窗口检测异常频率
    func recordUnlockAttempt() {
        let now = Date()
        let snap = manager.fun.signalSnapshot()
        unlockAttemptTimestamps.append(now)
        // 清理窗口外的记录
        unlockAttemptTimestamps = unlockAttemptTimestamps.filter {
            now.timeIntervalSince($0) < detectionWindow
        }
        // 检测异常：窗口内失败次数达到阈值
        if unlockAttemptTimestamps.count >= maxAttemptsInWindow {
            let timeSinceLastAlert = now.timeIntervalSince(lastAbnormalAlertTime)
            if timeSinceLastAlert > 3600 {  // 1小时内最多告警一次
                SystemInteractionService.shared.showAbnormalUnlockAlert(
                    count: unlockAttemptTimestamps.count, window: Int(detectionWindow))
                // P3: 形子模式遥测 — 记录异常解锁告警
                TelemetryLogger.shared.log(
                    event: .abnormalAlert, deviceModel: manager.monitoredDeviceName,
                    rawRSSI: manager.rssi ?? -100, kalmanRSSI: snap.kalmanEstimate,
                    effectiveRSSI: snap.effectiveRSSI, slope: snap.smoothedSlope, isAnomalous: true
                )
                lastAbnormalAlertTime = now
            }
        }
    }
}
