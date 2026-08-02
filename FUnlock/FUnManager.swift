// BluetoothManager.swift
// 核心状态机：收编所有锁屏/解锁决策逻辑
// 使用 Combine 暴露状态，async/await 替代 Timer

import Foundation
import Combine
import Cocoa

/// 写入文件诊断日志（不依赖 os.Logger，debug 级别不会被过滤）
private func _log(component: String, _ message: String) {
    let ts = _df.string(from: Date())
    let line = "[\(ts)] [\(component)] \(message)\n"
    if let data = line.data(using: .utf8) {
        let fh = FileHandle(forWritingAtPath: "/tmp/funlock_debug.log")
        fh?.seekToEndOfFile()
        fh?.write(data)
        fh?.closeFile()
    }
}
private let _df: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

// MARK: - 状态枚举

enum ScreenState: Equatable, CustomStringConvertible {
    case unlocked
    case locked(reason: LockReason)
    case screensaver
    case displaySleeping

    enum LockReason: Equatable {
        case away, lost, manual, timeout
    }

    var description: String {
        switch self {
        case .unlocked: return "unlocked"
        case .locked(let reason): return "locked(\(reason))"
        case .screensaver: return "screensaver"
        case .displaySleeping: return "displaySleeping"
        }
    }
}

enum SystemPowerState: Equatable, CustomStringConvertible {
    case awake, sleeping

    var description: String {
        switch self {
        case .awake: return "awake"
        case .sleeping: return "sleeping"
        }
    }
}

enum LockIntent: Equatable {
    case autoLock
    case manualLock(deadline: Date)

    var isManualLockActive: Bool {
        if case .manualLock(let deadline) = self { return Date() < deadline }
        return false
    }
}

enum WakePhase: Equatable {
    case idle, pending, succeeded, failed
}

enum MediaPlaybackState: Equatable {
    case idle, wasPlaying, paused
}

// MARK: - 聚合状态

struct LockScreenState: Equatable {
    var screen: ScreenState = .unlocked
    var system: SystemPowerState = .awake
    var intent: LockIntent = .autoLock
    var wake: WakePhase = .idle
    var media: MediaPlaybackState = .idle
    var unlockedAt: Date = .distantPast

    var canAutoUnlock: Bool {
        if intent.isManualLockActive { return false }
        if system == .sleeping { return false }
        if screen == .displaySleeping { return false }
        return true
    }

    var isEffectivelyLocked: Bool {
        switch screen {
        case .locked, .screensaver, .displaySleeping: return true
        case .unlocked: return false
        }
    }
}

// MARK: - FUnManager

@MainActor
final class FUnManager: ObservableObject {

    // MARK: Published state

    @Published private(set) var state = LockScreenState()
    @Published var rssi: Int? = nil
    @Published var connected: Bool = false
    @Published var discoveredDevices: [Device] = []
    @Published var monitoredDeviceName: String? = nil
    @Published var lockRSSI: Int = -80
    @Published var unlockRSSI: Int = -60
    @Published var thresholdVersion: Int = 0

    // MARK: Dependencies

    let fun: FUn
    let stateMachine: FUnlockStateMachine
    let decisionLogger: DecisionLogger
    var inputMonitor: InputActivityMonitor?
    var isSelfLocking = false  // 区分 FUnlock 自动锁屏 vs 用户手动锁屏
    private let updateChecker = UpdateChecker()
    private let downloader = UpdateDownloader()
    private(set) var updateState: UpdateDownloader.State = .idle
    private let prefs = UserDefaults.standard
    private var wakeTask: Task<Void, Never>?
    private var unlockTask: Task<Void, Never>?
    private var intrudeCheckTask: Task<Void, Never>?
    private var displayWakeRequested = false
    private var consecutiveUnlockAttempts = 0
    private let maxUnlockAttempts = 3
    private var lastAXRevokedAlertTime: Date = .distantPast
    private var mediaWasPlaying = false

    // MARK: - 冷却与缓冲策略（可测试时间源）
    private var nowProvider: () -> Date = { Date() }
    private var now: Date { nowProvider() }
    /// 解锁成功后的冷却时间（秒），冷却期内不重复尝试解锁
    var unlockCooldownDuration: TimeInterval = 5.0
    /// 自动锁屏后的缓冲时间（秒），缓冲期内不尝试自动解锁
    var lockBufferDuration: TimeInterval = 0.8
    /// 上次自动锁屏的时间（通过 onDeviceLeft 触发）
    var lastLockTime: Date = .distantPast
    /// 上次成功解锁的时间（自动或手动解锁时更新）
    var lastUnlockTime: Date = .distantPast

