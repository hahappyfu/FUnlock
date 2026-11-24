// FUnManager+Events.swift
// 系统事件监听分发与 FUn 设备事件入口（自 FUnManager.swift 抽离，保持单文件 <300 行）：
// 只做 @Observable 状态更新、决策记录与 UnlockOrchestrator 调度的接线，
// 不承载业务策略；解锁流水线见 UnlockOrchestrator.swift。

import Foundation
import Cocoa

extension FUnManager {

    // MARK: - 系统事件入口

    func onDisplaySleep() {
        AppLog.info(.sm, "displaySleep", [("screen", "\(self.state.screen)")])
        recordSystem(.displaySleep)
        state.screen = .displaySleeping
    }

    func onDisplayWake() {
        AppLog.info(.sm, "displayWake", [("screen", "\(self.state.screen)")])
        recordSystem(.displayWake)
        // 审计修复 #4/#10：必须在 cancelWakeRetry 复位 displayWakeRequested 之前捕获——
        // true 表示本次唤醒由 FUn 预唤醒（startWakeRetry）发起，属程序自唤醒而非用户手动唤醒
        let isSelfWake = orchestrator.displayWakeRequested
        state.wake = .succeeded
        orchestrator.cancelWakeRetry()
        if state.screen == .displaySleeping {
            // 息屏不等于会话已锁：唤醒后按外部真实锁态恢复，避免永久卡在 .locked
            let systemLocked = SystemInteractionService.shared.isSystemSessionLocked()
            state.screen = systemLocked ? .locked(reason: .away) : .unlocked
            AppLog.info(.sm, "displayWakeSessionState", [
                ("systemLocked", "\(systemLocked)"),
                ("screen", "\(state.screen)")
            ])
        }
        if isSelfWake {
            // 程序自唤醒：只调度自动解锁。若再走用户干预（resetToActive + cancelPendingTasks），
            // 会把刚调度的解锁任务取消，唤醒路径的自动解锁被自己杀死（修复 #4）
            // 标记复位：正常由 wakeTask 的 defer 兜底，此处同步复位保证状态确定性
            orchestrator.displayWakeRequested = false
            orchestrator.attemptAutoUnlock()
        } else {
            // 用户手动唤醒：先干预（复位状态机并取消陈旧任务），再调度新的延迟解锁任务。
            // 顺序不可倒置：onUserIntervention 的 cancelPendingTasks 无条件取消 unlockTask，
            // 若先 attemptAutoUnlock 后干预，刚调度的解锁任务必被取消，手动唤醒的自动解锁失效（P0-3）
            onUserIntervention()
            orchestrator.attemptAutoUnlock()
        }
    }

    func onSystemSleep() {
        AppLog.info(.sm, "systemSleep")
        recordSystem(.systemSleep)
        state.system = .sleeping
        systemWakeTask?.cancel()
        systemWakeTask = nil
        systemWakeGeneration &+= 1
        cancelDeferredLockRecheck()
        // 休眠期间临时转 regular：睡眠/唤醒窗口内可能需要弹出交互窗（改密确认、更新安装确认），
        // accessory（菜单栏 agent）拿不到关键窗口焦点；唤醒完成在 onSystemWake 恢复 accessory
        NSApp.setActivationPolicy(.regular)
    }

