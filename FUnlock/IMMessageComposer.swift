// IMMessageComposer.swift
// 纯函数：iMessage 事件 → 本地化通知文案（标题/正文），收件人格式化
// 无依赖、无状态，便于单元测试

import Foundation

/// iMessage 通知事件
enum IMEvent {
    case locked(reason: String, rssi: Double?, deviceName: String?)
    case unlocked(rssi: Double?, deviceName: String?)
    case test
}

enum IMMessageComposer {

    /// 事件 → (标题, 正文)。正文示例：`今天 23:45 · iPhone 信号 -88 dBm`
    /// - Parameter now: 注入当前时间，便于测试昨天分支（默认 .now）
    static func compose(_ event: IMEvent, now: Date = .now) -> (title: String, body: String) {
        let title: String
        let rssi: Double?
        let deviceName: String?
        switch event {
        case .locked(_, let r, let d):
            title = t("im_title_locked")
            rssi = r
            deviceName = d
        case .unlocked(let r, let d):
            title = t("im_title_unlocked")
            rssi = r
            deviceName = d
        case .test:
            title = t("im_title_unlocked")
            rssi = nil
            deviceName = nil
        }

        var parts: [String] = [timePart(now: now)]
        let signalPart = rssi.map { String(format: t("im_body_signal"), Int($0.rounded())) }
        if let deviceName, !deviceName.isEmpty {
            if let signalPart {
                parts.append("\(deviceName) \(signalPart)")
            } else {
                parts.append(deviceName)
            }
        } else if let signalPart {
            parts.append(signalPart)
        }
        return (title, parts.joined(separator: " · "))
    }

    /// 收件人规范化：`+86 138-1234 5678 → +8613812345678`；邮箱原样（去首尾空白）
    /// 注意：保留 `+` 国际前缀，否则 buddy 匹配失败（iMessage 按 +86... 国际格式寻址）
    static func normalizeRecipient(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.contains("@") { return trimmed }
        return trimmed
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
    }

    // MARK: - 私有

    /// 时间词 + HH:mm（今天/昨天）
    private static func timePart(now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        let time = formatter.string(from: now)
        let key = Calendar.current.isDateInToday(now) ? "im_body_time_today" : "im_body_time_yesterday"
        return String(format: t(key), time)
    }
}
