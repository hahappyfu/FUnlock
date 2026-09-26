// FUnManager+Events.swift
// 系统事件监听分发与 FUn 设备事件入口（自 FUnManager.swift 抽离，保持单文件 <300 行）：
// 只做 @Observable 状态更新、决策记录与 UnlockOrchestrator 调度的接线，
// 不承载业务策略；解锁流水线见 UnlockOrchestrator.swift。

import Foundation
import Cocoa

/// isSelfLocking 置位时间戳（审计修复 #2a：com.apple.screenIsLocked 通知可能丢失，
/// 标志残留会把用户下一次手动锁屏误判为自动锁屏；消费时距置位超过 10s 视为过期）。
/// extension 无法添加存储属性，故放文件作用域；FUnManager 全类 @MainActor 隔离，
/// 本标记同样限定主线程访问。internal 可见性供测试注入时间戳。
@MainActor var selfLockingStartedAt: Date?

extension FUnManager {

    // MARK: - 系统事件入口

    func onDisplaySleep() {
        Log.sm.debug("[SM] displaySleep")
        recordSystem(.displaySleep)
        Log.sm.debug("EVENT: onDisplaySleep screen=\(self.state.screen) system=\(self.state.system)")
        state.screen = .displaySleeping
    }

    func onDisplayWake() {
        Log.sm.debug("[SM] displayWake")
        recordSystem(.displayWake)
        Log.sm.debug("EVENT: onDisplayWake screen=\(self.state.screen) system=\(self.state.system)")
        // 审计修复 #4/#10：必须在 cancelWakeRetry 复位 displayWakeRequested 之前捕获——
        // true 表示本次唤醒由 FUn 预唤醒（startWakeRetry）发起，属程序自唤醒而非用户手动唤醒
        let isSelfWake = orchestrator.displayWakeRequested
        state.wake = .succeeded
        orchestrator.cancelWakeRetry()
        if state.screen == .displaySleeping {
            state.screen = .locked(reason: .away)
        }
        if isSelfWake {
            // 程序自唤醒：只调度自动解锁。若再走用户干预（resetToActive + cancelPendingTasks），
            // 会把刚调度的解锁任务取消，唤醒路径的自动解锁被自己杀死（修复 #4）
            // 标记复位：正常由 wakeTask 的 defer 兜底，此处同步复位保证状态确定性
            orchestrator.displayWakeRequested = false
            orchestrator.attemptAutoUnlock()
        } else {
            // 用户手动唤醒：保持原有两级语义——先 attemptAutoUnlock（原 onDisplayWake 行为），
            // 再执行用户干预（原 AppDelegate 独立 screensDidWake 观察者的行为）。
            // 两个订阅者已合并到同一入口按固定顺序执行，消除"先调度后取消"的竞态（修复 #10）：
            // 此前干预经独立观察者异步触发，且 wakeTask 的 defer 可能已提前复位
            // displayWakeRequested，导致自唤醒路径的解锁任务仍被误杀
            orchestrator.attemptAutoUnlock()
            onUserIntervention()
        }
    }

    func onSystemSleep() {
        Log.sm.debug("[SM] systemSleep")
        recordSystem(.systemSleep)
        state.system = .sleeping
        NSApp.setActivationPolicy(.regular)
    }

