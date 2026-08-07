// iMessageNotifier.swift
// 通过 AppleScript 调用 Messages 给自己发 iMessage，解锁/锁屏时通知到 Apple Watch

import Foundation

/// iMessage 通知单例
final class iMessageNotifier {
    /// 手动测试发送结果。用嵌套私有类型避免全局污染 String 的 Error 遵循。
    struct SendError: Error {
        let message: String
    }

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

    /// 测试注入点：替换真实 AppleScript 执行，便于单测（默认 nil）
    var scriptRunner: ((String, String) -> String?)?

    /// 开关 / 收件人读取（复用现有 Keys enum）
    private var enabled: Bool {
        UserDefaults.standard.bool(forKey: Keys.enabled)
    }
    private var recipient: String? {
        UserDefaults.standard.string(forKey: Keys.recipient)
    }

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

    /// 手动连通性测试：发送并返回结果（成功 .success, 失败 .failure+原因）。
    /// 绕过 30s 防抖、不写 lastSendTime —— 测试就是要反复验证。
    /// completion 在主线程回调。
    func sendTestNotification(title: String, message: String,
                              completion: @escaping (Result<Void, iMessageNotifier.SendError>) -> Void) {
        guard enabled else {
            DispatchQueue.main.async {
                completion(.failure(iMessageNotifier.SendError(message: "iMessage 通知开关未开启，请先开启")))
            }
            return
        }
        guard let recipient = recipient, !recipient.isEmpty else {
            DispatchQueue.main.async {
                completion(.failure(iMessageNotifier.SendError(message: "收件人为空，请先填写 iMessage 收件人")))
            }
            return
        }
        let text = "\(title)\n\(message)"
        queue.async { [weak self] in
            guard let self = self else { return }
            let err: String?
            if let runner = self.scriptRunner {
                err = runner(recipient, text)
            } else {
                err = self.runAppleScript(recipient: recipient, text: text)
            }
            DispatchQueue.main.async {
                if let err = err {
                    completion(.failure(iMessageNotifier.SendError(message: err)))
                } else {
                    completion(.success(()))
                }
            }
        }
    }

    /// 执行 AppleScript 发送 iMessage。成功返回 nil，失败返回可读错误描述。
    @discardableResult
    private func runAppleScript(recipient: String, text: String) -> String? {
        let script = """
        tell application "Messages"
            set targetService to 1st service whose service type = iMessage
            set targetBuddy to buddy "\(recipient)" of targetService
            send "\(text)" to targetBuddy
        end tell
        """
        guard let appleScript = NSAppleScript(source: script) else {
            return "AppleScript 源码编译失败"
        }
        var errorInfo: NSDictionary?
        appleScript.executeAndReturnError(&errorInfo)
        guard let errorInfo = errorInfo else { return nil }
        return Self.friendlyError(errorInfo: errorInfo as? [String: Any] ?? [:])
    }

    /// 手动测试：把 NSAppleScript 错误字典转换为用户可读的中文提示
    static func friendlyError(errorInfo: [String: Any]) -> String {
        let number = errorInfo["NSAppleScriptErrorNumber"] as? Int ?? -1
        let message = errorInfo["NSAppleScriptErrorMessage"] as? String ?? "未知错误"
        if number == -1743 {
            return "Messages 未授权：请在 系统设置 → 隐私与安全性 → 自动化 中允许 FUnlock 控制 Messages"
        }
        if message.localizedCaseInsensitiveContains("buddy") || message.localizedCaseInsensitiveContains("not found") {
            return "收件人无效：请检查号码/账号是否为 iMessage 好友（需先在 Messages 中有会话）"
        }
        return "发送失败：\(message)（错误码 \(number)）"
    }
}
