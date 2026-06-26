// BluetoothManager.swift
// 核心状态机：收编所有锁屏/解锁决策逻辑
// 使用 Combine 暴露状态，async/await 替代 Timer

import Foundation
import Combine
import UserNotifications
import Cocoa
import Quartz

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
    var inputMonitor: InputActivityMonitor?
    var isSelfLocking = false  // 区分 FUnlock 自动锁屏 vs 用户手动锁屏
    private let updateChecker = UpdateChecker()
    private let downloader = UpdateDownloader()
    private(set) var updateState: UpdateDownloader.State = .idle
    private let prefs = UserDefaults.standard
    private var wakeTask: Task<Void, Never>?
    private var unlockTask: Task<Void, Never>?
    private var intrudeCheckTask: Task<Void, Never>?
    private var userNotificationId = ""
    private var displayWakeRequested = false
    private var consecutiveUnlockAttempts = 0
    private let maxUnlockAttempts = 3

    // MARK: - 异常解锁频率检测（滑动窗口）
    private var unlockAttemptTimestamps: [Date] = []
    private let maxAttemptsInWindow = 10          // 窗口内最多允许10次
    private let detectionWindow: TimeInterval = 300  // 5分钟窗口
    private var lastAbnormalAlertTime: Date = .distantPast

    // MARK: Init

    init(fun: FUn) {
        self.fun = fun
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
        Log.sm.debug("EVENT: onDisplaySleep screen=\(self.state.screen) system=\(self.state.system)")
        state.screen = .displaySleeping
    }

    func onDisplayWake() {
        Log.sm.debug("[SM] displayWake")
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
        state.system = .sleeping
        NSApp.setActivationPolicy(.regular)
    }

    func onSystemWake() {
        Log.sm.debug("[SM] systemWake")
        // 延迟 1 秒等待蓝牙栈恢复
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            NSApp.setActivationPolicy(.accessory)
            self.state.system = .awake
            self.attemptAutoUnlock()
        }
    }

    func onUnlock() {
        Log.sm.debug("[SM] userUnlocked")
        state.screen = .unlocked
        state.unlockedAt = Date()
        state.intent = .autoLock
        consecutiveUnlockAttempts = 0
        recordUnlockSuccess()

        // 2 秒后检查是否为入侵（非 FUn 自动解锁）
        intrudeCheckTask?.cancel()
        intrudeCheckTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            if Date().timeIntervalSince1970 >= state.unlockedAt.timeIntervalSince1970 + 10 {
                if fun.unlockRSSI != fun.UNLOCK_DISABLED {
                    runScript("intruded")
                    logEvent("intruded")
                }
                playNowPlaying()
            }
            checkUpdate()
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
        }
        state.screen = .locked(reason: .manual)
        state.unlockedAt = Date(timeIntervalSince1970: 0)
    }

    // MARK: - FUn 设备事件

    func onDeviceApproached() {
        guard prefs.bool(forKey: "enabled") else { return }
        guard fun.unlockRSSI != fun.UNLOCK_DISABLED else { return }

        // 清除锁屏通知
        if !userNotificationId.isEmpty {
            UNUserNotificationCenter.current()
                .removeDeliveredNotifications(withIdentifiers: [userNotificationId])
            userNotificationId = ""
        }

        // 显示器休眠中 → 确保已唤醒（早唤醒可能已触发，这里做兜底）
        if state.screen == .displaySleeping
            && prefs.bool(forKey: "wakeOnProximity")
            && !displayWakeRequested {
            displayWakeRequested = true
            startWakeRetry()
        }

        attemptAutoUnlock()
    }

    func onDeviceLeft(reason: String) {
        guard prefs.bool(forKey: "enabled") else { return }
        guard state.screen == .unlocked else { return }
        guard fun.lockRSSI != fun.LOCK_DISABLED else { return }

        displayWakeRequested = false
        state.screen = .displaySleeping
        pauseNowPlaying()
        isSelfLocking = true
        lockOrSaveScreen()
        notifyUser(reason)
        runScript(reason)
        logEvent("locked: \(reason)")
    }

    func onRSSIUpdated(rssi: Int?, active: Bool) {
        self.rssi = rssi

        // 早唤醒：信号出现且显示器休眠时，立即唤醒（不等到解锁阈值）
        if let rssi = rssi, !displayWakeRequested,
           state.screen == .displaySleeping,
           prefs.bool(forKey: "wakeOnProximity") {
            displayWakeRequested = true
            print("[SM] early wake triggered at RSSI \(rssi)")
            startWakeRetry()
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

        // 清除 Manager 层状态
        monitoredDeviceName = nil
        prefs.removeObject(forKey: "device")
        prefs.removeObject(forKey: "deviceName")
        rssi = nil
        connected = false
    }

    // MARK: - 用户操作

    func lockNow() {
        guard !isScreenLocked() else { return }
        state.intent = .manualLock(deadline: Date().addingTimeInterval(10))
        state.screen = .locked(reason: .manual)
        pauseNowPlaying()
        lockOrSaveScreen()
    }

    // MARK: - 核心：自动解锁

    private func attemptAutoUnlock() {
        let screenLocked = isScreenLocked()
        let axGranted = AXIsProcessTrusted()
        Log.sm.debug("attemptAutoUnlock presence=\(self.fun.presence) screen=\(self.state.screen) wakeWO=\(self.prefs.bool(forKey: "wakeWithoutUnlocking")) locked=\(screenLocked) ax=\(axGranted)")
        guard fun.presence else { Log.sm.debug("SKIP: no presence"); return }
        guard fun.unlockRSSI != fun.UNLOCK_DISABLED else { Log.sm.debug("SKIP: unlock disabled"); return }

        // Wi-Fi SSID 暂停：连接指定 Wi-Fi 时跳过自动解锁
        if prefs.bool(forKey: "pauseOnWiFi") {
            let targetSSID = prefs.string(forKey: "pauseOnWiFiSSID") ?? ""
            if !targetSSID.isEmpty, let currentSSID = WiFiMonitor.shared.currentSSID, currentSSID == targetSSID {
                Log.sm.debug("SKIP: pauseOnWiFi matched SSID '\(targetSSID)'")
                return
            }
        }
        // #5: 手动锁屏后不自动解锁
        if prefs.bool(forKey: "manualLockNoAutoUnlock") && state.intent.isManualLockActive {
            Log.sm.debug("SKIP: manualLock active, waiting for manual unlock")
            return
        }
        if !axGranted { Log.sm.debug("WARN: ax=false, trying anyway") }

        // 优化 2: 显示器休眠时，唤醒和解锁并行 — 先唤醒，同时启动延迟解锁任务
        if state.screen == .displaySleeping && state.system == .awake
            && prefs.bool(forKey: "wakeOnProximity") {
            Log.sm.debug("starting parallel wake + unlock")
            startWakeRetry()
            // 并行：等 0.8s 后尝试解锁，不等唤醒完成
            unlockTask?.cancel()
            unlockTask = Task {
                try? await Task.sleep(nanoseconds: 800_000_000) // 0.8s
                guard !Task.isCancelled else { return }
                tryUnlock()
            }
            return
        }

        guard !self.prefs.bool(forKey: "wakeWithoutUnlocking") else { Log.sm.debug("SKIP: wakeWithoutUnlocking"); return }
        guard self.state.screen != .displaySleeping else { Log.sm.debug("SKIP: still displaySleeping"); return }

        // 屏幕已锁定等 0.3s
        let delay: UInt64 = 300_000_000
        unlockTask?.cancel()
        unlockTask = Task {
            Log.sm.debug("unlockTask STARTED — sleeping \(delay / 1_000_000)ms, isScreenLocked=\(self.isScreenLocked())")
            try? await Task.sleep(nanoseconds: UInt64(delay))
            guard !Task.isCancelled else { Log.sm.debug("unlockTask CANCELLED after sleep"); return }
            Log.sm.debug("unlockTask WOKE — isScreenLocked=\(self.isScreenLocked())")
            tryUnlock()
        }
    }

    // 抽取解锁逻辑（被 attemptAutoUnlock 和并行唤醒共用）
    private func tryUnlock() {
        let locked = isScreenLocked()
        Log.sm.debug("screen locked check: \(locked)")
        guard locked else { Log.sm.debug("SKIP: screen not locked"); return }
        let sinceUnlock = Date().timeIntervalSince1970 - state.unlockedAt.timeIntervalSince1970
        guard sinceUnlock > 3 else {
            Log.sm.debug("SKIP: recently unlocked (\(String(format:"%.1f", sinceUnlock))s ago)")
            return
        }
        guard let password = fetchPassword(warn: true) else { Log.sm.debug("SKIP: no password"); return }

        // #6: 最后一次检查，防止等待期间指纹/Apple Watch 解锁
        guard isSecureToInject() else { Log.sm.debug("SKIP: screen no longer secure for injection"); return }

        Log.sm.debug("typing password (\(password.count) chars)")
        self.state.unlockedAt = Date()
        let posted = fakeKeyStrokes(password)
        Log.sm.debug("fakeKeyStrokes done — posted=\(posted)")
        if !posted {
            Log.sm.debug("WARN: CGEvent post failed — Accessibility permission likely revoked")
            showAXRevokedAlertIfNeeded()
        } else {
            self.consecutiveUnlockAttempts += 1
            recordUnlockAttempt()
            Log.sm.debug("unlock attempt #\(self.consecutiveUnlockAttempts)")
            if self.consecutiveUnlockAttempts >= self.maxUnlockAttempts {
                showPasswordMismatchAlert()
                self.consecutiveUnlockAttempts = 0
            }
        }
        playNowPlaying()
        runScript("unlocked")
        logEvent("unlocked")
        Log.sm.debug("unlock complete")
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
                wakeDisplay()
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s（优化：从 1s 降到 0.5s）
                // wakeDisplay() 不一定触发 screensDidWakeNotification，
                // 直接检测屏幕是否已解锁
                if state.wake == .succeeded || !isScreenLocked() {
                    state.wake = .succeeded
                    releaseWakeAssertion()
                    self.attemptAutoUnlock()
                    return
                }
            }
            print("[SM] wake failed after 10 retries")
            state.wake = .failed
            releaseWakeAssertion()
            self.attemptAutoUnlock()
        }
    }

    // MARK: - Now Playing

    private func pauseNowPlaying() {
        guard prefs.bool(forKey: "pauseItunes") else { return }
        state.media = .idle
        MRMediaRemoteGetNowPlayingApplicationIsPlaying(DispatchQueue.main) { [weak self] playing in
            guard let self = self else { return }
            if playing {
                self.state.media = .wasPlaying
                MRMediaRemoteSendCommand(MRCommandPause, nil)
            } else {
                self.state.media = .paused
            }
        }
    }

    private func playNowPlaying() {
        guard prefs.bool(forKey: "pauseItunes") else { return }
        guard state.media == .wasPlaying else { return }
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            MRMediaRemoteSendCommand(MRCommandPlay, nil)
            state.media = .idle
        }
    }

    // MARK: - 屏幕操作

    private func lockOrSaveScreen() {
        if prefs.bool(forKey: "screensaver") {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ScreenSaver.Engine") {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                NSWorkspace.shared.openApplication(at: url, configuration: config)
            }
        } else {
            _ = SACLockScreenImmediate()
        }
        if prefs.bool(forKey: "sleepDisplay") {
            sleepDisplay()
        }
    }

    private func isScreenLocked() -> Bool {
        // 优先用 CGSession 检测系统原生锁屏
        if let dict = CGSessionCopyCurrentDictionary() as? [String: Any] {
            if dict["CGSSessionScreenIsLocked"] as? Int == 1 { return true }
        }
        // CGSession 不覆盖屏幕保护程序，用进程检测兜底
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.ScreenSaver.Engine").count > 0 {
            return true
        }
        // 最终兜底：状态机知道屏幕是否锁着（覆盖 Cmd+Ctrl+Q 等所有场景）
        return state.screen != .unlocked
    }

    /// 双重安全检查：确保密码注入时屏幕确实锁定且前台是 loginwindow
    private func isSecureToInject() -> Bool {
        // 检查1: 系统锁屏状态
        guard isScreenLocked() else { return false }
        // 检查2: 前台应用必须是 loginwindow
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           frontApp.bundleIdentifier != "com.apple.loginwindow" {
            Log.sm.debug("ABORT: frontmost=\(frontApp.bundleIdentifier ?? "nil"), not loginwindow")
            return false
        }
        return true
    }

    // MARK: - 键盘模拟

    private func fakeKeyStrokes(_ string: String) -> Bool {
        // 直接尝试 CGEvent（不依赖 AXIsProcessTrusted，它对 agent 应用不可靠）
        return fakeKeyStrokesCGEvent(string)
    }

    @discardableResult
    private func fakeKeyStrokesCGEvent(_ string: String) -> Bool {
        let src = CGEventSource(stateID: .hidSystemState)
        var anyEventPosted = false
        let uniCharCount = string.utf16.count
        var strIndex = string.utf16.startIndex
        for offset in stride(from: 0, to: uniCharCount, by: 20) {
            // 每批按键前双重检查：屏幕仍锁定 + 前台仍是 loginwindow
            guard isSecureToInject() else {
                Log.sm.debug("ABORT: screen no longer secure during keystroke injection")
                return anyEventPosted
            }
            let pressEvent = CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: true)
            let len = offset + 20 < uniCharCount ? 20 : uniCharCount - offset
            let buffer = UnsafeMutablePointer<UniChar>.allocate(capacity: len)
            defer { buffer.deallocate() }
            for i in 0..<len {
                buffer[i] = string.utf16[strIndex]
                strIndex = string.utf16.index(after: strIndex)
            }
            pressEvent?.keyboardSetUnicodeString(stringLength: len, unicodeString: buffer)
            pressEvent?.post(tap: .cgSessionEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: false)?.post(tap: .cgSessionEventTap)
            if pressEvent != nil { anyEventPosted = true }
        }
        // Return 键发送前再次确认
        guard isSecureToInject() else {
            Log.sm.debug("ABORT: screen no longer secure before Return key")
            return anyEventPosted
        }
        let returnDown = CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: true)
        let returnUp = CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: false)
        returnDown?.post(tap: .cgSessionEventTap)
        returnUp?.post(tap: .cgSessionEventTap)
        if returnDown != nil { anyEventPosted = true }
        return anyEventPosted
    }

    // MARK: - Keychain

    func storePassword(_ password: String) {
        guard let pw = password.data(using: .utf8) else { return }
        let query: [String: Any] = [
            String(kSecClass): kSecClassGenericPassword,
            String(kSecAttrAccount): NSUserName(),
            String(kSecAttrService): Bundle.main.bundleIdentifier ?? "FUnlock",
            String(kSecAttrLabel): "FUnlock",
            String(kSecAttrAccessible): kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            String(kSecValueData): pw,
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            let err = SecCopyErrorMessageString(status, nil)
            errorModal(t("failed_store_password"), info: err as String? ?? "Status \(status)")
            return
        }
    }

    func fetchPassword(warn: Bool = false) -> String? {
        let query: [String: Any] = [
            String(kSecClass): kSecClassGenericPassword,
            String(kSecAttrAccount): NSUserName(),
            String(kSecAttrService): Bundle.main.bundleIdentifier ?? "FUnlock",
            String(kSecReturnData): true as CFBoolean,
            String(kSecMatchLimit): kSecMatchLimitOne,
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            if warn { errorModal(t("password_not_set")) }
            return nil
        }
        guard status == errSecSuccess else {
            let info = SecCopyErrorMessageString(status, nil)
            errorModal(t("failed_retrieve_password"), info: info as String? ?? "Status \(status)")
            return nil
        }
        guard let data = item as? Data else {
            errorModal(t("failed_convert_password"))
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - 通知

    private func notifyUser(_ reason: String) {
        let content = UNMutableNotificationContent()
        content.title = "FUnlock"
        if reason == "lost" { content.subtitle = t("notification_lost_signal") }
        else if reason == "away" { content.subtitle = t("notification_device_away") }
        content.body = t("notification_locked")
        let req = UNNotificationRequest(identifier: "funlock-lock", content: content, trigger: nil)
        userNotificationId = req.identifier
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    // MARK: - 日志 / 脚本

    func logEvent(_ event: String) {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return }
        let logDir = dir.appendingPathComponent("FUnlock", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logFile = logDir.appendingPathComponent("events.log")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let rssiStr = rssi.map { String($0) } ?? "N/A"
        let line = "\(formatter.string(from: Date())) | \(event) | RSSI: \(rssiStr)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile.path) {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logFile)
            }
        }
    }

    func runScript(_ arg: String) {
        guard let directory = try? FileManager.default.url(for: .applicationScriptsDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return }
        let file = directory.appendingPathComponent("event")
        let process = Process()
        process.executableURL = file
        var args = [arg]
        if let r = rssi { args.append(String(r)) }
        if let uuid = fun.monitoredUUID, let device = fun.devices[uuid] {
            args.append(device.description)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        args.append(formatter.string(from: Date()))
        process.arguments = args
        try? process.run()
    }

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
            releaseWakeAssertion()
        }
        wakeTask?.cancel()
        unlockTask?.cancel()
        intrudeCheckTask?.cancel()
    }

    // MARK: - UI 辅助

    /// 同一小时内最多提示一次无障碍权限丢失
    private func showAXRevokedAlertIfNeeded() {
        let key = "lastAXRevokedAlert"
        let now = Date().timeIntervalSince1970
        if let last = prefs.object(forKey: key) as? Double, now - last < 3600 {
            Log.sm.debug("AX revoked alert throttled (last shown \(Int(now - last))s ago)")
            return
        }
        prefs.set(now, forKey: key)
        let alert = NSAlert()
        alert.messageText = t("ax_revoked_title")
        alert.informativeText = t("ax_revoked_info")
        alert.alertStyle = .warning
        alert.addButton(withTitle: t("open_settings"))
        alert.addButton(withTitle: t("ok"))
        alert.window.title = "FUnlock"
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func errorModal(_ msg: String, info: String? = nil) {
        let alert = NSAlert()
        alert.messageText = msg
        alert.informativeText = info ?? ""
        alert.window.title = "FUnlock"
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func askPassword() {
        let msg = NSAlert()
        msg.addButton(withTitle: t("ok"))
        msg.addButton(withTitle: t("cancel"))
        msg.messageText = t("enter_password")
        msg.informativeText = t("password_info")
        msg.window.title = "FUnlock"
        let txt = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 20))
        msg.accessoryView = txt
        txt.becomeFirstResponder()
        NSApp.activate(ignoringOtherApps: true)
        let response = msg.runModal()
        if response == .alertFirstButtonReturn {
            storePassword(txt.stringValue)
        }
    }

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
                showAbnormalUnlockAlert()
                lastAbnormalAlertTime = now
            }
        }
    }

    /// 成功解锁后清除失败记录
    private func recordUnlockSuccess() {
        unlockAttemptTimestamps.removeAll()
    }

    /// 异常解锁频率告警
    @MainActor
    private func showAbnormalUnlockAlert() {
        Log.sm.debug("abnormal unlock alert: \(self.unlockAttemptTimestamps.count) attempts in \(Int(self.detectionWindow))s")
        let alert = NSAlert()
        alert.messageText = t("abnormal_unlock_title")
        alert.informativeText = t("abnormal_unlock_info")
        alert.alertStyle = .critical
        alert.addButton(withTitle: t("ok"))
        alert.window.title = "FUnlock"
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// 连续多次解锁尝试未收到 onUnlock，提示用户密码可能已更改
    private func showPasswordMismatchAlert() {
        Log.sm.debug("showing password mismatch alert after \(self.maxUnlockAttempts) attempts")
        let alert = NSAlert()
        alert.messageText = t("password_mismatch_title")
        alert.informativeText = t("password_mismatch_info")
        alert.alertStyle = .warning
        alert.addButton(withTitle: t("re_enter_password"))
        alert.addButton(withTitle: t("cancel"))
        alert.window.title = "FUnlock"
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            askPassword()
        }
    }

    // MARK: - 密码变更检测

    /// 系统密码变更通知回调：清除旧密码并提醒用户重新输入
    func handlePasswordChanged() {
        guard fetchPassword() != nil else { return }  // 没存密码，无需处理
        Log.sm.debug("system password changed, clearing stored password")
        // 清除 Keychain 中的旧密码
        let query: [String: Any] = [
            String(kSecClass): kSecClassGenericPassword,
            String(kSecAttrAccount): NSUserName(),
            String(kSecAttrService): Bundle.main.bundleIdentifier ?? "FUnlock",
        ]
        SecItemDelete(query as CFDictionary)

        let alert = NSAlert()
        alert.messageText = t("password_changed_title")
        alert.informativeText = t("password_changed_info")
        alert.alertStyle = .warning
        alert.addButton(withTitle: t("re_enter_password"))
        alert.addButton(withTitle: t("later"))
        alert.window.title = "FUnlock"
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            askPassword()
        }
    }

    // MARK: - 便利属性

    var isDeviceConnected: Bool { connected }

    func updateConnected(_ newValue: Bool) {
        connected = newValue
    }
}