    // MARK: - 决策记录辅助

    private func recordUnlock(_ outcome: DecisionOutcome = .skipped, reason: DecisionReason?, detail: String = "") {
        decisionLogger.record(category: .unlock, outcome: outcome, reason: reason,
                              rssi: rssi, device: monitoredDeviceName,
                              screen: state.screen.description, detail: detail)
    }

    private func recordLock(_ reason: DecisionReason, detail: String = "") {
        decisionLogger.record(category: .lock, outcome: .success, reason: reason,
                              rssi: rssi, device: monitoredDeviceName,
                              screen: state.screen.description, detail: detail)
    }

    private func recordSystem(_ reason: DecisionReason) {
        decisionLogger.record(category: .system, outcome: .info, reason: reason,
                              rssi: rssi, device: monitoredDeviceName,
                              screen: state.screen.description)
    }

    private func recordUser(_ reason: DecisionReason) {
        decisionLogger.record(category: .user, outcome: .success, reason: reason,
                              rssi: rssi, device: monitoredDeviceName,
                              screen: state.screen.description)
    }

    // MARK: - 异常解锁频率检测（滑动窗口）
    private var unlockAttemptTimestamps: [Date] = []
    private let maxAttemptsInWindow = 10          // 窗口内最多允许10次
    private let detectionWindow: TimeInterval = 300  // 5分钟窗口
    private var lastAbnormalAlertTime: Date = .distantPast

    // MARK: Init

    init(fun: FUn, nowProvider: @escaping () -> Date = { Date() }, decisionLogger: DecisionLogger = .shared) {
        self.fun = fun
        self.stateMachine = FUnlockStateMachine(nowProvider: nowProvider)
        self.nowProvider = nowProvider
        self.decisionLogger = decisionLogger
        self.lockRSSI = fun.lockRSSI
        self.unlockRSSI = fun.unlockRSSI

        // 接线：updateChecker → downloader → installer
        updateChecker.onNewVersion = { [weak self] version in
            self?.downloader.download(version: version)
        }
        downloader.onStateChange = { [weak self] state in
            self?.updateState = state
            if case .completed(let appPath) = state {
                try? UpdateInstaller.install(appPath: appPath)
            }
        }
    }

    deinit {
        wakeTask?.cancel()
        unlockTask?.cancel()
        intrudeCheckTask?.cancel()
    }

    // MARK: - 阈值同步

    func setLockRSSI(_ value: Int) {
        lockRSSI = value
        fun.lockRSSI = value
        UserDefaults.standard.set(value, forKey: "lockRSSI")
        thresholdVersion += 1
    }

    func setUnlockRSSI(_ value: Int) {
        unlockRSSI = value
        fun.unlockRSSI = value
        UserDefaults.standard.set(value, forKey: "unlockRSSI")
        thresholdVersion += 1
    }

    // MARK: - 扫描控制

    func startScanning() {
        fun.startScanning()
    }

