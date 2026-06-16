// BluetoothManager.swift
// 核心状态机：收编所有锁屏/解锁决策逻辑
// 使用 Combine 暴露状态，async/await 替代 Timer

import Foundation
import Combine
import UserNotifications
import Cocoa
import Quartz

// MARK: - 状态枚举

enum ScreenState: Equatable {
    case unlocked
    case locked(reason: LockReason)
    case screensaver
    case displaySleeping

    enum LockReason: Equatable {
        case away, lost, manual, timeout
    }
}

enum SystemPowerState: Equatable {
    case awake, sleeping
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
    private let prefs = UserDefaults.standard
    private var wakeTask: Task<Void, Never>?
    private var unlockTask: Task<Void, Never>?
    private var intrudeCheckTask: Task<Void, Never>?
    private var userNotificationId = ""
    private var cancellables = Set<AnyCancellable>()

    // MARK: Init

    init(fun: FUn) {
        self.fun = fun
        self.lockRSSI = fun.lockRSSI
        self.unlockRSSI = fun.unlockRSSI
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
        print("[SM] displaySleep")
        state.screen = .displaySleeping
    }

    func onDisplayWake() {
        print("[SM] displayWake")
        state.wake = .succeeded
        wakeTask?.cancel()
        wakeTask = nil
        if state.screen == .displaySleeping {
            state.screen = .locked(reason: .away)
        }
        attemptAutoUnlock()
    }

    func onSystemSleep() {
        print("[SM] systemSleep")
        state.system = .sleeping
        NSApp.setActivationPolicy(.regular)
    }

    func onSystemWake() {
        print("[SM] systemWake")
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
        print("[SM] userUnlocked")
        state.screen = .unlocked
        state.unlockedAt = Date()
        state.intent = .autoLock

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
        print("[SM] screensaverStart")
        state.screen = .screensaver
    }

    func onScreensaverStop() {
        print("[SM] screensaverStop")
        if state.screen == .screensaver {
            state.screen = .locked(reason: .manual)
        }
    }

    /// 系统原生锁屏通知（Apple 菜单 → Lock Screen，或快捷键）
    /// 无条件进入 manualLock 状态，防止设备走远再靠近时自动解锁
    func onSystemScreenLocked() {
        print("[SM] systemScreenLocked")
        state.intent = .manualLock(deadline: Date().addingTimeInterval(60))
        state.screen = .locked(reason: .manual)
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

        // 显示器休眠中 → 唤醒
        if state.screen == .displaySleeping && state.system == .awake
            && prefs.bool(forKey: "wakeOnProximity") {
            startWakeRetry()
        }

        attemptAutoUnlock()
    }

    func onDeviceLeft(reason: String) {
        guard prefs.bool(forKey: "enabled") else { return }
        guard state.screen == .unlocked else { return }
        guard fun.lockRSSI != fun.LOCK_DISABLED else { return }

        state.screen = .displaySleeping  // 标记为显示器休眠（与原始逻辑一致）
        pauseNowPlaying()
        lockOrSaveScreen()
        notifyUser(reason)
        runScript(reason)
        logEvent("locked: \(reason)")
    }

    func onRSSIUpdated(rssi: Int?, active: Bool) {
        self.rssi = rssi
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
        fun.addMonitoredDevice(uuid: device.uuid)
        monitoredDeviceName = device.description
        prefs.set(device.uuid.uuidString, forKey: "device")
        prefs.set(device.description, forKey: "deviceName")
    }

    func unbindDevice() {
        fun.monitoredUUID = nil
        fun.monitoredUUIDs.removeAll()
        fun.devicePresence.removeAll()
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

    private func unlockLog(_ msg: String) {
        let line = "\(Date()): [unlock] \(msg)\n"
        if let d = line.data(using: .utf8) {
            if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/funlock_unlock.log")) {
                h.seekToEndOfFile(); h.write(d); h.closeFile()
            } else {
                try? d.write(to: URL(fileURLWithPath: "/tmp/funlock_unlock.log"))
            }
        }
    }

