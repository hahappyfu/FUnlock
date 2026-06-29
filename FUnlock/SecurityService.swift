import Foundation
import Cocoa

final class SecurityService {
    static let shared = SecurityService()
    private init() {}

    // MARK: - Keychain

    /// Store password in Keychain. Returns nil on success, error message on failure.
    @discardableResult
    func storePassword(_ password: String) -> String? {
        guard let pw = password.data(using: .utf8) else { return "encoding error" }
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
            return err as String? ?? "Status \(status)"
        }
        return nil
    }

    /// Fetch password from Keychain. If warn=true and not found, shows error modal.
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
            if warn { UIHelper.errorModal(t("password_not_set")) }
            return nil
        }
        guard status == errSecSuccess else {
            let info = SecCopyErrorMessageString(status, nil)
            UIHelper.errorModal(t("failed_retrieve_password"), info: info as String? ?? "Status \(status)")
            return nil
        }
        guard let data = item as? Data else {
            UIHelper.errorModal(t("failed_convert_password"))
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Delete stored password from Keychain
    func deletePassword() {
        let query: [String: Any] = [
            String(kSecClass): kSecClassGenericPassword,
            String(kSecAttrAccount): NSUserName(),
            String(kSecAttrService): Bundle.main.bundleIdentifier ?? "FUnlock",
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Password Change Detection

    /// Handle system password change notification: clear old password and prompt user
    func handlePasswordChanged() {
        guard fetchPassword() != nil else { return }
        Log.sm.debug("system password changed, clearing stored password")
        deletePassword()

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

    // MARK: - Password Dialog

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
            let err = storePassword(txt.stringValue)
            if let err = err {
                UIHelper.errorModal(t("failed_store_password"), info: err)
            }
        }
    }
}

// MARK: - UI Helper (shared alert utilities)

enum UIHelper {
    static func errorModal(_ msg: String, info: String? = nil) {
        let alert = NSAlert()
        alert.messageText = msg
        alert.informativeText = info ?? ""
        alert.window.title = "FUnlock"
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
