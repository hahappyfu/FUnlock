import Foundation
import Cocoa
import UserNotifications

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
            FUnlock.sleepDisplay()
        }
    }

    // MARK: - Keyboard Injection

    /// Inject password keystrokes via CGEvent. Returns true if at least one event posted.
    /// isSecureCheck is called before each batch to verify screen is still locked.
    /// 采用三级降级策略：cgSessionEventTap -> cghidEventTap -> AppleScript
    func fakeKeyStrokes(_ string: String, isSecureCheck: () -> Bool) -> Bool {
        _log(component: "SystemInteraction", "fakeKeyStrokes() START - \(string.count) chars")
        Log.sm.debug("PASSWORD: attempting keystroke injection for \(string.count) chars")

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
        let result = injectWithAppleScript(string)
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
    private func injectWithAppleScript(_ string: String) -> Bool {
        guard string.canBeConverted(to: .ascii) else {
            Log.sm.debug("PASSWORD: AppleScript rejected - non-ASCII characters")
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
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
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