    func stopScanning() {
        fun.stopScanning()
    }

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
        wakeTask?.cancel()
        wakeTask = nil
        if state.screen == .displaySleeping {
            state.screen = .locked(reason: .away)
        }
        attemptAutoUnlock()
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
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            NSApp.setActivationPolicy(.accessory)
            self.state.system = .awake
            self.attemptAutoUnlock()
        }
    }

    /// 用户主动干预（如手动唤醒屏幕）时调用，强制状态机回到 active
    func onUserIntervention() {
        Log.sm.debug("[SM] userIntervention — force reset to active")
        stateMachine.resetToActive()
        wakeTask?.cancel()
        wakeTask = nil
        unlockTask?.cancel()
        unlockTask = nil
    }

    func onUnlock() {
        Log.sm.debug("[SM] userUnlocked")
        state.screen = .unlocked
        state.unlockedAt = Date()
        state.intent = .autoLock
        consecutiveUnlockAttempts = 0
        lastUnlockTime = now
        recordUser(.userUnlocked)
        recordUnlockSuccess()
        // 状态机：用户解锁成功 → 重置为 active（退出降级/冷却）
        Task { stateMachine.resetToActive() }

        // 2 秒后检查是否为入侵（非 FUn 自动解锁）
        intrudeCheckTask?.cancel()
        intrudeCheckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            if Date().timeIntervalSince1970 >= self.state.unlockedAt.timeIntervalSince1970 + 10 {
                if self.fun.unlockRSSI != self.fun.UNLOCK_DISABLED {
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
        if isSelfLocking {
            // FUnlock 自动锁屏，不标记为手动锁定
            isSelfLocking = false
            state.intent = .autoLock
        } else {
            // 用户手动锁屏（⌘+Ctrl+Q 等）
            let deadline = prefs.bool(forKey: "manualLockNoAutoUnlock")
                ? Date().addingTimeInterval(86400)  // 24h: 等待手动解锁
                : Date().addingTimeInterval(60)
            state.intent = .manualLock(deadline: deadline)
            recordUser(.userLocked)
        }
        state.screen = .locked(reason: .manual)
        state.unlockedAt = Date(timeIntervalSince1970: 0)
        lastLockTime = now
    }

    // MARK: - FUn 设备事件

    func onDeviceApproached() {
        guard prefs.bool(forKey: "enabled") else { return }
        guard fun.unlockRSSI != fun.UNLOCK_DISABLED else { return }

        // 清除锁屏通知
        SystemInteractionService.shared.clearLockNotification()

        // 阶梯唤醒：平滑信号达到 preWakeThreshold（-60dBm）时唤醒显示器
        let smoothed = fun.effectiveRSSI
        if state.screen == .displaySleeping
            && prefs.bool(forKey: "wakeOnProximity")
            && !displayWakeRequested
            && smoothed >= Double(fun.preWakeThreshold) {
            displayWakeRequested = true
            startWakeRetry()
        }

        // 阶梯解锁：平滑信号达到 unlockStairThreshold（-50dBm）时才尝试解锁
        if smoothed >= Double(fun.unlockStairThreshold) {
            attemptAutoUnlock()
        }
    }

    func onDeviceLeft(reason: String) {
        guard prefs.bool(forKey: "enabled") else { return }
        guard state.screen == .unlocked else { return }
        guard fun.lockRSSI != fun.LOCK_DISABLED else { return }

        displayWakeRequested = false
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
        // P3: 形子模式遥测 — 记录自动锁屏事件
        TelemetryLogger.shared.log(
            event: .autoLock,
            deviceModel: monitoredDeviceName,
            rawRSSI: rssi ?? -100,
            kalmanRSSI: fun.pipeline.kalmanEstimate,
            effectiveRSSI: fun.effectiveRSSI,
            slope: fun.pipeline.smoothedSlope,
            isAnomalous: fun.lastSignalAnomalous
        )

    }

    func onRSSIUpdated(rssi: Int?, active: Bool) {
        self.rssi = rssi

        // 预备唤醒：平滑 RSSI >= preWakeThreshold 时唤醒显示器（不等到解锁阈值）
        if let rssi = rssi, !displayWakeRequested,
           state.screen == .displaySleeping,
           prefs.bool(forKey: "wakeOnProximity") {
            let smoothed = fun.smoothedRSSI(rssi)
            if smoothed >= Double(fun.preWakeThreshold) {
                displayWakeRequested = true
                print("[SM] pre-wake triggered at smoothed RSSI \(String(format: "%.1f", smoothed))")
                startWakeRetry()
            }
        }
    }

    // MARK: - 设备发现

    func onDeviceDiscovered(_ device: Device) {
        if let idx = discoveredDevices.firstIndex(where: { $0.uuid == device.uuid }) {
            discoveredDevices[idx] = device
        } else {
            discoveredDevices.append(device)
        }
    }

    func onDeviceUpdated(_ device: Device) {
        if let idx = discoveredDevices.firstIndex(where: { $0.uuid == device.uuid }) {
            // Trigger @Published manually for in-place NSObject mutation
            objectWillChange.send()
            discoveredDevices[idx].rssi = device.rssi
            discoveredDevices[idx].manufacture = device.manufacture
            discoveredDevices[idx].model = device.model
        }
    }

    func onDeviceRemoved(_ device: Device) {
        discoveredDevices.removeAll { $0.uuid == device.uuid }
    }

    func selectDevice(_ device: Device) {
        fun.startMonitor(uuid: device.uuid)
        monitoredDeviceName = device.description
        prefs.set(device.uuid.uuidString, forKey: "device")
        prefs.set(device.description, forKey: "deviceName")
    }

    func unbindDevice() {
        // 断开 BLE 连接
        if let p = fun.monitoredPeripheral {
            fun.centralMgr.cancelPeripheralConnection(p)
        }
        fun.monitoredUUID = nil
        fun.monitoredUUIDs.removeAll()
        fun.monitoredPeripheral = nil
        fun.scanMode = false
        fun.stopScanning()

        // 清除所有 timer
        fun.invalidateAllTimers()
        for (_, device) in fun.devices {
            device.scanTimer?.invalidate()
            device.scanTimer = nil
        }

        // 重置状态
        fun.presence = false
        fun.signalLostCount = 0
        fun.stableCount = 0
        fun.activePollInterval = 2.0
        fun.lastEstimatedRSSI = 0
        fun.pipeline.reset()
        fun.effectiveRSSI = -60.0
        fun.displayRSSI = -60.0
        fun.resetSmoothedRSSI()

        // 清除 Manager 层状态
        monitoredDeviceName = nil
        prefs.removeObject(forKey: "device")
        prefs.removeObject(forKey: "deviceName")
        rssi = nil
        connected = false
    }

    // MARK: - 用户操作

    func lockNow() {
        guard !SystemInteractionService.shared.isScreenLocked(screenState: state.screen) else { return }
        state.intent = .manualLock(deadline: Date().addingTimeInterval(10))
        state.screen = .locked(reason: .manual)
        lastLockTime = now
        checkAndPauseMedia()
        SystemInteractionService.shared.lockOrSaveScreen(
            useScreensaver: prefs.bool(forKey: "screensaver"),
            sleepDisplayAfter: prefs.bool(forKey: "sleepDisplay"))
    }

    // MARK: - 注入前奏：解锁前置安全检查

    /// 注入前奏：检查系统是否处于适合解锁的状态（系统休眠时禁止注入）
    private func isSystemReadyForUnlock() -> Bool {
        return state.system == .awake
    }

    // MARK: - 核心：自动解锁

    func attemptAutoUnlock() {
        let sys = SystemInteractionService.shared
        let screenLocked = sys.isScreenLocked(screenState: state.screen)
        let axGranted = AXIsProcessTrusted()
        Log.sm.debug("attemptAutoUnlock presence=\(self.fun.presence) screen=\(self.state.screen) wakeWO=\(self.prefs.bool(forKey: "wakeWithoutUnlocking")) locked=\(screenLocked) ax=\(axGranted)")
        guard fun.presence else { Log.sm.debug("SKIP: no presence"); recordUnlock(reason: .noPresence); return }
        guard fun.unlockRSSI != fun.UNLOCK_DISABLED else { Log.sm.debug("SKIP: unlock disabled"); recordUnlock(reason: .unlockDisabled); return }
        // 状态机门控：degraded 或失败冷却期间拒绝解锁
        guard stateMachine.canAttemptUnlock else { Log.sm.debug("SKIP: state machine not ready (degraded/cooldown)"); recordUnlock(reason: .stateMachineBlocked); return }

        // 锁屏缓冲：刚锁屏后不立即尝试解锁，防止刚离开又回来的抖动
        let sinceLock = now.timeIntervalSince(lastLockTime)
        guard sinceLock >= lockBufferDuration else {
            Log.sm.debug("SKIP: lock buffer active (locked \(String(format: "%.1f", sinceLock))s ago)")
            recordUnlock(reason: .lockBufferActive, detail: "locked \(String(format: "%.1f", sinceLock))s ago")
            return
        }

        // 解锁冷却：成功解锁后短时间内不重复尝试，防止密码风暴
        if isUnlockCooldownActive() {
            Log.sm.debug("SKIP: unlock cooldown active (\(String(format: "%.1f", self.now.timeIntervalSince(self.lastUnlockTime)))s since last unlock)")
            recordUnlock(reason: .unlockCooldownActive, detail: "\(String(format: "%.1f", self.now.timeIntervalSince(self.lastUnlockTime)))s since last unlock")
            return
        }

        // Wi-Fi SSID 暂停：连接指定 Wi-Fi 时跳过自动解锁
        if prefs.bool(forKey: "pauseOnWiFi") {
            let targetSSID = prefs.string(forKey: "pauseOnWiFiSSID") ?? ""
            if !targetSSID.isEmpty, let currentSSID = WiFiMonitor.shared.currentSSID, currentSSID == targetSSID {
                Log.sm.debug("SKIP: pauseOnWiFi matched SSID '\(targetSSID)'")
                recordUnlock(reason: .wifiPaused, detail: "SSID '\(targetSSID)'")
                return
            }
        }
        // #5: 手动锁屏后不自动解锁
        if prefs.bool(forKey: "manualLockNoAutoUnlock") && state.intent.isManualLockActive {
            Log.sm.debug("SKIP: manualLock active, waiting for manual unlock")
            recordUnlock(reason: .manualLockActive)
            return
        }
        if !axGranted { Log.sm.debug("WARN: ax=false, trying anyway") }

        // 优化 2: 显示器休眠时，唤醒和解锁并行 — 先唤醒，同时启动延迟解锁任务
        // 注入前奏：系统休眠中不注入密码
        if state.screen == .displaySleeping && state.system == .awake
            && prefs.bool(forKey: "wakeOnProximity")
            && isSystemReadyForUnlock() {
            Log.sm.debug("starting parallel wake + unlock")
            startWakeRetry()
            // 阶梯解锁：平滑信号达到 unlockStairThreshold（-50dBm）时才并行解锁
            if fun.effectiveRSSI >= Double(fun.unlockStairThreshold) {
                // 并行：等 0.8s 后尝试解锁，不等唤醒完成
                unlockTask?.cancel()
                unlockTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 800_000_000) // 0.8s
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    guard self.isSystemReadyForUnlock() else { Log.sm.debug("SKIP: system not ready in parallel wake task"); recordUnlock(reason: .systemNotReady); return }
                    self.tryUnlock()
                }
            } else {
                Log.sm.debug("pre-wake only: effectiveRSSI=\(String(format: "%.1f", self.fun.effectiveRSSI)) < unlockStairThreshold=\(self.fun.unlockStairThreshold)")
            }
            return
        }

        guard !self.prefs.bool(forKey: "wakeWithoutUnlocking") else { Log.sm.debug("SKIP: wakeWithoutUnlocking"); recordUnlock(reason: .wakeWithoutUnlocking); return }
        guard self.state.screen != .displaySleeping else { Log.sm.debug("SKIP: still displaySleeping"); recordUnlock(reason: .displaySleeping); return }

        // 屏幕已锁定等 0.3s
        let delay: UInt64 = 300_000_000
        unlockTask?.cancel()
        unlockTask = Task {
            Log.sm.debug("unlockTask STARTED — sleeping \(delay / 1_000_000)ms, isScreenLocked=\(SystemInteractionService.shared.isScreenLocked(screenState: self.state.screen))")
            try? await Task.sleep(nanoseconds: UInt64(delay))
            guard !Task.isCancelled else { Log.sm.debug("unlockTask CANCELLED after sleep"); return }
            guard self.isSystemReadyForUnlock() else { Log.sm.debug("SKIP: system not ready in delayed unlock task"); recordUnlock(reason: .systemNotReady); return }
            Log.sm.debug("unlockTask WOKE — isScreenLocked=\(SystemInteractionService.shared.isScreenLocked(screenState: self.state.screen))")
            self.tryUnlock()
        }
    }

    // 抽取解锁逻辑（被 attemptAutoUnlock 和并行唤醒共用）
    private func tryUnlock() {
        let sys = SystemInteractionService.shared
        let sec = SecurityService.shared
        let locked = sys.isScreenLocked(screenState: state.screen)
        _log(component: "FUnManager", "tryUnlock() START - screen=\(state.screen), locked=\(locked)")
        Log.sm.debug("screen locked check: \(locked)")
        guard locked else { Log.sm.debug("SKIP: screen not locked"); recordUnlock(.info, reason: .screenNotLocked, detail: "already unlocked"); return }

        // 状态机门控：通过状态机确认解锁冷却和降级状态
        let smAllowed = stateMachine.attemptUnlock()
        guard smAllowed else { Log.sm.debug("SKIP: state machine denied unlock attempt"); recordUnlock(reason: .stateMachineBlocked); return }

        let sinceUnlock = now.timeIntervalSince1970 - state.unlockedAt.timeIntervalSince1970
        guard sinceUnlock > 3 else {
            Log.sm.debug("SKIP: recently unlocked (\(String(format:"%.1f", sinceUnlock))s ago)")
            recordUnlock(reason: .recentlyUnlocked, detail: "\(String(format: "%.1f", sinceUnlock))s ago")
            return
        }
        let fetchResult = sec.fetchPassword(warn: true)
        guard case .success(let password) = fetchResult, let password = password else {
            if case .failure(let error) = fetchResult {
                Log.sm.debug("SKIP: Keychain error - \(error)")
                recordUnlock(reason: .keychainColdBoot, detail: "\(error)")
            } else {
                Log.sm.debug("SKIP: no password")
                recordUnlock(reason: .noPassword)
            }
            return
        }
        _log(component: "FUnManager", "tryUnlock() password fetched - length=\(password.count)")

        // #6: 最后一次检查，防止等待期间指纹/Apple Watch 解锁
        let secure = sys.isSecureToInject(screenState: state.screen)
        _log(component: "FUnManager", "tryUnlock() isSecureToInject = \(secure), screen=\(state.screen)")
        guard secure else { Log.sm.debug("SKIP: screen no longer secure for injection"); recordUnlock(reason: .notSecureForInjection); return }

        Log.sm.debug("typing password (\(password.count) chars) with Shift prelude")
        self.state.unlockedAt = now
        self.lastUnlockTime = now
        _log(component: "FUnManager", "tryUnlock() calling injectPasswordWithPrelude(\(password.count) chars)")
        let posted = sys.injectPasswordWithPrelude(password) {
            self.state.screen != .unlocked
            && sys.isSecureToInject(screenState: self.state.screen)
        }
        _log(component: "FUnManager", "tryUnlock() injectPasswordWithPrelude returned posted=\(posted)")
        Log.sm.debug("fakeKeyStrokes done — posted=\(posted)")
        if !posted {
            Log.sm.debug("WARN: CGEvent post failed — Accessibility permission likely revoked")
            recordUnlock(.blocked, reason: .axRevoked, detail: "CGEvent post failed")
            sys.showAXRevokedAlertIfNeeded(lastAlertTime: &lastAXRevokedAlertTime)
        } else {
            recordUnlockAttempt()
            recordUnlock(.success, reason: .unlockSuccess)
            _log(component: "FUnManager", "tryUnlock() - unlock attempt posted, optimistic unlock confirmed")
            Log.sm.debug("unlock attempt posted, optimistic unlock confirmed")
            // 乐观解锁策略：密码注入后立即记录 unlock_confirmed
            let verifyStartTime = self.now
            let optimisticExtras: [String: String] = [
                "result": "success",
                "latencyMs": "0",
                "source": "proximity",
                "effectiveRSSI": String(format: "%.1f", fun.effectiveRSSI),
                "device": monitoredDeviceName ?? "unknown"
            ]
            ScriptRunner.shared.logEventIfNeeded("unlock_confirmed", rssi: rssi, extraFields: optimisticExtras)
            // 双保险验证：通知 + CGSession 竞速（withTaskGroup），替代旧的0.5秒固定延时
            Task { [weak self] in
                let sys = SystemInteractionService.shared
                let verification = await sys.verifyUnlock(timeout: 2.0, notificationTimeout: 1.0)
                guard let self else { return }
                if verification.unlock {
                    // 通知或 CGSession 确认解锁成功
                    Log.sm.debug("dual verify: unlock confirmed")
                    self.consecutiveUnlockAttempts = 0
                    _log(component: "FUnManager", "tryUnlock() - dual verify passed, counter reset")
                    Task { self.stateMachine.handleUnlockSuccess() }
                } else {
                    // 通知和 CGSession 都未确认解锁 → 可能密码错误
                    let stillLocked = sys.isScreenLocked(screenState: self.state.screen)
                    if stillLocked {
                        self.consecutiveUnlockAttempts += 1
                        Log.sm.debug("dual verify: still locked → #\(self.consecutiveUnlockAttempts)/\(self.maxUnlockAttempts)")
                        recordUnlock(.failed, reason: .unlockFailed, detail: "attempt #\(self.consecutiveUnlockAttempts)/\(self.maxUnlockAttempts)")
                        _log(component: "FUnManager", "tryUnlock() - dual verify failed, attempts=\(self.consecutiveUnlockAttempts)/\(self.maxUnlockAttempts)")
                        Task { self.stateMachine.handleUnlockFailure() }
                        let failExtras: [String: String] = [
                            "result": "fail",
                            "latencyMs": "0",
                            "source": "proximity",
                            "effectiveRSSI": String(format: "%.1f", self.fun.effectiveRSSI),
                            "device": self.monitoredDeviceName ?? "unknown"
                        ]
                        ScriptRunner.shared.logEventIfNeeded("unlock_failed", rssi: self.rssi, extraFields: failExtras)
                        _log(component: "FUnManager", "tryUnlock() - unlock_failed recorded, attempts=\(self.consecutiveUnlockAttempts)/\(self.maxUnlockAttempts)")
                        if self.consecutiveUnlockAttempts >= self.maxUnlockAttempts {
                            recordUnlock(.blocked, reason: .passwordMismatch, detail: "too many failed attempts")
                            sys.showPasswordMismatchAlert()
                            self.consecutiveUnlockAttempts = 0
                        }
                    } else {
                        // CGSession 也显示已解锁（竞态下可能延迟发现）
                        Log.sm.debug("dual verify: timeout but CGSession says unlocked")
                        self.consecutiveUnlockAttempts = 0
                        _log(component: "FUnManager", "tryUnlock() - dual verify timeout but screen unlocked, counter reset")
                        Task { self.stateMachine.handleUnlockSuccess() }
                    }
                }
            }
            resumeMediaIfNeeded()
            ScriptRunner.shared.runScript("unlocked", rssi: rssi, deviceName: monitoredDeviceName)
            ScriptRunner.shared.logEvent("unlocked", rssi: rssi)
            // P3: 形子模式遥测 — 记录自动解锁事件
            TelemetryLogger.shared.log(
                event: .autoUnlock,
                deviceModel: monitoredDeviceName,
                rawRSSI: rssi ?? -100,
                kalmanRSSI: fun.pipeline.kalmanEstimate,
                effectiveRSSI: fun.effectiveRSSI,
                slope: fun.pipeline.smoothedSlope,
                isAnomalous: fun.lastSignalAnomalous
            )
            Log.sm.debug("unlock complete")
        }
    }

    // MARK: - 显示器唤醒重试 (async/await 替代 Timer)

    private func startWakeRetry() {
        state.wake = .pending
        state.screen = .locked(reason: .away)

        wakeTask?.cancel()
        wakeTask = Task {
            for attempt in 0..<10 {
                guard !Task.isCancelled else { return }
                if attempt > 0 {
                    print("[SM] retrying wake #\(attempt)")
                }
                funlock_wakeDisplay()
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s（优化：从 1s 降到 0.5s）
                // wakeDisplay() 不一定触发 screensDidWakeNotification，
                // 直接检测屏幕是否已解锁
                if state.wake == .succeeded || !SystemInteractionService.shared.isScreenLocked(screenState: state.screen) {
                    state.wake = .succeeded
                    funlock_releaseWakeAssertion()
                    self.attemptAutoUnlock()
                    return
                }
            }
            print("[SM] wake failed after 10 retries")
            state.wake = .failed
            funlock_releaseWakeAssertion()
            self.attemptAutoUnlock()
        }
    }

    // MARK: - Now Playing（委托 SystemInteractionService）

    private func checkAndPauseMedia() {
        guard prefs.bool(forKey: "pauseItunes") else { return }
        state.media = .idle
        SystemInteractionService.shared.checkAndPauseMedia(enabled: true) { [weak self] playing in
            self?.mediaWasPlaying = playing
            self?.state.media = playing ? .wasPlaying : .paused
        }
    }

    private func resumeMediaIfNeeded() {
        guard prefs.bool(forKey: "pauseItunes") else { return }
        guard state.media == .wasPlaying else { return }
        SystemInteractionService.shared.resumeMediaIfNeeded(wasPlaying: mediaWasPlaying, enabled: true)
        state.media = .idle
    }

    // 屏幕操作、键盘注入、Keychain、通知、日志、脚本 — 已迁移至
    // SystemInteractionService / SecurityService / ScriptRunner

    func checkUpdate() {
        updateChecker.check()
    }

    /// 手动触发检查更新
    func forceCheckUpdate(completion: ((String?) -> Void)? = nil) {
        updateChecker.forceCheck(completion: completion)
    }

    // MARK: - 清理（退出时调用，防止 RunLoop Timer 崩溃）

    func cleanup() {
        // 退出时不要同步 invalidate Timer —— RunLoop 正在销毁 Timer 列表，
        // 同步 invalidate 会导致 __CFRunLoopDeallocateTimers 数组越界崩溃。
        // 延迟到下一个 RunLoop 迭代（退出时不会执行，Timer 随 RunLoop 一起释放）。
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.fun.invalidateAllTimers()
            for (_, device) in self.fun.devices {
                device.scanTimer?.invalidate()
                device.scanTimer = nil
            }
            funlock_releaseWakeAssertion()
        }
        wakeTask?.cancel()
        unlockTask?.cancel()
        intrudeCheckTask?.cancel()
        Task { stateMachine.cancelActiveTask() }
    }

    // MARK: - UI 辅助

    /// 记录一次解锁尝试（失败时调用），滑动窗口检测异常频率
    private func recordUnlockAttempt() {
        let now = Date()
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
                    event: .abnormalAlert,
                    deviceModel: self.monitoredDeviceName,
                    rawRSSI: self.rssi ?? -100,
                    kalmanRSSI: self.fun.pipeline.kalmanEstimate,
                    effectiveRSSI: self.fun.effectiveRSSI,
                    slope: self.fun.pipeline.smoothedSlope,
                    isAnomalous: true
                )
                lastAbnormalAlertTime = now
            }
        }
    }

    /// 成功解锁后清除失败记录
    private func recordUnlockSuccess() {
        unlockAttemptTimestamps.removeAll()
    }

    // MARK: - 冷却与缓冲检查

    /// 解锁冷却期内（成功解锁后 unlockCooldownDuration 秒内）返回 true
    func isUnlockCooldownActive() -> Bool {
        now.timeIntervalSince(lastUnlockTime) < unlockCooldownDuration
    }

    /// 锁屏缓冲期内（自动锁屏后 lockBufferDuration 秒内）返回 true
    func isLockBufferActive() -> Bool {
        now.timeIntervalSince(lastLockTime) < lockBufferDuration
    }

    // MARK: - 便利属性

    var isDeviceConnected: Bool { connected }

    func updateConnected(_ newValue: Bool) {
        connected = newValue
    }
}

