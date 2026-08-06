// StatsView.swift
// 信号诊断仪表盘 — P1 可观测性升级

import SwiftUI
import Combine

// MARK: - 图表模式

enum ChartMode: String, CaseIterable {
    case signal = "stats_chart_signal"
    case slope  = "stats_chart_slope"
}

// MARK: - 统计面板

struct StatsView: View {
    @Binding var isPresented: Bool
    @ObservedObject private var dataStore = SignalDataStore.shared
    @ObservedObject private var logger = DecisionLogger.shared

    @State private var chartMode: ChartMode = .signal

    private var recentEvents: [DecisionEvent] {
        logger.events
            .filter { $0.category == .unlock || $0.category == .lock }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(10)
            .map { $0 }
    }

    private var todayUnlocks: Int { StatsCalculator.todayUnlocks(logger.events) }
    private var todayLocks: Int { StatsCalculator.todayLocks(logger.events) }
    private var thisWeekUnlocks: Int { StatsCalculator.thisWeekUnlocks(logger.events) }

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text(t("unlock_stats"))
                    .font(.headline)
                Spacer()
                Button(action: { isPresented = false }) {
                    Text(t("done"))
                        .font(.callout)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if dataStore.samples.isEmpty && recentEvents.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "chart.bar.xaxis.ascending")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text(t("stats_no_data"))
                        .font(.callout)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    // 概览
                    Section {
                        HStack(spacing: 10) {
                            largeStatCard(t("stats_today_unlocks"), value: "\(todayUnlocks)", icon: "lock.open.fill", color: .green)
                            largeStatCard(t("stats_today_locks"), value: "\(todayLocks)", icon: "lock.fill", color: .orange)
                            largeStatCard(t("stats_week_unlocks"), value: "\(thisWeekUnlocks)", icon: "calendar", color: .accentColor)
                        }
                        .frame(maxWidth: .infinity)
                    }

                    // 信号图表区域（macOS 13+）
                    if !dataStore.samples.isEmpty {
                        if #available(macOS 13.0, *) {
                            Section {
                                HStack {
                                    Text(t("stats_signal_diagnostics"))
                                        .font(.subheadline.bold())
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Picker("", selection: $chartMode) {
                                        ForEach(ChartMode.allCases, id: \.self) { mode in
                                            Text(t(mode.rawValue)).tag(mode)
                                        }
                                    }
                                    .pickerStyle(.segmented)
                                    .frame(width: 160)
                                }

                                switch chartMode {
                                case .signal:
                                    SignalChartView(samples: dataStore.samples,
                                                    unlockThreshold: dataStore.unlockThreshold,
                                                    lockThreshold: dataStore.lockThreshold)
                                case .slope:
                                    SlopeChartView(samples: dataStore.samples)
                                }

                                HStack {
                                    Spacer()
                                    chartLegend
                                }
                            }
                        } else {
                            // macOS 12 fallback：简易 RSSI 文本列表
                            Section {
                                fallbackSignalList
                            }
                        }
                    }

                    // 最近事件（圆角卡片容器，时间戳在左）
                    Section(t("stats_recent_events")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(t("stats_recent_10"))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            ForEach(recentEvents) { entry in
                                HStack(spacing: 8) {
                                    Text(entry.timestamp, format: .dateTime.hour().minute().second())
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .frame(width: 62, alignment: .leading)
                                    Image(systemName: entry.icon.0)
                                        .font(.system(size: 11))
                                        .foregroundColor(entry.icon.1)
                                        .frame(width: 16)
                                    Text(t(entry.reason?.titleKey ?? entry.outcome.rawValue))
                                        .font(.callout.weight(.medium))
                                        .lineLimit(1)
                                    if !entry.detail.isEmpty {
                                        Text(entry.detail)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                        .padding(10)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .formStyle(.grouped)
            }
        }
        .onAppear { if logger.events.isEmpty { logger.loadHistory() } }
        .frame(width: 440, height: 560)
    }

    // MARK: - macOS 12 fallback（无 Charts 时显示文本摘要）

    private var fallbackSignalList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t("stats_signal_diagnostics"))
                .font(.subheadline.bold())
                .foregroundColor(.secondary)
            let recent = dataStore.samples.suffix(10)
            ForEach(Array(recent.enumerated()), id: \.element.id) { _, sample in
                HStack {
                    Text(sample.timestamp, format: .dateTime.hour().minute().second())
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 65, alignment: .leading)
                    Text("\(t("stats_raw")): \(Int(sample.rawRSSI))")
                        .font(.caption)
                        .frame(width: 60, alignment: .leading)
                    Text("\(t("stats_kalman")): \(Int(sample.kalmanEstimate))")
                        .font(.caption)
                        .frame(width: 65, alignment: .leading)
                    if let event = sample.event {
                        Image(systemName: event == "unlocked" ? "lock.open.fill" : "lock.fill")
                            .font(.caption2)
                            .foregroundColor(event == "unlocked" ? .green : .orange)
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: - 图例

    private var chartLegend: some View {
        HStack(spacing: 16) {
            if chartMode == .signal {
                legendDot(color: .gray, label: "Raw RSSI")
                legendDot(color: .blue, label: "Kalman")
                legendDot(color: .purple, label: "Effective")
                legendDot(color: .red, label: "异常点")
            } else {
                legendDot(color: .orange, label: "Slope")
                legendDot(color: .green, label: "上升区")
                legendDot(color: .red, label: "下降区")
            }
        }
        .font(.caption2)
        .foregroundColor(.secondary)
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
        }
    }

    // MARK: - 统计卡（大数字圆体）

    private func largeStatCard(_ title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundColor(color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - 信号曲线图（macOS 13+）

import Charts

@available(macOS 13.0, *)
struct SignalChartView: View {
    let samples: [SignalSample]
    let unlockThreshold: Double
    let lockThreshold: Double

    /// X 轴刻度间隔：按数据窗口跨度自适应，避免标签拥挤重叠
    private var xStride: (unit: Calendar.Component, count: Int) {
        guard let first = samples.first?.timestamp, let last = samples.last?.timestamp else { return (.minute, 5) }
        let span = last.timeIntervalSince(first)
        switch span {
        case ..<300:   return (.second, 30)   // < 5 分钟 → 30 秒
        case ..<1800:  return (.minute, 5)    // < 30 分钟 → 5 分钟
        default:       return (.minute, 15)   // ≥ 30 分钟 → 15 分钟
        }
    }

    var body: some View {
        Chart {
            // 阈值参考线（线端标注当前动态值）
            RuleMark(y: .value("解锁阈值", unlockThreshold))
                .foregroundStyle(.green.opacity(0.3))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .annotation(position: .trailing, spacing: 2) {
                    Text("解锁 \(Int(unlockThreshold))")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            RuleMark(y: .value("锁定阈值", lockThreshold))
                .foregroundStyle(.orange.opacity(0.3))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .annotation(position: .trailing, spacing: 2) {
                    Text("锁定 \(Int(lockThreshold))")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

            // Raw RSSI（灰色）
            ForEach(samples) { sample in
                LineMark(
                    x: .value("时间", sample.timestamp),
                    y: .value("Raw RSSI", sample.rawRSSI),
                    series: .value("类型", "Raw")
                )
                .foregroundStyle(.gray.opacity(0.3))
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 1))
            }

            // Kalman 估值（蓝色）
            ForEach(samples) { sample in
                LineMark(
                    x: .value("时间", sample.timestamp),
                    y: .value("Kalman", sample.kalmanEstimate),
                    series: .value("类型", "Kalman")
                )
                .foregroundStyle(.blue)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2))
            }

            // Effective RSSI（紫色虚线）
            ForEach(samples) { sample in
                LineMark(
                    x: .value("时间", sample.timestamp),
                    y: .value("Effective", sample.effectiveRSSI),
                    series: .value("类型", "Effective")
                )
                .foregroundStyle(.purple.opacity(0.6))
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
            }

            // 异常点
            ForEach(samples.filter { $0.isAnomalous }) { sample in
                PointMark(
                    x: .value("时间", sample.timestamp),
                    y: .value("Raw RSSI", sample.rawRSSI)
                )
                .foregroundStyle(.red)
                .symbolSize(30)
            }

            // 事件标记
            ForEach(samples.filter { $0.event != nil }) { sample in
                RuleMark(x: .value("事件", sample.timestamp))
                    .foregroundStyle(sample.event == "unlocked" ? .green : .orange)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .annotation(position: .top, spacing: 4) {
                        Image(systemName: sample.event == "unlocked" ? "lock.open.fill" : "lock.fill")
                            .font(.caption2)
                            .foregroundColor(sample.event == "unlocked" ? .green : .orange)
                    }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: xStride.unit, count: xStride.count)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text("\(Int(v)) dBm")
                            .font(.caption2)
                    }
                }
            }
        }
        .chartYScale(domain: -100 ... -20)
        .frame(height: 200)
    }
}