    private func attemptAutoUnlock() {
        let screenLocked = isScreenLocked()
        let axGranted = AXIsProcessTrusted()
        let log = "\(Date()): attemptAutoUnlock presence=\(fun.presence) screen=\(state.screen) wakeWO=\(prefs.bool(forKey: "wakeWithoutUnlocking")) locked=\(screenLocked) ax=\(axGranted)\n"
        if let d = log.data(using: .utf8) { try? d.write(to: URL(fileURLWithPath: "/tmp/funlock_unlock.log")) }
        guard fun.presence else { unlockLog("SKIP: no presence"); return }
        guard fun.unlockRSSI != fun.UNLOCK_DISABLED else { unlockLog("SKIP: unlock disabled"); return }
        if !axGranted { unlockLog("WARN: ax=false, trying anyway") }

        // 显示器休眠中 → 先唤醒
        if state.screen == .displaySleeping && state.system == .awake
            && prefs.bool(forKey: "wakeOnProximity") {
            unlockLog("starting wakeRetry (display sleeping)")
            startWakeRetry()
            return
        }

        guard !prefs.bool(forKey: "wakeWithoutUnlocking") else { unlockLog("SKIP: wakeWithoutUnlocking"); return }
        guard state.screen != .displaySleeping else { unlockLog("SKIP: still displaySleeping"); return }

        unlockTask?.cancel()
        unlockTask = Task {
            unlockLog("Task started, sleeping 0.5s")
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            guard !Task.isCancelled else { unlockLog("Task cancelled after sleep"); return }
            let locked = isScreenLocked()
            unlockLog("screen locked check: \(locked)")
            guard locked else { unlockLog("SKIP: screen not locked"); return }
            let sinceUnlock = Date().timeIntervalSince1970 - state.unlockedAt.timeIntervalSince1970
            guard sinceUnlock > 3 else {
                unlockLog("SKIP: recently unlocked (\(String(format:"%.1f", sinceUnlock))s ago)")
                return
            }
            guard let password = fetchPassword(warn: true) else { unlockLog("SKIP: no password"); return }

            unlockLog("typing password (\(password.count) chars)")
            self.state.unlockedAt = Date()
            fakeKeyStrokes(password)
            unlockLog("fakeKeyStrokes done")
            playNowPlaying()
            runScript("unlocked")
            logEvent("unlocked")
            unlockLog("unlock complete")
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
                wakeDisplay()
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s
                // wakeDisplay() 不一定触发 screensDidWakeNotification，
                // 直接检测屏幕是否已解锁
                if state.wake == .succeeded || !isScreenLocked() {
                    state.wake = .succeeded
                    DispatchQueue.main.async { [weak self] in
                        self?.attemptAutoUnlock()
                    }
                    return
                }
            }
            print("[SM] wake failed after 10 retries")
            state.wake = .failed
            // wake 完成后尝试解锁（原始逻辑：onDisplayWake 会调 tryUnlockScreen）
            DispatchQueue.main.async { [weak self] in
                self?.attemptAutoUnlock()
            }
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
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.screensaver.ScreenSaverEngine") {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                NSWorkspace.shared.openApplication(at: url, configuration: config)
            }
        } else {
            DispatchQueue.main.async {
                // 必须真正锁屏，让 isScreenLocked() 返回 true
                _ = SACLockScreenImmediate()
            }
        }
    }

    private func isScreenLocked() -> Bool {
        if let dict = CGSessionCopyCurrentDictionary() as? [String: Any] {
            return dict["CGSSessionScreenIsLocked"] as? Int == 1
        }
        return false
    }

    // MARK: - 键盘模拟

    private func fakeKeyStrokes(_ string: String) {
        // 直接尝试 CGEvent（不依赖 AXIsProcessTrusted，它对 agent 应用不可靠）
        fakeKeyStrokesCGEvent(string)
    }

    private func fakeKeyStrokesCGEvent(_ string: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        let PER = 20
        let uniCharCount = string.utf16.count
        var strIndex = string.utf16.startIndex
        for offset in stride(from: 0, to: uniCharCount, by: PER) {
            let pressEvent = CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: true)
            let len = offset + PER < uniCharCount ? PER : uniCharCount - offset
            let buffer = UnsafeMutablePointer<UniChar>.allocate(capacity: len)
            defer { buffer.deallocate() }
            for i in 0..<len {
                buffer[i] = string.utf16[strIndex]
                strIndex = string.utf16.index(after: strIndex)
            }
            pressEvent?.keyboardSetUnicodeString(stringLength: len, unicodeString: buffer)
            pressEvent?.post(tap: .cgSessionEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: false)?.post(tap: .cgSessionEventTap)
        }
        // Return key (36 = main Return, not numpad Enter 52)
        CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: true)?.post(tap: .cgSessionEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: false)?.post(tap: .cgSessionEventTap)
    }

    private func fakeKeyStrokesAppleScript(_ string: String) {
        // 通过 System Events 发送键盘事件（某些 macOS 版本不需要 Accessibility）
        let escaped = string.replacingOccurrences(of: "\\", with: "\\\\")
                          .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "System Events"
            keystroke "\(escaped)"
            delay 0.1
            key code 36
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error = error {
                print("[SM] AppleScript keystroke failed: \(error)")
            }
        }
    }

    // MARK: - Keychain

    func storePassword(_ password: String) {
        let pw = password.data(using: .utf8)!
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
            String(kSecReturnData): kCFBooleanTrue!,
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
        return String(data: data, encoding: .utf8)!
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
        // 由 checkUpdate.swift 的全局函数处理
        FUnlock.checkUpdate()
    }

    // MARK: - 清理（退出时调用，防止 RunLoop Timer 崩溃）

    func cleanup() {
        fun.proximityTimer?.invalidate()
        fun.proximityTimer = nil
        fun.signalTimer?.invalidate()
        fun.signalTimer = nil
        fun.activeModeTimer?.invalidate()
        fun.activeModeTimer = nil
        fun.connectionTimer?.invalidate()
        fun.connectionTimer = nil
        wakeTask?.cancel()
        unlockTask?.cancel()
        intrudeCheckTask?.cancel()
    }

    // MARK: - UI 辅助

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

    // MARK: - 便利属性

    var isDeviceConnected: Bool { connected }

    func updateConnected(_ newValue: Bool) {
        connected = newValue
    }
}
