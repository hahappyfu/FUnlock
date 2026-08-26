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

/// 百分比文案：0 → "0%"，其余保留 1 位小数
private func percentText(_ p: Double) -> String {
    if p == 0 { return "0%" }
    return String(format: "%.1f%%", p)
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

// MARK: - 卡片视图（弹窗与总览页共用）

struct QuotaCard: View {
    @ObservedObject var quota: QuotaService
    @State private var expanded = false

    private var snap: QuotaSnapshot { quota.snapshot }
    /// 有可渲染数据（available 且至少一个合法窗口）；.empty 同时充当加载中骨架
    private var hasData: Bool { snap.available && !snap.windows.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 迷你态行：点击切换展开
            Button {
                guard hasData else { return }
                withAnimation(.easeInOut(duration: 0.22)) { expanded.toggle() }
            } label: {
                miniRow.padding(.vertical, 2)
            }
            .buttonStyle(.plain)

            if expanded && hasData {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(snap.windows, id: \.key) { win in
                        windowRow(win)
                    }
                    Text(t("quota_footer_hint"))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .padding(.top, 2)
                }
                .padding(.top, 10)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // 迷你行：⚡ 标题 + 右侧百分比 + 4px 进度条 + 新鲜度徽标
    private var miniRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(hasData ? badgeColor : .secondary)
                Text(t("quota_title"))
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(displayPercent)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(hasData ? .primary : .secondary)
            }
            bar(percent: hasData ? weeklyWindow?.percent : nil, height: 4)
            HStack(spacing: 4) {
                Circle().fill(badgeColor).frame(width: 5, height: 5)
                Text(badgeText).font(.system(size: 9)).foregroundColor(.secondary)
                Spacer()
            }
        }
    }

    // 展开行：标签 + 倒计时 / 6px 条 + 百分比
    private func windowRow(_ win: QuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(windowLabel(win.key))
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(resetText(win))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 8) {
                bar(percent: win.percent, height: 6)
                    .frame(maxWidth: .infinity)
                Text(percentText(win.percent))
                    .font(.system(size: 9, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                    .fixedSize()
            }
        }
    }

    // 通用进度条：percent=nil 渲染灰色空槽（无数据/加载中），布局高度不变
    private func bar(percent: Double?, height: CGFloat) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                if let p = percent {
                    Capsule()
                        .fill(quotaColor(percent: p))
                        .frame(width: geo.size.width * min(100, max(0, p)) / 100)
                }
            }
        }
        .frame(height: height)
    }

    // ---- 派生展示值 ----

    private var weeklyWindow: QuotaWindow? { snap.windows.first { $0.key == "weekly" } }

    private var displayPercent: String {
        guard hasData, let p = weeklyWindow?.percent else { return "--" }
        return percentText(p)
    }

    // 四态徽标：正常绿 / 过期琥珀 / 无数据与加载中红
    private var badgeColor: Color {
        if !hasData { return .red }
        return snap.expired ? .orange : .green
    }
    private var badgeText: String {
        if !hasData { return t("quota_no_data") }
        if snap.expired { return t("quota_expired") }
        return timeAgoText(snap.fetchedAt, now: Date())
    }

    private func windowLabel(_ key: String) -> String {
        switch key {
        case "5h": return t("quota_5h")
        case "weekly": return t("quota_weekly")
        default: return t("quota_monthly")
        }
    }

    private func resetText(_ win: QuotaWindow) -> String {
        guard let resetAt = win.resetAt else { return "--" }
        return humanizeReset(resetAt.timeIntervalSinceNow)
    }
}
