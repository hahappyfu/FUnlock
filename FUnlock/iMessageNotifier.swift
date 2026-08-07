// iMessageNotifier.swift
// 通过 AppleScript 调用 Messages 给自己发 iMessage，解锁/锁屏时通知到 Apple Watch

import Foundation

/// iMessage 通知单例
final class iMessageNotifier {
    static let shared = iMessageNotifier()
    private init() {}

    private enum Keys {
        static let recipient = "iMessageNotifyRecipient"
        static let enabled = "iMessageNotify"
    }

    private let queue = DispatchQueue(label: "com.funlock.imessage", qos: .utility)
    private let debounceInterval: TimeInterval = 30.0
    private var lastSendTime: [String: Date] = [:]
    private let lock = NSLock()

    /// 发送一条 iMessage 给自己（异步、防抖、失败静默）
    func sendNotification(title: String, message: String) {
        // 开关未启用或收件人为空则不发送
        guard UserDefaults.standard.bool(forKey: Keys.enabled) else { return }
        guard let recipient = UserDefaults.standard.string(forKey: Keys.recipient), !recipient.isEmpty else { return }

        // 同状态 30 秒内防抖
        let now = Date()
        lock.lock()
        if let last = lastSendTime[title], now.timeIntervalSince(last) < debounceInterval {
            lock.unlock()
            return
        }
        lastSendTime[title] = now
        lock.unlock()

        let text = "\(title)\n\(message)"
        queue.async { [weak self] in
            self?.runAppleScript(recipient: recipient, text: text)
        }
    }

    private func runAppleScript(recipient: String, text: String) {
        let script = """
        tell application "Messages"
            set targetService to 1st service whose service type = iMessage
            set targetBuddy to buddy "\(recipient)" of targetService
            send "\(text)" to targetBuddy
        end tell
        """
        guard let appleScript = NSAppleScript(source: script) else { return }
        var errorInfo: NSDictionary?
        appleScript.executeAndReturnError(&errorInfo)
    }
}