// MARK: - 解锁结果确认辅助结构体

/// 解锁结果确认结构体：封装屏幕锁定状态检查，按解锁结果拆分事件名。
/// 成功 → `unlock_confirmed`，失败 → `unlock_failed`。
/// 在 tryUnlock 的 CGEvent 发送后，2 秒延时检查屏幕状态时创建并使用。
struct FUnlockResultVerifier {
    private let isStillLocked: () -> Bool
    private let startTime: Date
    private let source: String
    private let effectiveRSSI: Double?
    private let device: String?

    /// 初始化器
    /// - Parameters:
    ///   - isStillLocked: 闭包返回 true 表示屏幕仍锁定（解锁失败）
    ///   - startTime: 解锁流程开始时间，用于计算延迟
    ///   - source: 解锁触发来源（如 "proximity" / "wake"）
    ///   - effectiveRSSI: 解锁时的有效 RSSI 值
    ///   - device: 监控设备名称
    init(
        isStillLocked: @escaping () -> Bool,
        startTime: Date = Date(),
        source: String = "proximity",
        effectiveRSSI: Double? = nil,
        device: String? = nil
    ) {
        self.isStillLocked = isStillLocked
        self.startTime = startTime
        self.source = source
        self.effectiveRSSI = effectiveRSSI
        self.device = device
    }