    func onSystemWake() {
        AppLog.info(.sm, "systemWake")
        recordSystem(.systemWake)
        // 延迟等待蓝牙栈恢复（默认 1s，测试注入更小值）；二次睡眠/重复唤醒会取消旧任务
        systemWakeTask?.cancel()
        systemWakeGeneration &+= 1
        let generation = systemWakeGeneration
        let delay = systemWakeDelay
        systemWakeTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.systemWakeGeneration == generation {
                    self.systemWakeTask = nil
                }
            }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.systemWakeGeneration == generation else { return }
            guard self.state.system == .sleeping else { return }
            // 恢复菜单栏 agent 形态（配对 onSystemSleep 的临时 regular，见该处注释）
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
        AppLog.info(.sm, "userIntervention", [("action", "forceResetToActive")])
        stateMachine.resetToActive(clearFailures: false)
        orchestrator.cancelPendingTasks()
    }

    func onUnlock() {
        AppLog.info(.sm, "userUnlocked")
        cancelDeferredLockRecheck()
        clearSelfLockWindow()
        state.screen = .unlocked
        state.unlockedAt = Date()
        state.intent = .autoLock
        orchestrator.resetAfterUserUnlock()
        lastUnlockTime = now
        fun.refreshProximityGrace()
        // 区分解锁来源：FUn 自动解锁的 unlockSuccess 已在 performInjectionAndVerify 记录，
        // 这里只在真正手动解锁时记录 userUnlocked，避免自动解锁被误标为"用户手动解锁"
        // P1-2: isAutoUnlocking 在 unlockTask 的 defer 中早于慢速分布式通知复位，
        // 改用带 4s 完成窗口的判定，避免合法自动解锁被误判
        if !orchestrator.isAutoUnlockingOrRecentlyCompleted {
            recordUser(.userUnlocked)
        }
        // 状态机：用户解锁成功 → 重置为 active（退出降级/冷却）
        // 本方法已在 @MainActor 上执行，同步调用即可，无需再包一层 Task
        stateMachine.resetToActive()

        // P1-1: 锁屏期间收到的改密通知被延迟到此处消费——屏幕已解锁，弹确认窗安全。
        // 先复位标记再处理，防止 runModal 期间重入重复消费
        if SecurityService.shared.hasPendingPasswordChange {
            SecurityService.shared.hasPendingPasswordChange = false
            SecurityService.shared.handlePasswordChanged()
        }

        // 2 秒后检查是否为入侵（非 FUn 自动解锁）
        // Task 是逃逸闭包，内部再读 isAutoUnlocking 会拿到 2 秒后的值，
        // 因此必须在启动 Task 前同步捕获快照
        // P1-2: 同上，改用带 4s 完成窗口的判定
        let wasFUnUnlock = orchestrator.isAutoUnlockingOrRecentlyCompleted
        // P1-2: 设备在场判定同样在 Task 前捕获——2 秒后信号可能已变化，
        // 用解锁瞬间的快照判断授权设备是否在场，防止设备在场的合法手动解锁被误报
        let snap = fun.signalSnapshot()
        let isDevicePresent = rssi != nil && (snap.presence || snap.effectiveRSSI >= Double(fun.unlockRSSI))
        intrudeCheckTask?.cancel()
        intrudeCheckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            if !wasFUnUnlock {
                // 入侵 = 手动输密码解锁且授权设备不在场（手表在另一房间/无信号）
                if !isDevicePresent && self.fun.unlockRSSI != FUn.UNLOCK_DISABLED {
                    ScriptRunner.shared.runScript("intruded", rssi: self.rssi, deviceName: self.monitoredDeviceName)
                    ScriptRunner.shared.logEvent("intruded", rssi: self.rssi)
                }
                self.resumeMediaIfNeeded()
            }
            self.checkUpdate()
        }
    }

    func onScreensaverStart() {
        AppLog.info(.sm, "screensaverStart")
        // 审计修复 #1：手动启动屏保（热角等）等同手动锁定——只改 screen 不设 intent 时，
        // 屏保结束后设备靠近仍会自动解锁。与 onSystemScreenLocked 的手动锁分支同语义；
        // 自锁窗口内不标记手动锁，也不清空窗口（系统锁屏与屏保通知可能任意顺序到达）
        if !isWithinSelfLockWindow {
            markManualLock()
        }
        state.screen = .screensaver
    }

    func onScreensaverStop() {
        AppLog.info(.sm, "screensaverStop")
        if state.screen == .screensaver {
            state.screen = .locked(reason: .manual)
            state.unlockedAt = Date(timeIntervalSince1970: 0)  // 重置解锁时间，允许新的解锁
        }
    }

    /// 系统原生锁屏通知（Apple 菜单 → Lock Screen，或快捷键）
    /// 无条件进入 manualLock 状态，防止设备走远再靠近时自动解锁
    func onSystemScreenLocked() {
        AppLog.info(.sm, "systemScreenLocked")
        cancelDeferredLockRecheck()
        // 自锁窗口内：按自动锁处理且不清空窗口（屏保通知可能随后到达）；
        // 窗口外：手动锁，永久阻止自动解锁直到 onUnlock。
        let isSelfLock = isWithinSelfLockWindow
        if isSelfLock {
            state.intent = .autoLock
        } else {
            markManualLock()
        }
        state.screen = .locked(reason: .manual)
        state.unlockedAt = Date(timeIntervalSince1970: 0)
        lastLockTime = now
        // 在 state.screen 更新后记录，保证诊断日志的屏幕状态为锁屏后的 .locked(manual)，
        // 与 onUnlock 记录 userUnlocked 的时机语义一致
        if !isSelfLock { recordUser(.userLocked) }
    }

    // MARK: - FUn 设备事件

    // MARK: - 延迟补锁复查（安全 Wi-Fi / 解锁冷静期）

    /// 取消待执行的补锁复查（设备回场 / 已锁屏 / 手动操作）。
    func cancelDeferredLockRecheck() {
        deferredLockGeneration &+= 1
        deferredLockTask?.cancel()
        deferredLockTask = nil
    }

    private func resolvedLockThresholdValue() -> Int {
        SignalHysteresisEngine.resolvedLockThreshold(unlockRSSI: fun.unlockRSSI, lockRSSI: fun.lockRSSI)
    }

    /// 当前是否仍满足自动锁屏条件（屏幕未锁、设备不在场、信号低于锁定阈值、冷静期已过）。
    private func shouldRetryDeferredLock() -> Bool {
        guard state.screen == .unlocked else { return false }
        let snap = fun.signalSnapshot()
        guard !snap.presence else { return false }
        guard snap.effectiveRSSI < Double(resolvedLockThresholdValue()) else { return false }
        guard !fun.isWithinLockGracePeriod() else { return false }
        return true
    }

    private func scheduleGraceRecheck(reason: String) {
        let remaining = fun.lockGraceRemaining
        cancelDeferredLockRecheck()
        deferredLockGeneration &+= 1
        let generation = deferredLockGeneration
        deferredLockTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.05, remaining + 0.05) * 1_000_000_000))
            guard !Task.isCancelled, let self, self.deferredLockGeneration == generation else { return }
            self.deferredLockTask = nil
            guard self.shouldRetryDeferredLock() else { return }
            self.onDeviceLeft(reason: reason)
        }
    }

    private func scheduleTrustedWiFiRecheck(reason: String, targetSSID: String) {
        cancelDeferredLockRecheck()
        deferredLockGeneration &+= 1
        let generation = deferredLockGeneration
        let interval = max(0.01, trustedWiFiRecheckInterval)
        deferredLockTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self, self.deferredLockGeneration == generation else { return }
                guard self.shouldRetryDeferredLock() else {
                    self.deferredLockTask = nil
                    return
                }
                if WiFiMonitor.shared.currentSSID != targetSSID {
                    self.deferredLockTask = nil
                    self.onDeviceLeft(reason: reason)
                    return
                }
            }
        }
    }

    func onDeviceApproached() {
        cancelDeferredLockRecheck()
        let snap = fun.signalSnapshot()
        // 键缺失时按启用处理（与 UI @AppStorage 默认值一致），避免静默拦截锁屏/解锁
        let enabled = ConfigStore.shared.bool(forKey: "enabled", default: true)
        guard enabled else { return }
        guard fun.unlockRSSI != FUn.UNLOCK_DISABLED else { return }
        let smoothed = snap.effectiveRSSI
        AppLog.info(.lock, "deviceApproached", [
            ("screen", "\(state.screen)"),
            ("eff", String(format: "%.1f", smoothed)),
            ("preWake", "\(fun.preWakeThreshold)"),
            ("stair", "\(fun.unlockStairThreshold)"),
            ("wakeOnProximity", "\(prefs.bool(forKey: "wakeOnProximity"))")
        ])
        timingLog("event=deviceApproached screen=\(state.screen) eff=\(String(format: "%.1f", smoothed)) preWake=\(fun.preWakeThreshold) stair=\(fun.unlockStairThreshold) wakeOnProx=\(prefs.bool(forKey: "wakeOnProximity"))")

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
        AppLog.info(.lock, "deviceLeft", [
            ("reason", reason),
            ("enabled", "\(enabled)"),
            ("screen", "\(screenState)"),
            ("lockRSSI", "\(fun.lockRSSI)"),
            ("lockDisabled", "\(lockDisabled)"),
            ("eff", String(format: "%.1f", snap.effectiveRSSI))
        ])
        guard enabled else { AppLog.info(.lock, "deviceLeftBlocked", [("reason", "enabledFalse")]); return }
        guard screenState == .unlocked else { AppLog.info(.lock, "deviceLeftBlocked", [("reason", "screenNotUnlocked"), ("screen", "\(screenState)")]); return }
        guard !lockDisabled else { AppLog.info(.lock, "deviceLeftBlocked", [("reason", "lockDisabled")]); return }
        // 锁冷静期：解锁成功后短时间内（proximityGracePeriod=5s）信号再弱也不锁，
        // 覆盖 lost 快速锁屏路径（3 次 BLE 超时 → markSignalLost），防止刚解锁又秒锁
        guard !fun.isWithinLockGracePeriod() else {
            AppLog.info(.lock, "deviceLeftBlocked", [("reason", "withinUnlockGracePeriod")])
            // 冷静期结束后若仍未回场，自动补锁一次
            scheduleGraceRecheck(reason: reason)
            return
        }

        // 安全 Wi-Fi：连接指定 Wi-Fi 时不自动锁屏（与 pauseOnWiFi 同一开关，双向暂停：不自动解锁也不自动锁屏）。
        // SSID 读不到时不拦截——读不到不等于命中，否则定位权限缺失会静默变成「永不锁屏」的安全漏洞。
        // 此处直读不复用 UnlockOrchestrator 的 5s 缓存：锁屏是低频事件，不需为性能付陈旧代价——
        // 刚离开安全 Wi-Fi 时缓存可能仍是旧值，会误判命中而漏锁。
        if ConfigStore.shared.bool(forKey: "pauseOnWiFi", default: false),
           let targetSSID = ConfigStore.shared.string(forKey: "pauseOnWiFiSSID"), !targetSSID.isEmpty,
           let currentSSID = WiFiMonitor.shared.currentSSID, currentSSID == targetSSID {
            AppLog.info(.lock, "deviceLeftSkipped", [("reason", "trustedWiFi"), ("ssid", currentSSID)])
            // 离开该 Wi-Fi 且设备仍不在场时自动补锁
            scheduleTrustedWiFiRecheck(reason: reason, targetSSID: targetSSID)
            return
        }

        orchestrator.displayWakeRequested = false
        state.screen = .displaySleeping
        lastLockTime = now
        checkAndPauseMedia()
        beginSelfLockWindow()
        let sys = SystemInteractionService.shared
        sys.lockOrSaveScreen(useScreensaver: prefs.bool(forKey: "screensaver"),
                             sleepDisplayAfter: prefs.bool(forKey: "sleepDisplay"))
        // 只有真正执行锁屏动作后才记录采样事件（被拦截时不产生虚假 .locked 点）
        SignalDataStore.shared.record(
            rawRSSI: Double(rssi ?? -100),
            kalmanEstimate: snap.kalmanEstimate,
            effectiveRSSI: snap.effectiveRSSI,
            slope: snap.smoothedSlope,
            isAnomalous: snap.lastSignalAnomalous,
            event: .locked)
        sys.notifyLock(reason: reason)
        ScriptRunner.shared.runScript(reason, rssi: rssi, deviceName: monitoredDeviceName)
        ScriptRunner.shared.logEvent("locked: \(reason)", rssi: rssi)
        let lockReason: DecisionReason = (reason == "lost") ? .lockedLost : .lockedAway
        recordLock(lockReason)
        iMessageNotifier.shared.send(.locked(reason: reason, rssi: snap.effectiveRSSI, deviceName: monitoredDeviceName))
        BarkNotifier.shared.send(.locked(reason: reason, rssi: snap.effectiveRSSI, deviceName: monitoredDeviceName))
        // P3: 形子模式遥测 — 记录自动锁屏事件
        TelemetryLogger.shared.log(
            event: .autoLock,
            deviceModel: monitoredDeviceName,
            rawRSSI: rssi ?? -100,
            kalmanRSSI: snap.kalmanEstimate,
            effectiveRSSI: snap.effectiveRSSI,
            slope: snap.smoothedSlope,
            isAnomalous: snap.lastSignalAnomalous,
            result: "success"
        )
        // 锁屏回读验证（2s）：SACLockScreenImmediate/屏保启动可能静默失败，
        // 失败时系统锁屏通知也不会来。代次守卫防止旧验证误伤新一次锁屏。
        scheduleLockVerification()
    }

    func onRSSIUpdated(rssi: Int?, active: Bool) {
        self.rssi = rssi

        // 预备唤醒：平滑 RSSI >= preWakeThreshold 时唤醒显示器（不等到解锁阈值）
        // 门控改读时间归一化 EMA（由 processSignal 单驱动），主线程不持锁直接读 currentSmoothedRSSI
        // rssi 非空守卫：失联派发（nil）不评估门控，避免用冻结 EMA 为已离场的设备误唤醒显示器
        if rssi != nil,
           !orchestrator.displayWakeRequested,
           state.screen == .displaySleeping,
           prefs.bool(forKey: "wakeOnProximity") {
            let smoothed = fun.currentSmoothedRSSI
            if smoothed >= Double(fun.preWakeThreshold) {
                orchestrator.displayWakeRequested = true
                AppLog.info(.sm, "preWakeTriggered", [("smoothedRSSI", String(format: "%.1f", smoothed))])
                orchestrator.startWakeRetry()
            }
        }
    }
}
