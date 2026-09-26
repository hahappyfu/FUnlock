// UnlockOrchestrator+AutoUnlock.swift
// 自动解锁入口：attemptAutoUnlock 的完整门控链、延迟调度与显示器唤醒重试
// startWakeRetry（自 FUnManager.swift 抽离；两者互相调用：唤醒循环成功后尝试解锁，
// 门控链在显示器休眠时启动唤醒重试）。
// 门控顺序严格保持原语义：presence → 解锁开关 → 信号阈值 → 状态机 →
// 锁屏缓冲 → 解锁冷却 → Wi-Fi 暂停 → 手动锁屏 → （显示器休眠并行唤醒路径）→
// 唤醒不解锁 → 显示器仍休眠 → 屏幕已解锁早退 → 0.3s 延迟 tryUnlock。

import Foundation
import Cocoa

/// pauseOnWiFi 门控的当前 SSID 结果缓存：`WiFiMonitor.currentSSID` 走 CoreWLAN 同步 XPC
/// 查询，在自动解锁的关键时机于主线程直读可能阻塞数十毫秒。缓存 5 秒内的读取结果，
/// 频繁门控（每次 attemptAutoUnlock）复用，避免解锁路径卡顿。
/// 与 FUn.swift 的 bleLogThrottler 同源设计（私有 final class + 自带锁 + 文件级单例，
/// 杜绝裸全局可变竞争）；缓存的是「当前 SSID 读取值」，与目标 SSID 无关，故改目标无需失效。
private final class PauseOnWiFiSSIDCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: (ssid: String?, timestamp: Date)?

    /// 命中且未过期返回 (true, 缓存值)；否则返回 (false, nil)，由调用方重读并回填。
    func value(now: Date, maxAge: TimeInterval) -> (fresh: Bool, ssid: String?) {
        lock.lock()
        defer { lock.unlock() }
        if let c = cached, now.timeIntervalSince(c.timestamp) < maxAge { return (true, c.ssid) }
        return (false, nil)
    }

    func store(_ ssid: String?, now: Date) {
        lock.lock()
        defer { lock.unlock() }
        cached = (ssid, now)
    }
}

private let pauseOnWiFiSSIDCache = PauseOnWiFiSSIDCache()

extension UnlockOrchestrator {

    // MARK: - 核心：自动解锁

