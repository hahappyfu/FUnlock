// StatsView.swift
// 信号诊断仪表盘 — P1 可观测性升级

import SwiftUI
import Combine

// MARK: - 事件日志（保留原有逻辑）

struct LogEntry {
    let timestamp: Date
    let event: String  // "unlocked" / "locked: away" / "locked: lost"
}

func loadRecentEvents(maxCount: Int = 200) -> [LogEntry] {
    guard let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return [] }
    let logURL = supportDir.appendingPathComponent("FUnlock/events.log")
    guard let data = try? Data(contentsOf: logURL),
          let content = String(data: data, encoding: .utf8) else { return [] }

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

    var entries: [LogEntry] = []
    for line in content.components(separatedBy: .newlines).suffix(maxCount) {
        let parts = line.components(separatedBy: " | ")
        guard parts.count >= 2,
              let date = formatter.date(from: parts[0]) else { continue }
        entries.append(LogEntry(timestamp: date, event: parts[1]))
    }
    return entries
}

// MARK: - 图表模式

enum ChartMode: String, CaseIterable {
    case signal = "信号曲线"
    case slope  = "斜率变化"
}

// MARK: - 统计面板

struct StatsView: View {
    @Binding var isPresented: Bool
    @ObservedObject private var dataStore = SignalDataStore.shared

    private let events = loadRecentEvents()
    @State private var chartMode: ChartMode = .signal

    private var calendar: Calendar { Calendar.current }
    private var today: Date { calendar.startOfDay(for: Date()) }

    private var todayUnlocks: Int {
        events.filter { $0.event == "unlocked" && calendar.isDate($0.timestamp, inSameDayAs: today) }.count
    }
    private var todayLocks: Int {
        events.filter { $0.event != "unlocked" && calendar.isDate($0.timestamp, inSameDayAs: today) }.count
    }
    private var thisWeekUnlocks: Int {
        let startOfWeek = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date()))!
        return events.filter { $0.event == "unlocked" && $0.timestamp >= startOfWeek }.count
    }

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

            if dataStore.samples.isEmpty && events.isEmpty {
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
                        HStack(spacing: 12) {
                            statCard(t("stats_today_unlocks"), value: "\(todayUnlocks)", icon: "lock.open.fill", color: .green)
                            statCard(t("stats_today_locks"), value: "\(todayLocks)", icon: "lock.fill", color: .orange)
                            statCard(t("stats_week_unlocks"), value: "\(thisWeekUnlocks)", icon: "calendar", color: .accentColor)
                        }
                        .frame(maxWidth: .infinity)
                    }

                    // 信号图表区域（macOS 13+）
                    if !dataStore.samples.isEmpty {
                        if #available(macOS 13.0, *) {
                            Section {
                                HStack {
                                    Text("信号诊断")
                                        .font(.subheadline.bold())
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Picker("", selection: $chartMode) {
                                        ForEach(ChartMode.allCases, id: \.self) { mode in
                                            Text(mode.rawValue).tag(mode)
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

                    // 最近事件
                    Section(t("stats_recent_events")) {
                        ForEach(events.suffix(8).reversed().indices, id: \.self) { i in
                            let entry = events.suffix(8).reversed()[i]
                            HStack {
                                Image(systemName: entry.event == "unlocked" ? "lock.open.fill" : "lock.fill")
                                    .foregroundColor(entry.event == "unlocked" ? .green : .orange)
                                    .frame(width: 16)
                                Text(t("stats_event_\(entry.event == "unlocked" ? "unlocked" : "locked")"))
                                    .font(.callout)
                                Spacer()
                                Text(entry.timestamp, format: .dateTime.month().day().hour().minute().second())
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .frame(width: 440, height: 560)
    }

    // MARK: - macOS 12 fallback（无 Charts 时显示文本摘要）

    private var fallbackSignalList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("信号诊断")
                .font(.subheadline.bold())
                .foregroundColor(.secondary)
            let recent = dataStore.samples.suffix(10)
            ForEach(Array(recent.enumerated()), id: \.element.id) { _, sample in
                HStack {
                    Text(sample.timestamp, format: .dateTime.hour().minute().second())
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 65, alignment: .leading)
                    Text("Raw: \(Int(sample.rawRSSI))")
                        .font(.caption)
                        .frame(width: 60, alignment: .leading)
                    Text("Kalman: \(Int(sample.kalmanEstimate))")
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

    // MARK: - 统计卡

    private func statCard(_ title: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.title3.bold())
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}

// MARK: - 信号曲线图（macOS 13+）

import Charts

@available(macOS 13.0, *)
struct SignalChartView: View {
    let samples: [SignalSample]
    let unlockThreshold: Double
    let lockThreshold: Double

    var body: some View {
        Chart {
            // 阈值参考线
            RuleMark(y: .value("解锁阈值", unlockThreshold))
                .foregroundStyle(.green.opacity(0.3))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            RuleMark(y: .value("锁定阈值", lockThreshold))
                .foregroundStyle(.orange.opacity(0.3))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

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