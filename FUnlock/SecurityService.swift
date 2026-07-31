import Foundation
import Cocoa

/// Keychain 操作错误类型，用于区分冷启动等安全限制场景
enum KeychainError: Error, CustomStringConvertible {
    /// 冷启动：系统重启后用户尚未手动解锁一次
    case coldBoot
    /// 其他 Keychain 错误
    case other(OSStatus, String?)

    var description: String {
        switch self {
        case .coldBoot:
            return "Keychain 冷启动：设备重启后需手动解锁一次"
        case .other(let status, let msg):
            return msg ?? "Keychain 错误 Status \(status)"
        }
    }
}

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
            String(kSecAttrAccessible): kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
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

    /// Fetch password from Keychain.
    /// - Returns: password string on success, nil on not-found (shows modal if warn=true), KeychainError on security error.
    func fetchPassword(warn: Bool = false) -> Result<String?, KeychainError> {
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
            return .success(nil)
        }
        if status == errSecInteractionNotAllowed {
            return .failure(.coldBoot)
        }
        guard status == errSecSuccess else {
            let info = SecCopyErrorMessageString(status, nil)
            return .failure(.other(status, info as String?))
        }
        guard let data = item as? Data else {
            UIHelper.errorModal(t("failed_convert_password"))
            return .success(nil)
        }
        return .success(String(data: data, encoding: .utf8))
    }

    /// 便捷方法：从 Result 中提取密码，冷启动时显示提示并返回 nil
    func fetchPasswordOrShowError(warn: Bool = false) -> String? {
        switch fetchPassword(warn: warn) {
        case .success(let pw):
            return pw
        case .failure(let error):
            if error.isColdBoot {
                UIHelper.errorModal(t("cold_boot_keychain"), info: error.description)
            } else {
                UIHelper.errorModal(t("failed_retrieve_password"), info: error.description)
            }
            return nil
        }
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
        if case .failure = fetchPassword() { return }
        if case .success(nil) = fetchPassword() { return }
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

// MARK: - KeychainError 便捷扩展

extension KeychainError {
    /// 是否为冷启动错误（errSecInteractionNotAllowed）
    var isColdBoot: Bool {
        if case .coldBoot = self { return true }
        return false
    }

    /// 底层 OSStatus（仅 .other 有值）
    var osStatus: OSStatus? {
        if case .other(let status, _) = self { return status }
        return nil
    }
}
