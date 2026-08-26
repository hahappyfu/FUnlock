// QuotaCard.swift
// 套餐余量卡的展示纯函数 + 视图。纯函数区供单测，视图区不自持业务状态。
import SwiftUI

// MARK: - 展示纯函数（唯一事实源）

/** 用量阈值色：<50 绿 · [50,80] 琥珀 · >80 红。进度条一律走这里，禁止硬编码。 */
func quotaColor(percent: Double) -> Color {
    if percent > 80 { return Color(red: 1.0, green: 0.231, blue: 0.188) }   // #FF3B30
    if percent >= 50 { return Color(red: 1.0, green: 0.624, blue: 0.039) }  // #FF9F0A
    return Color(red: 0.204, green: 0.780, blue: 0.349)                     // #34C759
}

/// 至多一位小数的紧凑数字（12.0 → "12"，1.234 → "1.2"）
private func oneDecimal(_ v: Double) -> String {
    let r = (v * 10).rounded() / 10
    return r == r.rounded() ? String(Int(r)) : String(r)
}

/** 大数缩写：≥1e8 → x.x 亿；≥1e4 → x.x 万；否则至多一位小数；非法 → "--"。 */
func formatNum(_ n: Double) -> String {
    guard n.isFinite else { return "--" }
    if n >= 1e8 { return oneDecimal(n / 1e8) + " 亿" }
    if n >= 1e4 { return oneDecimal(n / 1e4) + " 万" }
    return oneDecimal(n)
}

/** 重置倒计时文案（入参为剩余秒数，与缓存 resetInSec 同单位）。 */
func humanizeReset(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds > 0 else { return t("quota_reset_soon") }
    if seconds >= 86_400 {
        return String(format: t("quota_reset_days"), Int((seconds / 86_400).rounded()))
    }
    if seconds >= 3_600 {
        var h = Int(seconds / 3_600)
        var m = Int((seconds.truncatingRemainder(dividingBy: 3_600) / 60).rounded())
        if m == 60 { h += 1; m = 0 }   // 余数秒 ≥3570 时 rounded() 进到 60（如 1:59:59），须向小时进位
        return m == 0 ? String(format: t("quota_reset_hours"), h)
                      : String(format: t("quota_reset_hours_min"), h, m)
    }
    if seconds >= 60 {
        return String(format: t("quota_reset_minutes"), max(1, Int((seconds / 60).rounded())))
    }
    return t("quota_reset_soon")
}

/** 数据新鲜度文案。 */
func timeAgoText(_ fetchedAt: Date?, now: Date) -> String {
    guard let fetchedAt else { return t("quota_no_time") }
    let diff = now.timeIntervalSince(fetchedAt)
    if diff < 60 { return t("quota_updated_just_now") }
    return String(format: t("quota_updated_ago"), Int(diff / 60))
}