    func attemptAutoUnlock() {
        let m = manager
        let snap = m.fun.signalSnapshot()
        let sys = SystemInteractionService.shared
        let screenLocked = sys.isScreenLocked(screenState: m.state.screen)
        timingLog("attemptAutoUnlock | presence=\(snap.presence) screen=\(m.state.screen) system=\(m.state.system) rssi=\(String(format: "%.1f", snap.effectiveRSSI)) locked=\(screenLocked)")
        Log.sm.debug("attemptAutoUnlock presence=\(snap.presence) screen=\(m.state.screen) wakeWO=\(m.prefs.bool(forKey: "wakeWithoutUnlocking")) locked=\(screenLocked)")
        guard snap.presence else { Log.sm.info("SKIP: no presence"); timingLog("SKIP noPresence"); recordUnlock(reason: .noPresence); return }
        guard m.fun.unlockRSSI != FUn.UNLOCK_DISABLED else { Log.sm.info("SKIP: unlock disabled"); timingLog("SKIP unlockDisabled"); recordUnlock(reason: .unlockDisabled); return }
        // 信号门控：唤醒路径（onSystemWake/onDisplayWake/startWakeRetry）的 presence 可能残留为 true，
        // 与 onDeviceApproached 的到位门控保持一致，信号不足（如已衰减）时拒绝解锁
        guard snap.effectiveRSSI >= Double(m.fun.unlockRSSI) else {
            Log.sm.debug("SKIP: signal below unlock threshold (\(String(format: "%.1f", snap.effectiveRSSI)))")
            timingLog("SKIP signalBelowThreshold rssi=\(String(format: "%.1f", snap.effectiveRSSI)) unlock=\(m.fun.unlockRSSI)")
            recordUnlock(reason: .signalBelowThreshold, detail: "信号 \(String(format: "%.1f", snap.effectiveRSSI)) dBm 低于解锁阈值 \(m.fun.unlockRSSI) dBm")
            return
        }
        // 状态机门控：degraded 或失败冷却期间拒绝解锁
        guard m.stateMachine.canAttemptUnlock else { Log.sm.info("SKIP: state machine not ready (degraded/cooldown)"); timingLog("SKIP stateMachineBlocked"); recordUnlock(reason: .stateMachineBlocked); return }

        // 锁屏缓冲：刚锁屏后不立即尝试解锁，防止刚离开又回来的抖动
        let sinceLock = now.timeIntervalSince(m.lastLockTime)
        guard sinceLock >= m.lockBufferDuration else {
            Log.sm.debug("SKIP: lock buffer active (locked \(String(format: "%.1f", sinceLock))s ago)")
            timingLog("SKIP lockBufferActive sinceLock=\(String(format: "%.1f", sinceLock))s")
            recordUnlock(reason: .lockBufferActive, detail: "\(String(format: "%.1f", sinceLock)) 秒前已锁定")
            return
        }

        // 解锁冷却：成功解锁后短时间内不重复尝试，防止密码风暴
        if m.isUnlockCooldownActive() {
            Log.sm.debug("SKIP: unlock cooldown active (\(String(format: "%.1f", self.now.timeIntervalSince(m.lastUnlockTime)))s since last unlock)")
            timingLog("SKIP unlockCooldownActive sinceUnlock=\(String(format: "%.1f", now.timeIntervalSince(m.lastUnlockTime)))s")
            recordUnlock(reason: .unlockCooldownActive, detail: "距上次解锁 \(String(format: "%.1f", self.now.timeIntervalSince(m.lastUnlockTime))) 秒")
            return
        }

        // Wi-Fi SSID 暂停：连接指定 Wi-Fi 时跳过自动解锁
        if m.prefs.bool(forKey: "pauseOnWiFi") {
            let targetSSID = m.prefs.string(forKey: "pauseOnWiFiSSID") ?? ""
            if !targetSSID.isEmpty {
                // 复用 5s 内的当前 SSID 缓存，避免解锁关键时机在主线程同步 CoreWLAN XPC 查询阻塞数十毫秒
                let hit = pauseOnWiFiSSIDCache.value(now: now, maxAge: 5)
                let currentSSID: String?
                if hit.fresh {
                    currentSSID = hit.ssid
                } else {
                    currentSSID = WiFiMonitor.shared.currentSSID
                    pauseOnWiFiSSIDCache.store(currentSSID, now: now)
                }
                if let currentSSID, currentSSID == targetSSID {
                    Log.sm.debug("SKIP: pauseOnWiFi matched SSID '\(targetSSID)'")
                    recordUnlock(reason: .wifiPaused, detail: "WiFi '\(targetSSID)'")
                    return
                }
            }
        }
        // #5: 手动锁屏后不自动解锁（deadline 语义已含 60s/24h 区分，不依赖键是否缺失）
        if m.state.intent.isManualLockActive {
            Log.sm.debug("SKIP: manualLock active, waiting for manual unlock")
            recordUnlockThrottled(.manualLockActive)
            return
        }
        // 优化 2: 显示器休眠时，唤醒和解锁并行 — 先唤醒，同时启动延迟解锁任务
        // 注入前奏：系统休眠中不注入密码
        if m.state.screen == .displaySleeping && m.state.system == .awake
            && m.prefs.bool(forKey: "wakeOnProximity")
            && isSystemReadyForUnlock() {
            Log.sm.debug("starting parallel wake + unlock")
            timingLog("parallel wake path | displaySleeping + systemAwake, RSSI=\(String(format: "%.1f", snap.effectiveRSSI))")
            startWakeRetry()
            // 到位解锁：平滑信号达到解锁阈值 unlockRSSI 时才并行解锁
            if snap.effectiveRSSI >= Double(m.fun.unlockRSSI) {
                // 并行：等 0.8s 后尝试解锁，不等唤醒完成
                unlockTask?.cancel()
                unlockTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 800_000_000) // 0.8s
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    guard !self.manager.state.intent.isManualLockActive else { Log.sm.debug("SKIP: manualLock active in parallel wake task"); return }
                    // 「只唤醒不解锁」开关同样约束并行解锁任务（与主路径 wakeWithoutUnlocking 门控一致）
                    guard !self.manager.prefs.bool(forKey: "wakeWithoutUnlocking") else { Log.sm.debug("SKIP: wakeWithoutUnlocking in parallel wake task"); timingLog("SKIP wakeWithoutUnlocking in parallel task"); self.recordUnlock(reason: .wakeWithoutUnlocking); return }
                    timingLog("parallel unlock task fired after 0.8s")
                    guard self.isSystemReadyForUnlock() else { Log.sm.debug("SKIP: system not ready in parallel wake task"); timingLog("SKIP systemNotReady in parallel task"); self.recordUnlock(reason: .systemNotReady); return }
                    self.tryUnlock()
                }
            } else {
                Log.sm.debug("pre-wake only: effectiveRSSI=\(String(format: "%.1f", snap.effectiveRSSI)) < unlockRSSI=\(m.fun.unlockRSSI)")
            }
            return
        }

        guard !m.prefs.bool(forKey: "wakeWithoutUnlocking") else { Log.sm.debug("SKIP: wakeWithoutUnlocking"); timingLog("SKIP wakeWithoutUnlocking"); recordUnlock(reason: .wakeWithoutUnlocking); return }
        guard m.state.screen != .displaySleeping else { Log.sm.debug("SKIP: still displaySleeping"); timingLog("SKIP stillDisplaySleeping"); recordUnlock(reason: .displaySleeping); return }

        // 屏幕已解锁：无需尝试解锁，直接早退，避免每轮 RSSI 轮询走到 guardFetchPassword 刷 screenNotLocked 噪音日志
        // （放在所有 SKIP 决策记录之后，保留 noPresence/unlockDisabled 等低频决策的仪表化语义）
        guard screenLocked else { Log.sm.debug("SKIP: screen already unlocked"); return }

        // 屏幕已锁定等 0.3s
        let delay: UInt64 = 300_000_000
        unlockTask?.cancel()
        unlockTask = Task { @MainActor [weak self] in
            Log.sm.debug("unlockTask STARTED — sleeping \(delay / 1_000_000)ms, isScreenLocked=\(SystemInteractionService.shared.isScreenLocked(screenState: self?.manager.state.screen ?? .unlocked))")
            timingLog("delayed unlock task started | sleep 0.3s")
            try? await Task.sleep(nanoseconds: UInt64(delay))
            guard !Task.isCancelled else { Log.sm.debug("unlockTask CANCELLED after sleep"); timingLog("delayed unlock task cancelled"); return }
            guard let self else { return }
            guard !self.manager.state.intent.isManualLockActive else { Log.sm.debug("SKIP: manualLock active in delayed unlock task"); return }
            guard self.isSystemReadyForUnlock() else { Log.sm.debug("SKIP: system not ready in delayed unlock task"); timingLog("SKIP systemNotReady in delayed task"); self.recordUnlock(reason: .systemNotReady); return }
            Log.sm.debug("unlockTask WOKE — isScreenLocked=\(SystemInteractionService.shared.isScreenLocked(screenState: self.manager.state.screen))")
            timingLog("delayed unlock task fired | tryUnlock")
            self.tryUnlock()
        }
    }

    // MARK: - 显示器唤醒重试 (async/await 替代 Timer)

    func startWakeRetry() {
        manager.state.wake = .pending
        manager.state.screen = .locked(reason: .away)
        timingLog("startWakeRetry begin")

        wakeTask?.cancel()
        wakeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // defer 兜底：无论取消/成功/失败，都释放 wake assertion 并复位唤醒请求标记，
            // 防止 assertion 泄漏（显示器无法自动熄屏）与 displayWakeRequested 卡死（唤醒功能失效）
            defer {
                funlock_releaseWakeAssertion()
                self.displayWakeRequested = false
            }
            for attempt in 0..<10 {
                guard !Task.isCancelled else { return }
                funlock_wakeDisplay()
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s（优化：从 1s 降到 0.5s）
                timingLog("wake attempt=\(attempt) done | locked=\(!SystemInteractionService.shared.isScreenLocked(screenState: self.manager.state.screen))")
                // wakeDisplay() 不一定触发 screensDidWakeNotification，
                // 直接检测屏幕是否已解锁
                if self.manager.state.wake == .succeeded || !SystemInteractionService.shared.isScreenLocked(screenState: self.manager.state.screen) {
                    self.manager.state.wake = .succeeded
                    timingLog("wake succeeded")
                    self.attemptAutoUnlock()
                    return
                }
            }
            self.manager.state.wake = .failed
            timingLog("wake failed after 10 retries")
            self.attemptAutoUnlock()
        }
    }
}
