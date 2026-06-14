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

// MARK: - BluetoothManager

@MainActor
final class BluetoothManager: ObservableObject {

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

    let ble: BLE
    private let prefs = UserDefaults.standard
    private var wakeTask: Task<Void, Never>?
    private var unlockTask: Task<Void, Never>?
    private var intrudeCheckTask: Task<Void, Never>?
    private var userNotificationId = ""
    private var cancellables = Set<AnyCancellable>()

    // MARK: Init

    init(ble: BLE) {
        self.ble = ble
        self.lockRSSI = ble.lockRSSI
        self.unlockRSSI = ble.unlockRSSI
    }

    // MARK: - 阈值同步

    func setLockRSSI(_ value: Int) {
        lockRSSI = value
        ble.lockRSSI = value
        UserDefaults.standard.set(value, forKey: "lockRSSI")
        thresholdVersion += 1
    }

    func setUnlockRSSI(_ value: Int) {
        unlockRSSI = value
        ble.unlockRSSI = value
        UserDefaults.standard.set(value, forKey: "unlockRSSI")
        thresholdVersion += 1
    }

    // MARK: - 扫描控制

    func startScanning() {
        ble.startScanning()
    }

    func stopScanning() {
        ble.stopScanning()
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
        state.unlockedAt = Date()
        state.intent = .autoLock

        // 2 秒后检查是否为入侵（非 BLE 自动解锁）
        intrudeCheckTask?.cancel()
        intrudeCheckTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            if Date().timeIntervalSince1970 >= state.unlockedAt.timeIntervalSince1970 + 10 {
                if ble.unlockRSSI != ble.UNLOCK_DISABLED {
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

    // MARK: - BLE 设备事件

    func onDeviceApproached() {
        guard prefs.bool(forKey: "enabled") else { return }
        guard ble.unlockRSSI != ble.UNLOCK_DISABLED else { return }

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
        guard ble.lockRSSI != ble.LOCK_DISABLED else { return }

        let lockReason: ScreenState.LockReason = (reason == "lost") ? .lost : .away
        state.screen = .locked(reason: lockReason)
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
        ble.startMonitor(uuid: device.uuid)
        ble.addMonitoredDevice(uuid: device.uuid)
        monitoredDeviceName = device.description
        prefs.set(device.uuid.uuidString, forKey: "device")
        prefs.set(device.description, forKey: "deviceName")
    }

    func unbindDevice() {
        ble.monitoredUUID = nil
        ble.monitoredUUIDs.removeAll()
        ble.devicePresence.removeAll()
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
        guard state.canAutoUnlock else { return }
        guard ble.presence else { return }
        guard ble.unlockRSSI != ble.UNLOCK_DISABLED else { return }

        // 屏保中先按 Esc
        if state.screen == .screensaver {
            let src = CGEventSource(stateID: .hidSystemState)
            CGEvent(keyboardEventSource: src, virtualKey: 0x35, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 0x35, keyDown: false)?.post(tap: .cghidEventTap)
        }

        guard !prefs.bool(forKey: "wakeWithoutUnlocking") else { return }

        // 取消之前的解锁任务
        unlockTask?.cancel()

        unlockTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            guard !Task.isCancelled else { return }
            guard isScreenLocked() else { return }
            guard Date().timeIntervalSince1970 - state.unlockedAt.timeIntervalSince1970 > 3 else {
                print("[SM] recently unlocked by user, abort auto-unlock")
                return
            }
            guard let password = fetchPassword(warn: true) else { return }

            print("[SM] entering password")
            self.state.unlockedAt = Date()
            fakeKeyStrokes(password)
            playNowPlaying()
            runScript("unlocked")
            logEvent("unlocked")
        }
    }

    // MARK: - 显示器唤醒重试 (async/await 替代 Timer)

    private func startWakeRetry() {
        state.wake = .pending
        state.screen = .locked(reason: .away) // 唤醒后仍为锁定

        wakeTask?.cancel()
        wakeTask = Task {
            for attempt in 0..<10 {
                guard !Task.isCancelled else { return }
                if attempt > 0 {
                    print("[SM] retrying wake #\(attempt)")
                }
                wakeDisplay()
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s
                if state.wake == .succeeded {
                    return
                }
            }
            print("[SM] wake failed after 10 retries")
            state.wake = .failed
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
            if SACLockScreenImmediate() != 0 { print("[SM] failed to lock screen") }
            if prefs.bool(forKey: "sleepDisplay") {
                sleepDisplay()
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
            pressEvent?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: false)?.post(tap: .cghidEventTap)
        }
        CGEvent(keyboardEventSource: src, virtualKey: 52, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: 52, keyDown: false)?.post(tap: .cghidEventTap)
    }

    // MARK: - Keychain

    func storePassword(_ password: String) {
        let pw = password.data(using: .utf8)!
        let query: [String: Any] = [
            String(kSecClass): kSecClassGenericPassword,
            String(kSecAttrAccount): NSUserName(),
            String(kSecAttrService): Bundle.main.bundleIdentifier ?? "BLEUnlock",
            String(kSecAttrLabel): "BLEUnlock",
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
            String(kSecAttrService): Bundle.main.bundleIdentifier ?? "BLEUnlock",
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
        content.title = "BLEUnlock"
        if reason == "lost" { content.subtitle = t("notification_lost_signal") }
        else if reason == "away" { content.subtitle = t("notification_device_away") }
        content.body = t("notification_locked")
        let req = UNNotificationRequest(identifier: "bleunlock-lock", content: content, trigger: nil)
        userNotificationId = req.identifier
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    // MARK: - 日志 / 脚本

    func logEvent(_ event: String) {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return }
        let logDir = dir.appendingPathComponent("BLEUnlock", isDirectory: true)
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
        if let uuid = ble.monitoredUUID, let device = ble.devices[uuid] {
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
        BLEUnlock.checkUpdate()
    }

    // MARK: - UI 辅助

    func errorModal(_ msg: String, info: String? = nil) {
        let alert = NSAlert()
        alert.messageText = msg
        alert.informativeText = info ?? ""
        alert.window.title = "BLEUnlock"
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func askPassword() {
        let msg = NSAlert()
        msg.addButton(withTitle: t("ok"))
        msg.addButton(withTitle: t("cancel"))
        msg.messageText = t("enter_password")
        msg.informativeText = t("password_info")
        msg.window.title = "BLEUnlock"
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