    func onSystemWake() {
        Log.sm.debug("[SM] systemWake")
        recordSystem(.systemWake)
        // 延迟 1 秒等待蓝牙栈恢复
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            NSApp.setActivationPolicy(.accessory)
            self.state.system = .awake
            self.orchestrator.attemptAutoUnlock()
        }
    }

    /// 用户主动干预（如手动唤醒屏幕）时调用，强制状态机回到 active
    /// 注意：不清空失败计数与冷却（clearFailures: false），防止屏幕唤醒被用作绕过暴力破解保护的途径
    /// 审计修复 #4/#10：现仅由 onDisplayWake 的"用户手动唤醒"分支调用（原 AppDelegate
    /// 独立 screensDidWake 观察者已合并），程序自唤醒不会再触发本方法
    func onUserIntervention() {
        Log.sm.debug("[SM] userIntervention — force reset to active")
        stateMachine.resetToActive(clearFailures: false)
        orchestrator.cancelPendingTasks()
    }

    func onUnlock() {
        Log.sm.debug("[SM] userUnlocked")
        state.screen = .unlocked
        state.unlockedAt = Date()
        state.intent = .autoLock
        orchestrator.resetAfterUserUnlock()
        lastUnlockTime = now
        fun.refreshProximityGrace()
        // 区分解锁来源：FUn 自动解锁的 unlockSuccess 已在 performInjectionAndVerify 记录，
        // 这里只在真正手动解锁时记录 userUnlocked，避免自动解锁被误标为"用户手动解锁"
        if !orchestrator.isAutoUnlocking {
            recordUser(.userUnlocked)
        }
        // 状态机：用户解锁成功 → 重置为 active（退出降级/冷却）
        // 本方法已在 @MainActor 上执行，同步调用即可，无需再包一层 Task
        stateMachine.resetToActive()

        // 2 秒后检查是否为入侵（非 FUn 自动解锁）
        // Task 是逃逸闭包，内部再读 isAutoUnlocking 会拿到 2 秒后的值，
        // 因此必须在启动 Task 前同步捕获快照
        let wasFUnUnlock = orchestrator.isAutoUnlocking
        intrudeCheckTask?.cancel()
        intrudeCheckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            if !wasFUnUnlock {
                if self.fun.unlockRSSI != FUn.UNLOCK_DISABLED {
                    ScriptRunner.shared.runScript("intruded", rssi: self.rssi, deviceName: self.monitoredDeviceName)
                    ScriptRunner.shared.logEvent("intruded", rssi: self.rssi)
                }
                self.resumeMediaIfNeeded()
            }
            self.checkUpdate()
        }
    }

    func onScreensaverStart() {
        Log.sm.debug("[SM] screensaverStart")
        // 审计修复 #1：手动启动屏保（热角等）等同手动锁定——只改 screen 不设 intent 时，
        // 屏保结束后设备靠近仍会自动解锁。与 onSystemScreenLocked 的手动锁分支同语义；
        // isSelfLocking（FUnlock 自锁走屏保路径）时不标记，消费逻辑见 onSystemScreenLocked
        if !isSelfLocking {
            state.intent = .manualLock(deadline: Date().addingTimeInterval(86400))
        }
        state.screen = .screensaver
    }

    func onScreensaverStop() {
        Log.sm.debug("[SM] screensaverStop")
        if state.screen == .screensaver {
            state.screen = .locked(reason: .manual)
            state.unlockedAt = Date(timeIntervalSince1970: 0)  // 重置解锁时间，允许新的解锁
        }
    }

    /// 系统原生锁屏通知（Apple 菜单 → Lock Screen，或快捷键）
    /// 无条件进入 manualLock 状态，防止设备走远再靠近时自动解锁
    func onSystemScreenLocked() {
        Log.sm.debug("[SM] systemScreenLocked")
        // 审计修复 #2a：isSelfLocking 置位超过 10s 视为过期——
        // com.apple.screenIsLocked 通知丢失时标志残留，会把用户下一次手动锁屏误判为自动锁屏
        let selfLockingExpired: Bool
        if let startedAt = selfLockingStartedAt {
            selfLockingExpired = now.timeIntervalSince(startedAt) > 10
        } else {
            selfLockingExpired = false
        }
        let isManualLock = !isSelfLocking || selfLockingExpired
        if isSelfLocking && !selfLockingExpired {
            // FUnlock 自动锁屏，不标记为手动锁定
            state.intent = .autoLock
        } else {
            // 用户手动锁屏（⌘+Ctrl+Q 等）→ 永久阻止自动解锁，直到手动解锁
            state.intent = .manualLock(deadline: Date().addingTimeInterval(86400))
        }
        isSelfLocking = false
        selfLockingStartedAt = nil
        state.screen = .locked(reason: .manual)
        state.unlockedAt = Date(timeIntervalSince1970: 0)
        lastLockTime = now
        // 在 state.screen 更新后记录，保证诊断日志的屏幕状态为锁屏后的 .locked(manual)，
        // 与 onUnlock 记录 userUnlocked 的时机语义一致
        if isManualLock { recordUser(.userLocked) }
    }

    // MARK: - FUn 设备事件

    func onDeviceApproached() {
        let snap = fun.signalSnapshot()
        // 键缺失时按启用处理（与 UI @AppStorage 默认值一致），避免静默拦截锁屏/解锁
        let enabled = ConfigStore.shared.bool(forKey: "enabled", default: true)
        guard enabled else { return }
        guard fun.unlockRSSI != FUn.UNLOCK_DISABLED else { return }
        let smoothed = snap.effectiveRSSI
        lockLog("[LOCK] onDeviceApproached screen=\(state.screen) eff=\(String(format: "%.1f", smoothed)) preWake=\(fun.preWakeThreshold) stair=\(fun.unlockStairThreshold) wakeOnProximity=\(prefs.bool(forKey: "wakeOnProximity"))")
        timingLog("onDeviceApproached | screen=\(state.screen) eff=\(String(format: "%.1f", smoothed)) preWake=\(fun.preWakeThreshold) stair=\(fun.unlockStairThreshold) wakeOnProx=\(prefs.bool(forKey: "wakeOnProximity"))")

        // 清除锁屏通知
        SystemInteractionService.shared.clearLockNotification()

        // 阶梯唤醒：平滑信号达到 preWakeThreshold（-60dBm）时唤醒显示器
        if state.screen == .displaySleeping
            && prefs.bool(forKey: "wakeOnProximity")
            && !orchestrator.displayWakeRequested
            && smoothed >= Double(fun.preWakeThreshold) {
            orchestrator.displayWakeRequested = true
            orchestrator.startWakeRetry()
        }

        // 到位解锁：平滑信号达到解锁阈值 unlockRSSI 才尝试解锁（-70~-60 为预热带，只唤醒不解锁）
        if smoothed >= Double(fun.unlockRSSI) {
            orchestrator.attemptAutoUnlock()
        }
    }

    func onDeviceLeft(reason: String) {
        let snap = fun.signalSnapshot()
        // 键缺失时按启用处理（与 UI @AppStorage 默认值一致），避免静默拦截锁屏/解锁
        let enabled = ConfigStore.shared.bool(forKey: "enabled", default: true)
        let screenState = state.screen
        let lockDisabled = fun.lockRSSI == FUn.LOCK_DISABLED
        lockLog("[LOCK] onDeviceLeft reason=\(reason) enabled=\(enabled) screen=\(screenState) lockRSSI=\(fun.lockRSSI) lockDisabled=\(lockDisabled) eff=\(String(format: "%.1f", snap.effectiveRSSI))")
        guard enabled else { lockLog("[LOCK] onDeviceLeft blocked: enabled=false"); return }
        guard screenState == .unlocked else { lockLog("[LOCK] onDeviceLeft blocked: screen=\(screenState) != unlocked"); return }
        guard !lockDisabled else { lockLog("[LOCK] onDeviceLeft blocked: lock disabled"); return }
        // 锁冷静期：解锁成功后短时间内（proximityGracePeriod=5s）信号再弱也不锁，
        // 覆盖 lost 快速锁屏路径（3 次 BLE 超时 → markSignalLost），防止刚解锁又秒锁
        guard !fun.isWithinLockGracePeriod() else {
            lockLog("[LOCK] onDeviceLeft blocked: within unlock grace period")
            return
        }

        orchestrator.displayWakeRequested = false
        state.screen = .displaySleeping
        lastLockTime = now
        checkAndPauseMedia()
        isSelfLocking = true
        selfLockingStartedAt = now
        let sys = SystemInteractionService.shared
        sys.lockOrSaveScreen(useScreensaver: prefs.bool(forKey: "screensaver"),
                             sleepDisplayAfter: prefs.bool(forKey: "sleepDisplay"))
        sys.notifyLock(reason: reason)
        ScriptRunner.shared.runScript(reason, rssi: rssi, deviceName: monitoredDeviceName)
        ScriptRunner.shared.logEvent("locked: \(reason)", rssi: rssi)
        let lockReason: DecisionReason = (reason == "lost") ? .lockedLost : .lockedAway
        recordLock(lockReason)
        iMessageNotifier.shared.send(.locked(reason: reason, rssi: snap.effectiveRSSI, deviceName: monitoredDeviceName))
        // P3: 形子模式遥测 — 记录自动锁屏事件
        TelemetryLogger.shared.log(
            event: .autoLock,
            deviceModel: monitoredDeviceName,
            rawRSSI: rssi ?? -100,
            kalmanRSSI: snap.kalmanEstimate,
            effectiveRSSI: snap.effectiveRSSI,
            slope: snap.smoothedSlope,
            isAnomalous: snap.lastSignalAnomalous
        )
        // 审计修复 #2b：锁屏调用 2s 后回读会话状态，验证锁屏确实生效
        // （SACLockScreenImmediate/屏保启动可能静默失败，失败时通知 com.apple.screenIsLocked
        // 也不会来，isSelfLocking 残留 + 本地状态卡在锁定态）。未锁定则本地告警、
        // screen 回滚 unlocked 并复位 isSelfLocking。
        // 本回读在 @MainActor 执行，必须用 Task.sleep 而非 Thread.sleep。
        // 判定与 isScreenLocked 同源：CGSession 已锁 或 ScreenSaver.Engine 在运行（屏保路径）
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self, self.isSelfLocking else { return }
            let dict = CGSessionCopyCurrentDictionary() as? [String: Any]
            let sessionLocked = dict?["CGSSessionScreenIsLocked"] as? Int == 1
            let screensaverRunning = !NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.ScreenSaver.Engine").isEmpty
            if !sessionLocked && !screensaverRunning {
                Log.sm.error("[SM] lock verify failed: session not locked 2s after lock call, rolling back")
                self.state.screen = .unlocked
                self.isSelfLocking = false
                selfLockingStartedAt = nil
            }
        }
    }

    func onRSSIUpdated(rssi: Int?, active: Bool) {
        self.rssi = rssi

        // 预备唤醒：平滑 RSSI >= preWakeThreshold 时唤醒显示器（不等到解锁阈值）
        if let rssi = rssi, !orchestrator.displayWakeRequested,
           state.screen == .displaySleeping,
           prefs.bool(forKey: "wakeOnProximity") {
            let smoothed = fun.smoothedRSSI(rssi)
            if smoothed >= Double(fun.preWakeThreshold) {
                orchestrator.displayWakeRequested = true
                Log.sm.debug("[SM] pre-wake triggered at smoothed RSSI \(String(format: "%.1f", smoothed))")
                orchestrator.startWakeRetry()
            }
        }
    }
}