// MARK: - 斜率变化图（macOS 13+）

@available(macOS 13.0, *)
struct SlopeChartView: View {
    let samples: [SignalSample]

    var body: some View {
        Chart {
            RuleMark(y: .value("零线", 0))
                .foregroundStyle(.secondary.opacity(0.3))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            RuleMark(y: .value("上升阈值", 2.0))
                .foregroundStyle(.green.opacity(0.2))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            RuleMark(y: .value("下降阈值", -2.0))
                .foregroundStyle(.red.opacity(0.2))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

            ForEach(samples) { sample in
                AreaMark(
                    x: .value("时间", sample.timestamp),
                    y: .value("斜率", sample.slope)
                )
                .foregroundStyle(
                    sample.slope > 0
                        ? .green.opacity(0.15)
                        : .red.opacity(0.15)
                )
            }

            ForEach(samples) { sample in
                LineMark(
                    x: .value("时间", sample.timestamp),
                    y: .value("斜率", sample.slope)
                )
                .foregroundStyle(.orange)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .minute, count: 1)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(String(format: "%.1f", v))
                            .font(.caption2)
                    }
                }
            }
        }
        .chartYScale(domain: -10 ... 10)
        .frame(height: 200)
    }
}

// MARK: - 统计口径

/// 统计口径：只计成功事件（解锁=category.unlock 且 outcome.success，锁定同理）
enum StatsCalculator {
    static func todayUnlocks(_ events: [DecisionEvent], now: Date = Date(), calendar: Calendar = .current) -> Int {
        events.filter { $0.category == .unlock && $0.outcome == .success
            && calendar.isDate($0.timestamp, inSameDayAs: now) }.count
    }

    static func todayLocks(_ events: [DecisionEvent], now: Date = Date(), calendar: Calendar = .current) -> Int {
        events.filter { $0.category == .lock && $0.outcome == .success
            && calendar.isDate($0.timestamp, inSameDayAs: now) }.count
    }

    static func thisWeekUnlocks(_ events: [DecisionEvent], now: Date = Date(), calendar: Calendar = .current) -> Int {
        let startOfWeek = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
        return events.filter { $0.category == .unlock && $0.outcome == .success
            && $0.timestamp >= startOfWeek }.count
    }
}