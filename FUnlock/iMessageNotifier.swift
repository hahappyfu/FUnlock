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

    /// 测试注入点：替换真实 AppleScript 执行，便于单测（默认 nil）。
    /// 仅供测试进程在调用 send/sendTestNotification 之前设置；运行期恒为 nil，
    /// 不要在生产代码赋值，避免未来并行调用产生竞态。
    var scriptRunner: ((String, String) -> String?)?

    /// 仅供测试：清空防抖时间戳，避免测试间相互影响。
    func resetDebounceForTesting() {
        lock.lock()
        lastSendTime.removeAll()
        lock.unlock()
    }

    /// 开关 / 收件人读取（复用现有 Keys enum）
    private var enabled: Bool {
        ConfigStore.shared.bool(forKey: Keys.enabled)
    }
    private var recipient: String? {
        ConfigStore.shared.string(forKey: Keys.recipient)
    }

    /// 语义化事件发送：锁屏/解锁时由 FUnManager 调用。失败静默丢弃（锁时不打扰用户）。
    /// 防抖按事件类型（lock/unlock/test）各 30 秒。
    func send(_ event: IMEvent) {
        guard enabled else { return }
        guard let recipient = recipient, !recipient.isEmpty else { return }

        let typeKey: String
        switch event {
        case .locked: typeKey = "lock"
        case .unlocked: typeKey = "unlock"
        case .test: typeKey = "test"
        }

        // 同类型 30 秒内防抖
        let now = Date()
        lock.lock()
        if let last = lastSendTime[typeKey], now.timeIntervalSince(last) < debounceInterval {
            lock.unlock()
            return
        }
        lastSendTime[typeKey] = now
        lock.unlock()

        let (title, body) = IMMessageComposer.compose(event)
        let text = "\(title)\n\(body)"
        queue.async { [weak self] in
            guard let self = self else { return }
            let err: String?
            if let runner = self.scriptRunner {
                err = runner(recipient, text)
            } else {
                err = self.runAppleScript(recipient: recipient, text: text)
            }
            if let err = err {
                Log.ble.debug("[iMessage] 发送失败（静默丢弃）: \(err)")
            }
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

    /// 转义 AppleScript 字符串字面量中的 `\` 与 `"`，防止收件人/文本含引号时脚本语法被破坏
    private func escapedAppleScriptString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// 执行 AppleScript 发送 iMessage。成功返回 nil，失败返回可读错误描述。
    /// 注意：通过外部 /usr/bin/osascript 执行，而非进程内 NSAppleScript。
    /// LSUIElement（菜单栏）App 进程内 NSAppleScript 触发 TCC AppleEvents 检查时，
    /// 系统不弹授权框并静默拒绝（-1743），外部 osascript 可正常弹出授权提示。
    @discardableResult
    private func runAppleScript(recipient: String, text: String) -> String? {
        let script = """
        tell application "Messages"
            set targetService to 1st service whose service type = iMessage
            set targetBuddy to buddy "\(escapedAppleScriptString(recipient))" of targetService
            send "\(escapedAppleScriptString(text))" to targetBuddy
        end tell
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            if task.terminationStatus == 0 { return nil }
            return Self.parseScriptError(output: output)
        } catch {
            return "无法启动 osascript：\(error.localizedDescription)"
        }
    }

    /// 解析 osascript 错误输出（格式形如 "36:53: execution error: Messages 遇到一个错误：xxx。(-1743)"）
    static func parseScriptError(output: String) -> String {
        guard !output.isEmpty else { return "发送失败：osascript 退出（状态非 0）" }
        // 提取错误码（形如 "(-1743)" 或 "（-1743）"）
        let number: Int
        if let match = output.range(of: #"\((-?\d+)\)"#, options: .regularExpression) {
            number = Int(output[match].replacingOccurrences(of: "(", with: "")
                                        .replacingOccurrences(of: ")", with: "")) ?? -1
        } else {
            number = -1
        }
        // 提取错误信息主体（去掉前缀 "xx:xx: execution error: " 与尾部错误码）
        let trimmed = output
            .replacingOccurrences(of: #"^\d+:\d+: execution error: "#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return friendlyError(number: number, message: trimmed)
    }

    /// 手动测试：把 NSAppleScript 错误字典转换为用户可读的中文提示
    static func friendlyError(errorInfo: [String: Any]) -> String {
        let number = errorInfo["NSAppleScriptErrorNumber"] as? Int ?? -1
        let message = errorInfo["NSAppleScriptErrorMessage"] as? String ?? "未知错误"
        return friendlyError(number: number, message: message)
    }

    /// 按错误码映射为中文提示
    static func friendlyError(number: Int, message: String) -> String {
        if number == -1743 {
            return "Messages 未授权：请在 系统设置 → 隐私与安全性 → 自动化 中允许 Funlock 控制 Messages"
        }
        if message.localizedCaseInsensitiveContains("buddy") || message.localizedCaseInsensitiveContains("not found") {
            return "收件人无效：请检查号码/账号是否为 iMessage 好友（需先在 Messages 中有会话）"
        }
        return "发送失败：\(message)（错误码 \(number)）"
    }
}
