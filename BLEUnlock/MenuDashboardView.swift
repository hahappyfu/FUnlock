// MenuDashboardView.swift
// SwiftUI 控制中心 — 毛玻璃风格 + 全中文化

import SwiftUI
import Combine

@available(macOS 12.0, *)
struct MenuDashboardView: View {
    @ObservedObject var manager: BluetoothManager
    let ble: BLE

    @AppStorage("enabled") private var enabled = true
    @AppStorage("wakeOnProximity") private var wakeOnProximity = false
    @AppStorage("wakeWithoutUnlocking") private var wakeWithoutUnlocking = false
    @AppStorage("pauseItunes") private var pauseItunes = false
    @AppStorage("screensaver") private var useScreensaver = false
    @AppStorage("sleepDisplay") private var sleepDisplay = false
    @AppStorage("passiveMode") private var passiveMode = false
    @AppStorage("launchAtLogin") private var launchAtLogin = false

    var body: some View {
        VStack(spacing: 0) {
            // 1. 顶部：设备状态卡片
            headerSection
            Divider().padding(.horizontal, 12)

            // 2. 中部：信号仪表
            signalSection
            Divider().padding(.horizontal, 12)

            // 3. 下部：快捷开关卡片
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    toggleSection
                    otherSection
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }

            Divider().padding(.horizontal, 12)

            // 4. 底部：操作按钮
            footerSection
        }
        .frame(width: 320, height: 480)
        .background(.regularMaterial)
    }

    // MARK: - Header 设备状态卡片

    private var headerSection: some View {
        HStack(spacing: 12) {
            // 状态指示灯
            Circle()
                .fill(statusColor)
                .frame(width: 12, height: 12)
                .shadow(color: statusColor.opacity(0.6), radius: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusText)
                    .font(.headline)
                    .foregroundColor(.primary)
                Text(manager.rssi.map { "\($0) dBm" } ?? "未检测到信号")
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if manager.connected {
                Text("已连接")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.12))
                    .cornerRadius(6)
            }
        }
        .padding(14)
        .background(statusColor.opacity(0.06))
    }

    // MARK: - Signal 信号仪表卡片

    private var signalSection: some View {
        VStack(spacing: 12) {
            // 圆形仪表
            ZStack {
                // 背景环
                Circle()
                    .stroke(Color.gray.opacity(0.15), lineWidth: 10)
                    .frame(width: 90, height: 90)

                // 信号强度环
                Circle()
                    .trim(from: 0, to: signalStrength)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [signalColor.opacity(0.4), signalColor]),
                            center: .center,
                            startAngle: .degrees(0),
                            endAngle: .degrees(360 * signalStrength)
                        ),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .frame(width: 90, height: 90)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.5), value: signalStrength)

                // 中心数值
                VStack(spacing: 1) {
                    Text(manager.rssi.map { "\($0)" } ?? "—")
                        .font(.system(size: 26, weight: .bold, design: .monospaced))
                        .foregroundColor(.primary)
                    Text("dBm")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 8)

            // 锁定/解锁阈值
            HStack(spacing: 0) {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("锁定阈值")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text("\(ble.lockRSSI) dBm")
                            .font(.system(.caption, design: .monospaced))
                            .fontWeight(.medium)
                    }
                } icon: {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                Spacer()
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("解锁阈值")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text(ble.unlockRSSI == 1 ? "已禁用" : "\(ble.unlockRSSI) dBm")
                            .font(.system(.caption, design: .monospaced))
                            .fontWeight(.medium)
                    }
                } icon: {
                    Image(systemName: "lock.open.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(10)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Toggles 快捷开关卡片

    private var toggleSection: some View {
        VStack(spacing: 0) {
            toggleRow("启用", isOn: $enabled, icon: "power")
            divider
            toggleRow("靠近时唤醒", isOn: $wakeOnProximity, icon: "display")
            divider
            toggleRow("唤醒但不解锁", isOn: $wakeWithoutUnlocking, icon: "lock.open")
            divider
            toggleRow("锁定时暂停播放", isOn: $pauseItunes, icon: "pause.circle")
            divider
            toggleRow("使用屏幕保护程序", isOn: $useScreensaver, icon: "sparkles.tv")
            divider
            toggleRow("锁定时关闭屏幕", isOn: $sleepDisplay, icon: "display.sleep")
            divider
            toggleRow("被动模式", isOn: $passiveMode, icon: "antenna.radiowaves.left.and.right")
                .onChange(of: passiveMode) { newValue in
                    ble.setPassiveMode(newValue)
                }
            divider
            toggleRow("开机自启动", isOn: $launchAtLogin, icon: "arrow.up.circle")
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(10)
    }

    private var otherSection: some View {
        VStack(spacing: 0) {
            Button(action: { NSApp.orderFrontStandardAboutPanel(nil) }) {
                HStack {
                    Image(systemName: "info.circle")
                        .frame(width: 20)
                    Text("关于 BLEUnlock")
                        .font(.callout)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(10)
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack(spacing: 12) {
            Button(action: { manager.lockNow() }) {
                HStack {
                    Image(systemName: "lock.fill")
                    Text("立即锁定")
                }
                .font(.callout)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.orange)

            Button(action: { NSApplication.shared.terminate(nil) }) {
                HStack {
                    Image(systemName: "power")
                    Text("退出")
                }
                .font(.callout)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
        .padding(14)
    }

    // MARK: - Components

    private func toggleRow(_ title: String, isOn: Binding<Bool>, icon: String) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(.accentColor)
                    .frame(width: 20)
                Text(title)
                    .font(.callout)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var divider: some View {
        Divider()
            .padding(.leading, 44)
    }

    // MARK: - Status

    private var statusColor: Color {
        switch manager.state.screen {
        case .unlocked: return .green
        case .locked: return .orange
        case .screensaver: return .yellow
        case .displaySleeping: return .gray
        }
    }

    private var statusText: String {
        switch manager.state.screen {
        case .unlocked: return "设备已解锁"
        case .locked(let reason):
            switch reason {
            case .away: return "已锁定 — 设备远离"
            case .lost: return "已锁定 — 信号丢失"
            case .manual: return "已锁定 — 手动锁定"
            case .timeout: return "已锁定 — 信号超时"
            }
        case .screensaver: return "屏幕保护中"
        case .displaySleeping: return "显示器休眠"
        }
    }

    // MARK: - Signal helpers

    private var signalStrength: CGFloat {
        guard let rssi = manager.rssi else { return 0 }
        let normalized = CGFloat(rssi + 100) / 70.0
        return min(max(normalized, 0), 1)
    }

    private var signalColor: Color {
        let s = signalStrength
        if s > 0.7 { return .green }
        if s > 0.4 { return .yellow }
        return .red
    }
}
