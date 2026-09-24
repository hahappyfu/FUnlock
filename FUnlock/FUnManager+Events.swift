// FUnManager+Events.swift
// 系统事件监听分发与 FUn 设备事件入口（自 FUnManager.swift 抽离，保持单文件 <300 行）：
// 只做 @Published 状态更新、决策记录与 UnlockOrchestrator 调度的接线，
// 不承载业务策略；解锁流水线见 UnlockOrchestrator.swift。

import Foundation
import Cocoa

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
        state.wake = .succeeded
        orchestrator.cancelWakeRetry()
        if state.screen == .displaySleeping {
            state.screen = .locked(reason: .away)
        }
        orchestrator.attemptAutoUnlock()
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
        let isManualLock = !isSelfLocking
        if isSelfLocking {
            // FUnlock 自动锁屏，不标记为手动锁定
            isSelfLocking = false
            state.intent = .autoLock
        } else {
            // 用户手动锁屏（⌘+Ctrl+Q 等）→ 永久阻止自动解锁，直到手动解锁
            state.intent = .manualLock(deadline: Date().addingTimeInterval(86400))
        }
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
        let enabled = prefs.object(forKey: "enabled") == nil || prefs.bool(forKey: "enabled")
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
        let enabled = prefs.object(forKey: "enabled") == nil || prefs.bool(forKey: "enabled")
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