    /// 结果字符串：成功 → "success"，失败 → "fail"
    var result: String { isStillLocked() ? "fail" : "success" }

    /// 解锁是否成功
    var succeeded: Bool { !isStillLocked() }

    /// 延迟毫秒数（从 startTime 到调用时的经过时间）
    var latencyMs: Int {
        Int(Date().timeIntervalSince(startTime) * 1000)
    }

    /// 事件名：成功 → unlock_confirmed，失败 → unlock_failed
    var eventName: String { succeeded ? "unlock_confirmed" : "unlock_failed" }

    /// 写入扩展事件日志，返回实际写入的日志行（方便测试断言）
    func logUnlockResult() -> String {
        var extras: [String: String] = ["result": result]
        extras["latencyMs"] = String(latencyMs)
        extras["source"] = source
        if let rssi = effectiveRSSI {
            extras["effectiveRSSI"] = String(format: "%.1f", rssi)
        }
        if let name = device {
            extras["device"] = name
        }
        let line = ScriptRunner.shared.buildEventLine(eventName, rssi: nil, extraFields: extras)
        ScriptRunner.shared.logEventIfNeeded(eventName, rssi: nil, extraFields: extras)
        return line
    }

    // MARK: - 静态超时日志

    /// 事件名：验证超时（Task 被取消或未在合理时间内完成）
    static let timeoutEventName = "unlock_timeout"

    /// 记录超时事件（无需创建 verifier 实例）
    /// - Parameters:
    ///   - startTime: 解锁流程开始时间，用于计算延迟
    ///   - source: 解锁触发来源
    ///   - effectiveRSSI: 解锁时的有效 RSSI 值
    ///   - device: 监控设备名称
    @discardableResult
    static func logUnlockResultTimeout(
        startTime: Date,
        source: String = "proximity",
        effectiveRSSI: Double? = nil,
        device: String? = nil
    ) -> String {
        let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)
        var extras: [String: String] = ["result": "timeout"]
        extras["latencyMs"] = String(latencyMs)
        extras["source"] = source
        if let rssi = effectiveRSSI {
            extras["effectiveRSSI"] = String(format: "%.1f", rssi)
        }
        if let name = device {
            extras["device"] = name
        }
        let line = ScriptRunner.shared.buildEventLine(timeoutEventName, rssi: nil, extraFields: extras)
        ScriptRunner.shared.logEventIfNeeded(timeoutEventName, rssi: nil, extraFields: extras)
        return line
    }
}
