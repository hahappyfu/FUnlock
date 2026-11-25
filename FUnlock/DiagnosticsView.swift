// DiagnosticsView.swift
// 信号与诊断：真数据 KPI + 信号/斜率曲线 + 决策时间线（40 行分块）

import SwiftUI
import AppKit
import UniformTypeIdentifiers

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

extension Array {
    /// 按固定大小切块（最后一块可短于 size）；空数组返回空
    func chunked(pageSize size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

struct DiagnosticsView: View {
    var manager: FUnManager
    var logger: DecisionLogger
    let onNavigate: (MenuTab) -> Void

    @State private var filter: DecisionCategory?
    @State private var chartMode: ChartMode = .signal

    private var dataStore = SignalDataStore.shared

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
            VStack(alignment: .leading, spacing: FUnlockTheme.Space.sm) {
                kpiRow
                chartsCard
                header
                filterChips
                if filteredEvents.isEmpty {
                    emptyState
                } else {
                    timeline
                }
                clearFooter
            }
            .padding(.horizontal, FUnlockTheme.Space.md)
            .padding(.top, FUnlockTheme.Space.sm)
            .padding(.bottom, FUnlockTheme.Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            if logger.events.isEmpty { logger.loadHistory() }
        }
    }

    // MARK: - KPI

    private var todayUnlocks: Int { StatsCalculator.todayUnlocks(logger.events) }
    private var todayLocks: Int { StatsCalculator.todayLocks(logger.events) }
    private var thisWeekUnlocks: Int { StatsCalculator.thisWeekUnlocks(logger.events) }

    private var kpiRow: some View {
        HStack(spacing: FUnlockTheme.Space.sm) {
            kpiCard(t("stats_today_unlocks"), value: todayUnlocks,
                    icon: "lock.open.fill", tone: .safe)
            kpiCard(t("stats_today_locks"), value: todayLocks,
                    icon: "lock.fill", tone: .amber)
            kpiCard(t("stats_week_unlocks"), value: thisWeekUnlocks,
                    icon: "calendar", tone: .neutral)
        }
    }

    private func kpiCard(_ title: String, value: Int, icon: String, tone: StatusTone) -> some View {
        FUnlockCard(padding: FUnlockTheme.Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(FUnlockTheme.Text.secondary.color)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(value)")
                        .font(.title.monospacedDigit().weight(.semibold))
                        .foregroundStyle(FUnlockTheme.Text.primary.color)
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(tone.fillColor)
                }
            }
        }
    }

    // MARK: - 图表

    private var chartsCard: some View {
        FUnlockCard {
            VStack(alignment: .leading, spacing: FUnlockTheme.Space.sm) {
                HStack(spacing: FUnlockTheme.Space.xs) {
                    Text(t("stats_signal_diagnostics"))
                        .font(.headline)
                        .foregroundStyle(FUnlockTheme.Text.primary.color)
                    Spacer(minLength: FUnlockTheme.Space.xs)
                    Picker("", selection: $chartMode) {
                        ForEach(ChartMode.allCases, id: \.self) { mode in
                            Text(t(mode.rawValue)).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 160)
                }

                TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                    let currentSamples = dataStore.snapshot()
                    if currentSamples.isEmpty {
                        Text(t("stats_no_data"))
                            .font(.callout)
                            .foregroundStyle(FUnlockTheme.Text.secondary.color)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, FUnlockTheme.Space.md)
                    } else {
                        chartBody(samples: currentSamples)
                        HStack {
                            Spacer(minLength: 0)
                            chartLegend
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func chartBody(samples: [SignalSample]) -> some View {
        switch chartMode {
        case .signal:
            SignalChartView(samples: samples,
                            unlockThreshold: dataStore.unlockThreshold,
                            lockThreshold: dataStore.lockThreshold)
        case .slope:
            SlopeChartView(samples: samples)
        }
    }

    private var chartLegend: some View {
        HStack(spacing: FUnlockTheme.Space.md) {
            if chartMode == .signal {
                legendDot(color: .gray, label: "Raw RSSI")
                legendDot(color: .blue, label: "Kalman")
                legendDot(color: .purple, label: "Effective")
                legendDot(color: .red, label: t("stats_anomaly"))
            } else {
                legendDot(color: .orange, label: "Slope")
            }
        }
        .font(.caption2)
        .foregroundStyle(FUnlockTheme.Text.secondary.color)
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text(t("diagnostics_subtitle"))
                .font(.caption)
                .foregroundStyle(FUnlockTheme.Text.secondary.color)
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
                .font(.caption.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? FUnlockTheme.Accent.base.color
                                            : FUnlockTheme.Text.secondary.color)
                .padding(.horizontal, FUnlockTheme.Space.sm)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(isSelected
                                   ? FUnlockTheme.Accent.base.color.opacity(0.12)
                                   : FUnlockTheme.Surface.well.color)
                )
                .overlay(
                    Capsule().strokeBorder(
                        isSelected ? FUnlockTheme.Accent.base.color.opacity(0.45)
                                   : FUnlockTheme.Surface.border.color,
                        lineWidth: 1)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - 时间轴

    /// 轴布局常量：保持 columnWidth / 2 == lineOffset + lineWidth / 2 即可让圆点与竖线对齐
    private enum AxisLayout {
        static let columnWidth: CGFloat = 18
        static let dotSize: CGFloat = 9
        static let lineWidth: CGFloat = 2
        static let guideLineWidth: CGFloat = 1.5
        static let guideLineOpacity: Double = 0.2
    }

    private var timeline: some View {
        LazyVStack(alignment: .leading, spacing: FUnlockTheme.Space.sm) {
            ForEach(groupedEvents, id: \.title) { group in
                Text(group.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FUnlockTheme.Text.secondary.color)
                    .padding(.top, 2)
                // 分块渲染：同一天可能有数百条事件，整组作为单个渲染单元会让滚动每帧重建
                ForEach(makeChunks(from: group.events)) { chunk in
                    timelineGroup(events: chunk.events)
                }
            }
        }
    }

    /// 单张卡片的最大行数：控制滚动时单次重建的渲染单元规模
    static let timelinePageSize = 40

    private struct EventChunk: Identifiable {
        let id: UUID
        let events: [DecisionEvent]
    }

    private func makeChunks(from events: [DecisionEvent]) -> [EventChunk] {
        events.chunked(pageSize: Self.timelinePageSize).compactMap { chunk in
            chunk.first.map { EventChunk(id: $0.id, events: chunk) }
        }
    }

    private func timelineGroup(events: [DecisionEvent]) -> some View {
        FUnlockCard(padding: FUnlockTheme.Space.xs) {
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(FUnlockTheme.Surface.border.color)
                    .frame(width: AxisLayout.guideLineWidth)
                    .padding(.leading, AxisLayout.columnWidth / 2 - AxisLayout.guideLineWidth / 2)
                    .padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(events) { event in
                        itemRow(for: event)
                    }
                }
            }
        }
        .id(events.first?.id)
    }

    private func itemRow(for event: DecisionEvent) -> some View {
        let iconInfo = event.icon
        return HStack(alignment: .top, spacing: FUnlockTheme.Space.xs) {
            Circle()
                .fill(iconInfo.1.opacity(0.22))
                .frame(width: AxisLayout.dotSize, height: AxisLayout.dotSize)
                .overlay(Circle().stroke(iconInfo.1, lineWidth: AxisLayout.lineWidth))
                .frame(width: AxisLayout.columnWidth)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: iconInfo.0)
                        .font(.caption)
                        .foregroundStyle(iconInfo.1)
                        .frame(width: 16)
                    Text(t(event.reason?.titleKey ?? event.outcome.rawValue))
                        .font(.body.weight(.medium))
                        .foregroundStyle(FUnlockTheme.Text.primary.color)
                        .lineLimit(1)
                    Spacer()
                    Text(Self.timeString(event.timestamp))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(FUnlockTheme.Text.secondary.color)
                }
                if !event.detail.isEmpty {
                    Text(event.detail)
                        .font(.caption)
                        .foregroundStyle(FUnlockTheme.Text.secondary.color)
                        .lineLimit(2)
                }
                if let screenKey = DecisionEvent.screenLabel(event.screen) {
                    Text(t(screenKey))
                        .font(.caption)
                        .foregroundStyle(FUnlockTheme.Text.secondary.color)
                }
                HStack(spacing: FUnlockTheme.Space.xs) {
                    if let rssi = event.rssi, event.detail.isEmpty {
                        Text("\(rssi) dBm")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(FUnlockTheme.Text.secondary.color)
                    }
                    if let device = event.device {
                        Text(device)
                            .font(.caption)
                            .foregroundStyle(FUnlockTheme.Text.secondary.color)
                    }
                    Spacer()
                    if let action = event.reason?.action {
                        InstrumentButton(title: t(action.labelKey), kind: .secondary) {
                            perform(action)
                        }
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
            let next = SignalHysteresisEngine.stepUnlockThreshold(current: current, delta: -5)
            manager.setUnlockRSSI(next)
        case .openAccessibilitySettings:
            SystemInteractionService.shared.openAccessibilitySettings()
        case .reEnterPassword:
            SecurityService.shared.askPassword()
        case .goToTab(let tabKey):
            // 旧 key（basic/unlock/lock/network/config）经兼容路由映射到新分区
            if let tab = MenuTab.resolve(tabKey) { onNavigate(tab) }
        case .resetStateMachine:
            manager.stateMachine.resetToActive()
        }
    }

    // MARK: - 空状态 / 清空

    private var emptyState: some View {
        VStack(spacing: FUnlockTheme.Space.xs) {
            Image(systemName: "waveform.path.ecg")
                .font(.title2)
                .foregroundStyle(FUnlockTheme.Text.secondary.color)
            Text(t("diagnostics_empty"))
                .font(.body)
                .foregroundStyle(FUnlockTheme.Text.secondary.color)
            Text(t("diagnostics_empty_hint"))
                .font(.caption)
                .foregroundStyle(FUnlockTheme.Text.tertiary.color)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, FUnlockTheme.Space.xl)
    }

    private var clearFooter: some View {
        HStack {
            InstrumentButton(title: t("export_diagnostics"), kind: .secondary, action: exportDiagnostics)
            Spacer()
            InstrumentButton(title: t("diagnostics_clear"), kind: .ghost) { logger.clear() }
        }
    }

    private func exportDiagnostics() {
        let fm = FileManager.default
        // 路径单源：各 logger 暴露的文件 URL（测试目录重定向时自动跟随）
        let candidates: [URL] = [
            DebugLog.logFileURL,
            timingLogFileURL,
            DecisionLogger.shared.logFile,
            TelemetryLogger.shared.testLogFile,
            ScriptRunner.shared.eventsLogURL,
        ].compactMap { $0 }.filter { fm.fileExists(atPath: $0.path) }

        guard !candidates.isEmpty else {
            let alert = NSAlert()
            alert.messageText = t("export_diagnostics")
            alert.informativeText = t("diagnostics_empty")
            alert.alertStyle = .informational
            alert.addButton(withTitle: t("ok"))
            alert.runModal()
            return
        }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyyMMdd-HHmmss"
        let defaultName = "FUnlock-diagnostics-\(df.string(from: Date())).zip"

        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        // 移出主线程：文件拷贝 + 同步 zip 打包（Process.waitUntilExit 会阻塞到子进程结束）
        Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
                for src in candidates {
                    let dst = tmpDir.appendingPathComponent(src.lastPathComponent)
                    try? FileManager.default.copyItem(at: src, to: dst)
                }
                if FileManager.default.fileExists(atPath: dest.path) { try? FileManager.default.removeItem(at: dest) }
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                let fileNames = try FileManager.default.contentsOfDirectory(atPath: tmpDir.path)
                task.arguments = ["-j", dest.path] + fileNames
                task.currentDirectoryURL = tmpDir
                try task.run()
                task.waitUntilExit()
                guard task.terminationStatus == 0 else { throw NSError(domain: "zip", code: Int(task.terminationStatus)) }
                try? FileManager.default.removeItem(at: tmpDir)
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = t("export_diagnostics")
                    alert.informativeText = dest.path
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: t("ok"))
                    alert.runModal()
                }
            } catch {
                try? FileManager.default.removeItem(at: tmpDir)
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = t("export_diagnostics")
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: t("ok"))
                    alert.runModal()
                }
            }
        }
    }

    // MARK: - 渲染辅助

    static func timeString(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }
}
