import Foundation
import Cocoa
import UserNotifications

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
        guard isScreenLocked(screenState: screenState) else { return false }
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           frontApp.bundleIdentifier != "com.apple.loginwindow" {
            Log.sm.debug("ABORT: frontmost=\(frontApp.bundleIdentifier ?? "nil"), not loginwindow")
            return false
        }
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
    func fakeKeyStrokes(_ string: String, isSecureCheck: () -> Bool) -> Bool {
        let src = CGEventSource(stateID: .hidSystemState)
        var anyEventPosted = false
        let uniCharCount = string.utf16.count
        var strIndex = string.utf16.startIndex
        for offset in stride(from: 0, to: uniCharCount, by: 20) {
            guard isSecureCheck() else {
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
        guard isSecureCheck() else {
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
