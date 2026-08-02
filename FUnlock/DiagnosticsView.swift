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

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private var filteredEvents: [DecisionEvent] {
        guard let filter else { return logger.events }
        return logger.events.filter { $0.category == filter }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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

    // MARK: - 时间线

    private var timeline: some View {
        LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(filteredEvents.reversed()) { event in
                row(for: event)
            }
        }
    }

    private func row(for event: DecisionEvent) -> some View {
        let iconInfo = Self.icon(for: event)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: iconInfo.0)
                    .font(.system(size: 12))
                    .foregroundColor(iconInfo.1)
                    .frame(width: 18)
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
            HStack(spacing: 8) {
                if let rssi = event.rssi {
                    Text("\(rssi) dBm").font(.system(size: 11)).foregroundColor(.secondary)
                }
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
        .padding(8)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(7)
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

    static func icon(for event: DecisionEvent) -> (String, Color) {
        switch (event.category, event.outcome) {
        case (.unlock, .success): return ("lock.open.fill", .green)
        case (.unlock, .failed), (.unlock, .blocked): return ("exclamationmark.triangle.fill", .red)
        case (.unlock, .skipped): return ("lock.open", .secondary)
        case (.lock, .success): return ("lock.fill", .orange)
        case (.lock, _): return ("lock", .secondary)
        case (.system, _): return ("power", .blue)
        case (.user, _): return ("person.fill", .teal)
        }
    }

    static func timeString(_ date: Date) -> String {
        if date > Date().addingTimeInterval(-24 * 3600) {
            return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
        }
        return date.formatted(.dateTime.month().day().hour().minute())
    }
}
