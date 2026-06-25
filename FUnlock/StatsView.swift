// StatsView.swift
// 解锁统计面板

import SwiftUI
import Combine

// MARK: - 事件日志

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

// MARK: - 统计面板

struct StatsView: View {
    @Binding var isPresented: Bool

    private let events = loadRecentEvents()

    private var calendar: Calendar { Calendar.current }

    private var today: Date {
        calendar.startOfDay(for: Date())
    }

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

    private struct DayCount: Identifiable {
        let id = UUID()
        let label: String
        let date: Date
        let unlocks: Int
    }

    private var dailyUnlocks: [DayCount] {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd"
        return (0..<7).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let count = events.filter { $0.event == "unlocked" && calendar.isDate($0.timestamp, inSameDayAs: date) }.count
            return DayCount(label: formatter.string(from: date), date: date, unlocks: count)
        }.reversed()
    }

    private var recentEntries: [LogEntry] {
        Array(events.suffix(5).reversed())
    }

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private let fullFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm"
        return f
    }()

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

            if events.isEmpty {
                // 无数据
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
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 16) {
                        // 概览
                        HStack(spacing: 12) {
                            statCard(t("stats_today_unlocks"), value: "\(todayUnlocks)", icon: "lock.open.fill", color: .green)
                            statCard(t("stats_today_locks"), value: "\(todayLocks)", icon: "lock.fill", color: .orange)
                            statCard(t("stats_week_unlocks"), value: "\(thisWeekUnlocks)", icon: "calendar", color: .accentColor)
                        }

                        Divider()

                        // 近7天趋势
                        VStack(alignment: .leading, spacing: 6) {
                            Text(t("stats_7day_trend"))
                                .font(.subheadline.bold())
                                .foregroundColor(.secondary)
                            ForEach(dailyUnlocks) { day in
                                HStack {
                                    Text(day.label)
                                        .font(.system(.caption, design: .monospaced))
                                        .frame(width: 40, alignment: .leading)
                                    // 简易条形
                                    if day.unlocks > 0 {
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(Color.green.opacity(0.6))
                                            .frame(width: CGFloat(min(day.unlocks, 30)) * 3, height: 8)
                                    }
                                    Text("\(day.unlocks)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .frame(width: 20, alignment: .trailing)
                                    Spacer()
                                }
                            }
                        }

                        Divider()

                        // 最近事件
                        VStack(alignment: .leading, spacing: 6) {
                            Text(t("stats_recent_events"))
                                .font(.subheadline.bold())
                                .foregroundColor(.secondary)
                            ForEach(recentEntries.indices, id: \.self) { i in
                                let entry = recentEntries[i]
                                HStack {
                                    Image(systemName: entry.event == "unlocked" ? "lock.open.fill" : "lock.fill")
                                        .foregroundColor(entry.event == "unlocked" ? .green : .orange)
                                        .frame(width: 16)
                                    Text(t("stats_event_\(entry.event == "unlocked" ? "unlocked" : "locked")"))
                                        .font(.callout)
                                    Spacer()
                                    Text(fullFormatter.string(from: entry.timestamp))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 340, height: 420)
        .background(.regularMaterial)
    }

    private func statCard(_ title: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(color)
            Text(value)
                .font(.title2.bold())
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.08))
        .cornerRadius(8)
    }
}
