// DiagnosticsView.swift
// 「诊断」Tab：解锁/锁屏决策时间线，基于 DecisionLogger 渲染原因与操作按钮

import SwiftUI

extension DecisionCategory {
    /// 过滤器 chip 的本地化 key
    var filterKey: String {
        switch self {
        case .unlock: return "diagnostics_filter_unlock"
        case .lock: return "diagnostics_filter_lock"
        case .system: return "diagnostics_filter_system"
        case .user: return "diagnostics_filter_user"
        }
    }
}

struct DiagnosticsView: View {
    @ObservedObject var manager: FUnManager
    @ObservedObject var logger: DecisionLogger
    let onNavigate: (MenuTab) -> Void

    @State private var filter: DecisionCategory?

    init(manager: FUnManager, logger: DecisionLogger = DecisionLogger.shared,
         onNavigate: @escaping (MenuTab) -> Void) {
        self.manager = manager
        self.logger = logger
        self.onNavigate = onNavigate
    }

    private var filteredEvents: [DecisionEvent] {
        guard let filter else { return logger.events }
        return logger.events.filter { $0.category == filter }
    }

    /// 按日期分组（今天/昨天/更早），组内时间倒序
    private var groupedEvents: [(title: String, events: [DecisionEvent])] {
        let cal = Calendar.current
        let events = filteredEvents.reversed()
        return Dictionary(grouping: events) { event in
            cal.startOfDay(for: event.timestamp)
        }
        .keys.sorted(by: >)
        .map { day in
            let title: String
            if cal.isDateInToday(day) {
                title = t("diagnostics_today")
            } else if cal.isDateInYesterday(day) {
                title = t("diagnostics_yesterday")
            } else {
                title = day.formatted(.dateTime.month().day())
            }
            let dayEvents = events.filter { cal.isDate($0.timestamp, inSameDayAs: day) }
            return (title, dayEvents)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                filterChips
                if filteredEvents.isEmpty {
                    emptyState
                } else {
                    timeline
                }
                clearFooter
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            if logger.events.isEmpty { logger.loadHistory() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(t("diagnostics"))
                    .font(.system(size: 15, weight: .bold))
                Text(t("diagnostics_subtitle"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - 过滤器

    private var filterChips: some View {
        HStack(spacing: 6) {
            chipButton(title: t("diagnostics_all"), isSelected: filter == nil) {
                filter = nil
            }
            ForEach(DecisionCategory.allCases, id: \.self) { cat in
                chipButton(title: t(cat.filterKey), isSelected: filter == cat) {
                    filter = cat
                }
            }
        }
    }

    private func chipButton(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 时间轴

    /// 轴布局常量：保持 columnWidth / 2 == lineOffset + lineWidth / 2 即可让圆点与竖线对齐
    private enum AxisLayout {
        static let columnWidth: CGFloat = 18
        static let dotSize: CGFloat = 9
        static let lineWidth: CGFloat = 2
    }

    private var timeline: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(groupedEvents, id: \.title) { group in
                Text(group.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                timelineGroup(for: group)
            }
        }
    }

    /// 单组时间轴：左侧一条竖线贯穿整组，每个事件是轴上的一个节点
    private func timelineGroup(for group: (title: String, events: [DecisionEvent])) -> some View {
        ZStack(alignment: .topLeading) {
            // 竖线：中心 x = columnWidth / 2，与节点圆点水平居中对齐
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(width: AxisLayout.lineWidth)
                .padding(.leading, AxisLayout.columnWidth / 2 - AxisLayout.lineWidth / 2)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(group.events) { event in
                    itemRow(for: event)
                }
            }
        }
    }

    /// 时间轴节点行：圆点位于竖线上，右侧为事件内容
    private func itemRow(for event: DecisionEvent) -> some View {
        let iconInfo = event.icon
        return HStack(alignment: .top, spacing: 8) {
            // 节点圆点：轴列内水平居中，描边色 = 事件状态色，背景填充遮住竖线
            Circle()
                .fill(Color(nsColor: .windowBackgroundColor))
                .frame(width: AxisLayout.dotSize, height: AxisLayout.dotSize)
                .overlay(Circle().stroke(iconInfo.1, lineWidth: AxisLayout.lineWidth))
                .frame(width: AxisLayout.columnWidth)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: iconInfo.0)
                        .font(.system(size: 11))
                        .foregroundColor(iconInfo.1)
                        .frame(width: 16)
                    Text(t(event.reason?.titleKey ?? event.outcome.rawValue))
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    Text(Self.timeString(event.timestamp))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                if !event.detail.isEmpty {
                    Text(event.detail)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                if let screenKey = DecisionEvent.screenLabel(event.screen) {
                    Text(t(screenKey))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                HStack(spacing: 8) {
                    if let device = event.device {
                        Text(device).font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Spacer()
                    if let action = event.reason?.action {
                        Button(t(action.labelKey)) { perform(action) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(.vertical, 5)
    }

    // MARK: - 操作

    private func perform(_ hint: ActionHint) {
        switch hint {
        case .lowerUnlockThreshold:
            let current = manager.unlockRSSI
            let next = current == manager.fun.UNLOCK_DISABLED ? -95 : max(current - 5, -100)
            manager.setUnlockRSSI(next)
        case .openAccessibilitySettings:
            SystemInteractionService.shared.openAccessibilitySettings()
        case .reEnterPassword:
            SecurityService.shared.askPassword()
        case .goToTab(let tabKey):
            if let tab = MenuTab(rawValue: tabKey) { onNavigate(tab) }
        case .resetStateMachine:
            manager.stateMachine.resetToActive()
        }
    }

    // MARK: - 空状态 / 清空

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 26))
                .foregroundColor(.secondary)
            Text(t("diagnostics_empty"))
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Text(t("diagnostics_empty_hint"))
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var clearFooter: some View {
        HStack {
            Spacer()
            Button(t("diagnostics_clear")) { logger.clear() }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 渲染辅助

    static func timeString(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }
}
