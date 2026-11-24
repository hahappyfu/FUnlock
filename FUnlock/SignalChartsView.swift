// SignalChartsView.swift
// 信号 / 斜率曲线与统计口径（原 StatsView.swift 的数据部分，供诊断 Tab 使用）
// 性能红线：图表降采样到 120 点，异常点与事件标记保持全量

import SwiftUI
import Charts

// MARK: - 图表模式

enum ChartMode: String, CaseIterable {
    case signal = "stats_chart_signal"
    case slope  = "stats_chart_slope"
}

/// 等距降采样：样本数超过 maxPoints 时按等距索引取样
fileprivate func downsampleForChart(_ samples: [SignalSample], maxPoints: Int = 120) -> [SignalSample] {
    guard samples.count > maxPoints else { return samples }
    let step = Double(samples.count) / Double(maxPoints)
    return (0..<maxPoints).map { samples[min(samples.count - 1, Int(Double($0) * step))] }
}

// MARK: - 信号曲线图

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
        case ..<300:   return (.second, 30)
        case ..<1800:  return (.minute, 5)
        default:       return (.minute, 15)
        }
    }

    var body: some View {
        Chart {
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

            let plotted = downsampleForChart(samples)

            ForEach(plotted) { sample in
                LineMark(
                    x: .value("时间", sample.timestamp),
                    y: .value("Raw RSSI", sample.rawRSSI),
                    series: .value("类型", "Raw")
                )
                .foregroundStyle(.gray.opacity(0.3))
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 1))
            }

            ForEach(plotted) { sample in
                LineMark(
                    x: .value("时间", sample.timestamp),
                    y: .value("Kalman", sample.kalmanEstimate),
                    series: .value("类型", "Kalman")
                )
                .foregroundStyle(.blue)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2))
            }

            ForEach(plotted) { sample in
                LineMark(
                    x: .value("时间", sample.timestamp),
                    y: .value("Effective", sample.effectiveRSSI),
                    series: .value("类型", "Effective")
                )
                .foregroundStyle(.purple.opacity(0.6))
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
            }

            ForEach(samples.filter { $0.isAnomalous }) { sample in
                PointMark(
                    x: .value("时间", sample.timestamp),
                    y: .value("Raw RSSI", sample.rawRSSI)
                )
                .foregroundStyle(.red)
                .symbolSize(30)
            }

            ForEach(samples.filter { $0.event != nil }) { sample in
                RuleMark(x: .value("事件", sample.timestamp))
                    .foregroundStyle(sample.isUnlockEvent ? .green : .orange)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .annotation(position: .top, spacing: 4) {
                        Image(systemName: sample.isUnlockEvent ? "lock.open.fill" : "lock.fill")
                            .font(.caption2)
                            .foregroundColor(sample.isUnlockEvent ? .green : .orange)
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

// MARK: - 斜率变化图

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

            let plotted = downsampleForChart(samples)

            ForEach(plotted) { sample in
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

            ForEach(plotted) { sample in
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
