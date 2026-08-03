import Foundation
import Cocoa
import UserNotifications
import IOKit

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

/// Encapsulates all OS-level side effects: screen control, keyboard injection, media, notifications
final class SystemInteractionService {
    static let shared = SystemInteractionService()
    private init() {}

    // MARK: - Screen State Detection

    /// Check if screen is locked (CGSession + screensaver + state fallback)
    func isScreenLocked(screenState: ScreenState?) -> Bool {
        if let dict = CGSessionCopyCurrentDictionary() as? [String: Any] {
            if dict["CGSSessionScreenIsLocked"] as? Int == 1 { return true }
        }
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.ScreenSaver.Engine").count > 0 {
            return true
        }
        if let screen = screenState { return screen != .unlocked }
        return false
    }

    /// Double safety check: screen locked + frontmost app is loginwindow
    func isSecureToInject(screenState: ScreenState?) -> Bool {
        let locked = isScreenLocked(screenState: screenState)
        guard locked else {
            _log(component: "SystemInteraction", "isSecureToInject: NOT locked")
            return false
        }
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           frontApp.bundleIdentifier != "com.apple.loginwindow" {
            _log(component: "SystemInteraction", "isSecureToInject: ABORT frontmost=\(frontApp.bundleIdentifier ?? "nil")")
            Log.sm.debug("ABORT: frontmost=\(frontApp.bundleIdentifier ?? "nil"), not loginwindow")
            return false
        }
        _log(component: "SystemInteraction", "isSecureToInject: OK")
        return true
    }

    // MARK: - Screen Control

    /// Check if the display is powered on via IOKit IODisplayWrangler
    func isDisplayPoweredOn() -> Bool {
        let reg = IORegistryEntryFromPath(kIOMainPortDefault,
                                          "IOService:/IOResources/IODisplayWrangler")
        guard reg != 0 else {
            _log(component: "SystemInteraction", "isDisplayPoweredOn: failed to get IODisplayWrangler")
            return true  // 无法查询时默认通电，避免误唤醒
        }
        defer { IOObjectRelease(reg) }

        if let prop = IORegistryEntryCreateCFProperty(reg, "IOEnginePower" as CFString, kCFAllocatorDefault, 0) {
            let powerState = prop.takeRetainedValue() as! CFNumber
            var value: UInt32 = 0
            CFNumberGetValue(powerState, .sInt32Type, &value)
            _log(component: "SystemInteraction", "isDisplayPoweredOn: IOEnginePower=\(value)")
            return value != 0
        }
        _log(component: "SystemInteraction", "isDisplayPoweredOn: IOEnginePower not found")
        return true  // 属性不存在时默认通电
    }

    /// Wake the display before password injection
    func wakeDisplay() {
        _log(component: "SystemInteraction", "wakeDisplay: waking display")
        Log.sm.debug("PASSWORD: waking display before injection")
        funlock_wakeDisplay()
        Thread.sleep(forTimeInterval: 0.3)
    }

    // MARK: - Screen Control (Lock)

    /// Lock screen or start screensaver based on user preference
    func lockOrSaveScreen(useScreensaver: Bool, sleepDisplayAfter: Bool) {
        if useScreensaver {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ScreenSaver.Engine") {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                NSWorkspace.shared.openApplication(at: url, configuration: config)
            }
        } else {
            _ = SACLockScreenImmediate()
        }
        if sleepDisplayAfter {
            funlock_sleepDisplay()
        }
    }

    // MARK: - Keyboard Injection

    /// Inject password keystrokes via CGEvent. Returns true if at least one event posted.
    /// isSecureCheck is called before each batch to verify screen is still locked.
    /// 采用三级降级策略：cgSessionEventTap -> cghidEventTap -> AppleScript
    func fakeKeyStrokes(_ string: String, isSecureCheck: () -> Bool) -> Bool {
        _log(component: "SystemInteraction", "fakeKeyStrokes() START - \(string.count) chars")
        Log.sm.debug("PASSWORD: attempting keystroke injection for \(string.count) chars")

        // 检查屏幕是否可见，如果不可见则唤醒
        if !isDisplayPoweredOn() {
            _log(component: "SystemInteraction", "fakeKeyStrokes: display off, waking")
            Log.sm.debug("PASSWORD: display off, waking screen")
            wakeDisplay()
        }

        // 尝试第1级：cgSessionEventTap + virtualKey 0
        _log(component: "SystemInteraction", "Level 1: cgSessionEventTap + vk0")
        Log.sm.debug("PASSWORD: trying Level 1 - cgSessionEventTap + virtualKey 0")
        if injectWithCGEvent(string, tap: .cgSessionEventTap, virtualKey: 0, isSecureCheck: isSecureCheck) {
            _log(component: "SystemInteraction", "Level 1: SUCCESS")
            Log.sm.debug("PASSWORD: Level 1 injection succeeded")
            return true
        }
        _log(component: "SystemInteraction", "Level 1: FAILED, trying Level 2")
        Log.sm.debug("PASSWORD: Level 1 failed, trying Level 2")

        // 尝试第2级：cghidEventTap + virtualKey 0
        _log(component: "SystemInteraction", "Level 2: cghidEventTap + vk0")
        Log.sm.debug("PASSWORD: trying Level 2 - cghidEventTap + virtualKey 0")
        if injectWithCGEvent(string, tap: .cghidEventTap, virtualKey: 0, isSecureCheck: isSecureCheck) {
            _log(component: "SystemInteraction", "Level 2: SUCCESS")
            Log.sm.debug("PASSWORD: Level 2 injection succeeded")
            return true
        }
        _log(component: "SystemInteraction", "Level 2: FAILED, trying Level 3")
        Log.sm.debug("PASSWORD: Level 2 failed, trying Level 3")

        // 尝试第3级：AppleScript System Events（仅限 ASCII 密码）
        guard string.canBeConverted(to: .ascii) else {
            _log(component: "SystemInteraction", "Level 3: SKIPPED - non-ASCII password")
            Log.sm.debug("PASSWORD: Level 3 skipped - password contains non-ASCII characters")
            return false
        }
        _log(component: "SystemInteraction", "Level 3: AppleScript System Events")
        Log.sm.debug("PASSWORD: trying Level 3 - AppleScript System Events")
        let result = injectWithAppleScript(string, isSecureCheck: isSecureCheck)
        if result {
            _log(component: "SystemInteraction", "Level 3: SUCCESS")
            Log.sm.debug("PASSWORD: Level 3 injection succeeded")
        } else {
            _log(component: "SystemInteraction", "Level 3: FAILED - all levels exhausted")
            Log.sm.debug("PASSWORD: Level 3 failed - all levels exhausted")
        }
        _log(component: "SystemInteraction", "fakeKeyStrokes() END - result=\(result)")
        return result
    }

    /// Inject password using CGEvent with specified tap type and virtual key.
    /// Returns true if at least one event posted.
    private func injectWithCGEvent(_ string: String, tap: CGEventTapLocation, virtualKey: CGKeyCode, isSecureCheck: () -> Bool) -> Bool {
        let src = CGEventSource(stateID: .hidSystemState)
        var anyEventPosted = false
        let uniCharCount = string.utf16.count
        var strIndex = string.utf16.startIndex

        for offset in stride(from: 0, to: uniCharCount, by: 20) {
            guard isSecureCheck() else {
                Log.sm.debug("PASSWORD: ABORT - screen no longer secure during keystroke injection")
                return anyEventPosted
            }
            let pressEvent = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: true)
            let len = offset + 20 < uniCharCount ? 20 : uniCharCount - offset
            let buffer = UnsafeMutablePointer<UniChar>.allocate(capacity: len)
            defer { buffer.deallocate() }
            for i in 0..<len {
                buffer[i] = string.utf16[strIndex]
                strIndex = string.utf16.index(after: strIndex)
            }
            pressEvent?.keyboardSetUnicodeString(stringLength: len, unicodeString: buffer)
            pressEvent?.post(tap: tap)
            CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: false)?.post(tap: tap)
            if pressEvent != nil { anyEventPosted = true }
        }

        guard isSecureCheck() else {
            Log.sm.debug("PASSWORD: ABORT - screen no longer secure before Return key")
            return anyEventPosted
        }
        let returnDown = CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: true)
        let returnUp = CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: false)
        returnDown?.post(tap: tap)
        returnUp?.post(tap: tap)
        if returnDown != nil { anyEventPosted = true }
        return anyEventPosted
    }

    /// Inject password using AppleScript System Events (only for ASCII passwords).
    /// Returns true if injection was initiated successfully.
    /// 执行前与结束后均调用 isSecureCheck 确认屏幕仍处于锁定状态（防密码泄露给非锁定会话）
    private func injectWithAppleScript(_ string: String, isSecureCheck: () -> Bool) -> Bool {
        guard string.canBeConverted(to: .ascii) else {
            Log.sm.debug("PASSWORD: AppleScript rejected - non-ASCII characters")
            return false
        }

        // osascript 执行前再次确认屏幕仍锁定，防止密码泄露给非锁定会话
        guard isSecureCheck() else {
            _log(component: "SystemInteraction", "Level 3: ABORT - screen no longer secure before AppleScript")
            Log.sm.debug("PASSWORD: ABORT - screen no longer secure before AppleScript injection")
            return false
        }

        // Escape special characters for AppleScript string
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "'", with: "\\'")

        let script = """
        tell application "System Events"
            keystroke "\(escaped)"
            delay 0.05
            keystroke return
        end tell
        """

        Log.sm.debug("PASSWORD: executing AppleScript keystroke injection")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]

        do {
            try task.run()
            task.waitUntilExit()
            let status = task.terminationStatus
            // osascript 为同步 waitUntilExit，此处检查只能用于结果判定：
            // 若屏幕已解锁，密码可能已被输入到非锁定会话，调用方不得视为成功
            if !isSecureCheck() {
                _log(component: "SystemInteraction", "Level 3: screen no longer locked after AppleScript - result unreliable, treated as failure")
                Log.sm.debug("PASSWORD: screen no longer locked after AppleScript, treating as failure")
                return false
            }
            if status == 0 {
                Log.sm.debug("PASSWORD: AppleScript injection completed successfully")
                return true
            } else {
                Log.sm.debug("PASSWORD: AppleScript failed with status \(status)")
                return false
            }
        } catch {
            Log.sm.debug("PASSWORD: AppleScript error - \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Injection Prelude

    /// Send a single Shift key press-release via CGEvent.
    /// Used as a prelude before password injection to activate the login window text field.
    /// isSecureCheck is called before each event batch to verify screen is still locked.
    public func sendShiftKey(isSecureCheck: @escaping () -> Bool) -> Bool {
        _log(component: "SystemInteraction", "sendShiftKey() START")
        Log.sm.debug("PASSWORD: sending Shift key prelude")

        let src = CGEventSource(stateID: .hidSystemState)

        for tap in [CGEventTapLocation.cgSessionEventTap, CGEventTapLocation.cghidEventTap] {
            guard isSecureCheck() else {
                _log(component: "SystemInteraction", "sendShiftKey: ABORT - screen not secure")
                return false
            }
            let shiftDown = CGEvent(keyboardEventSource: src, virtualKey: 56, keyDown: true)
            let shiftUp = CGEvent(keyboardEventSource: src, virtualKey: 56, keyDown: false)
            shiftDown?.post(tap: tap)
            shiftUp?.post(tap: tap)
            if shiftDown != nil {
                _log(component: "SystemInteraction", "sendShiftKey: SUCCESS via tap=\(tap == .cgSessionEventTap ? "cgSession" : "cghid")")
                Log.sm.debug("PASSWORD: Shift key sent successfully")
                return true
            }
        }

        _log(component: "SystemInteraction", "sendShiftKey: FAILED - all taps exhausted")
        Log.sm.debug("PASSWORD: Shift key send failed")
        return false
    }

    /// Send a Shift key prelude, wait 300ms, then inject password.
    /// The Shift key activates the login window text field before password injection.
    /// Returns true if at least one password event was posted.
    public func injectPasswordWithPrelude(_ string: String, isSecureCheck: @escaping () -> Bool) -> Bool {
        _log(component: "SystemInteraction", "injectPasswordWithPrelude() START - \(string.count) chars")
        Log.sm.debug("PASSWORD: injection with prelude - Shift + 300ms delay")

        let shiftSent = sendShiftKey(isSecureCheck: isSecureCheck)
        if shiftSent {
            _log(component: "SystemInteraction", "injectPasswordWithPrelude: Shift sent, waiting 300ms")
            Log.sm.debug("PASSWORD: Shift prelude sent, waiting 300ms before password")
            Thread.sleep(forTimeInterval: 0.3)
        } else {
            _log(component: "SystemInteraction", "injectPasswordWithPrelude: Shift failed, proceeding without delay")
            Log.sm.debug("PASSWORD: Shift prelude failed, proceeding without delay")
        }

        _log(component: "SystemInteraction", "injectPasswordWithPrelude: injecting password")
        let result = fakeKeyStrokes(string, isSecureCheck: isSecureCheck)
        _log(component: "SystemInteraction", "injectPasswordWithPrelude() END - result=\(result)")
        return result
    }

    // MARK: - Media Control

    /// Pause Now Playing if preference enabled. Returns whether it was playing.
    func checkAndPauseMedia(enabled: Bool, callback: @escaping (Bool) -> Void) {
        guard enabled else { callback(false); return }
        MRMediaRemoteGetNowPlayingApplicationIsPlaying(DispatchQueue.main) { playing in
            if playing {
                MRMediaRemoteSendCommand(MRCommandPause, nil)
            }
            callback(playing)
        }
    }

    /// Resume Now Playing if it was playing before
    func resumeMediaIfNeeded(wasPlaying: Bool, enabled: Bool) {
        guard enabled && wasPlaying else { return }
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            MRMediaRemoteSendCommand(MRCommandPlay, nil)
        }
    }

    // MARK: - Notifications

    private var deliveredNotificationId = ""

    func notifyLock(reason: String) {
        let content = UNMutableNotificationContent()
        content.title = "FUnlock"
        if reason == "lost" { content.subtitle = t("notification_lost_signal") }
        else if reason == "away" { content.subtitle = t("notification_device_away") }
        content.body = t("notification_locked")
        let req = UNNotificationRequest(identifier: "funlock-lock", content: content, trigger: nil)
        deliveredNotificationId = req.identifier
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    func clearLockNotification() {
        if !deliveredNotificationId.isEmpty {
            UNUserNotificationCenter.current()
                .removeDeliveredNotifications(withIdentifiers: [deliveredNotificationId])
            deliveredNotificationId = ""
        }
    }

    // MARK: - 双保险验证

    /// 解锁通知结果
    struct UnlockNotification {
        let unlock: Bool
    }

    /// 等待系统解锁（快速路径）
    /// 监听 NSWorkspace.didWakeNotification（系统唤醒信号）+ 轮询 CGSession
    /// 系统唤醒时立即开始高频轮询，比纯 CGSession 轮询更快响应
    func waitForUnlockNotification(timeout: TimeInterval = 1.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        // 唤醒信号：收到后立即开始高频轮询（比固定间隔更快）
        let wakeSignal = NSLock()
        var wakeDetected = false

        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            wakeSignal.lock()
            wakeDetected = true
            wakeSignal.unlock()
        }

        defer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }

        while Date() < deadline {
            // 检查 CGSession
            if let dict = CGSessionCopyCurrentDictionary() as? [String: Any] {
                if dict["CGSSessionScreenIsLocked"] as? Int == 0 {
                    _log(component: "SystemInteraction", "waitForUnlockNotification: unlocked via CGSession")
                    return true
                }
            } else {
                // CGSession 为 nil 表示无会话信息，不视为解锁，继续轮询
                _log(component: "SystemInteraction", "waitForUnlockNotification: CGSession nil → 继续轮询")
            }
            // 唤醒信号检测到后用更短间隔轮询（50ms），否则200ms
            wakeSignal.lock()
            let detected = wakeDetected
            wakeSignal.unlock()
            let interval: UInt64 = detected ? 50_000_000 : 200_000_000
            try? await Task.sleep(nanoseconds: interval)
        }
        _log(component: "SystemInteraction", "waitForUnlockNotification: timeout (\(timeout)s)")
        return false
    }

    /// 通过 CGSession 轮询检测屏幕是否解锁（兜底路径，最多2秒）
    /// 每100ms 检查一次 CGSessionCopyCurrentDictionary，超时返回 false
    func checkScreenUnlocked(timeout: TimeInterval = 2.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let dict = CGSessionCopyCurrentDictionary() as? [String: Any] {
                if dict["CGSSessionScreenIsLocked"] as? Int == 0 {
                    _log(component: "SystemInteraction", "checkScreenUnlocked: screen unlocked via CGSession")
                    return true
                }
            } else {
                // CGSession 为 nil 表示无会话信息，不视为解锁，继续轮询
                _log(component: "SystemInteraction", "checkScreenUnlocked: CGSession nil → 继续轮询")
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        _log(component: "SystemInteraction", "checkScreenUnlocked: timeout (\(timeout)s)")
        return false
    }

    /// 双保险验证：通知 + CGSession 竞速，withTaskGroup 实现
    /// 任一路径先返回 true 即为解锁成功；全部超时返回 .timeout
    @MainActor
    func verifyUnlock(
        timeout: TimeInterval = 2.0,
        notificationTimeout: TimeInterval = 1.0
    ) async -> UnlockNotification {
        let result = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            // 路径1：系统解锁通知（快速，约100ms）
            group.addTask { [self] in
                await self.waitForUnlockNotification(timeout: notificationTimeout)
            }
            // 路径2：CGSession 轮询（兜底，最多2秒）
            group.addTask { [self] in
                await self.checkScreenUnlocked(timeout: timeout)
            }

            // 超时兜底：整体 deadline
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }

            // 任一路径返回 true 立即获胜
            for await success in group {
                if success {
                    group.cancelAll()
                    return true
                }
            }
            return false
        }
        return UnlockNotification(unlock: result)
    }

    /// 双保险验证（可测试版本）：接受注入的通知监听和屏幕检查闭包
    /// 用于单元测试时替换系统 API 调用
    @MainActor
    static func verifyUnlock(
        timeout: TimeInterval = 2.0,
        notificationTimeout: TimeInterval = 1.0,
        waitForNotification: @escaping (TimeInterval) async -> Bool,
        checkUnlocked: @escaping (TimeInterval) async -> Bool
    ) async -> UnlockNotification {
        let result = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            group.addTask {
                await waitForNotification(notificationTimeout)
            }
            group.addTask {
                await checkUnlocked(timeout)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            for await success in group {
                if success {
                    group.cancelAll()
                    return true
                }
            }
            return false
        }
        return UnlockNotification(unlock: result)
    }

    // MARK: - Alert Dialogs

    /// Show AX permission revoked alert (throttled to once per hour)
    func showAXRevokedAlertIfNeeded(lastAlertTime: inout Date) {
        let now = Date().timeIntervalSince1970
        if now - lastAlertTime.timeIntervalSince1970 < 3600 {
            return
        }
        lastAlertTime = Date()
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
            openAccessibilitySettings()
        }
    }

    /// 打开系统「辅助功能」权限设置页
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func showPasswordMismatchAlert() {
        let alert = NSAlert()
        alert.messageText = t("password_mismatch_title")
        alert.informativeText = t("password_mismatch_info")
        alert.alertStyle = .warning
        alert.addButton(withTitle: t("re_enter_password"))
        alert.addButton(withTitle: t("cancel"))
        alert.window.title = "FUnlock"
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            SecurityService.shared.askPassword()
        }
    }

    func showAbnormalUnlockAlert(count: Int, window: Int) {
        Log.sm.debug("abnormal unlock alert: \(count) attempts in \(window)s")
        let alert = NSAlert()
        alert.messageText = t("abnormal_unlock_title")
        alert.informativeText = t("abnormal_unlock_info")
        alert.alertStyle = .critical
        alert.addButton(withTitle: t("ok"))
        alert.window.title = "FUnlock"
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
