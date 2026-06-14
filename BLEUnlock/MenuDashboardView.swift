// MenuDashboardView.swift
// SwiftUI 控制中心 — 替代旧 NSMenu

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
            // 1. 顶部：设备名与状态
            headerSection
            Divider()

            // 2. 中部：信号雷达
            signalSection
            Divider()

            // 3. 下部：快捷开关
            ScrollView {
                VStack(spacing: 8) {
                    toggleRow("Enabled", $enabled)
                    toggleRow("Wake on Proximity", $wakeOnProximity)
                    toggleRow("Wake without Unlocking", $wakeWithoutUnlocking)
                    toggleRow("Pause Now Playing", $pauseItunes)
                    toggleRow("Use Screensaver", $useScreensaver)
                    toggleRow("Turn Off Screen", $sleepDisplay)
                    toggleRow("Passive Mode", $passiveMode)
                        .onChange(of: passiveMode) { newValue in
                            ble.setPassiveMode(newValue)
                        }
                    toggleRow("Launch at Login", $launchAtLogin)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            Divider()

            // 4. 底部：操作按钮
            footerSection
        }
        .frame(width: 320, height: 450)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 6) {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(statusText)
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
            }
            HStack {
                Text(manager.rssi.map { "\($0) dBm" } ?? "No signal")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                if manager.connected {
                    Text("Active")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
        }
        .padding(16)
        .background(statusColor.opacity(0.08))
    }

    // MARK: - Signal

    private var signalSection: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 8)
                    .frame(width: 80, height: 80)
                Circle()
                    .trim(from: 0, to: signalStrength)
                    .stroke(signalColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .frame(width: 80, height: 80)
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    Text(manager.rssi.map { "\($0)" } ?? "—")
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                    Text("dBm")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 12)

            HStack {
                Label("Lock: \(ble.lockRSSI) dBm", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Label("Unlock: \(ble.unlockRSSI == 1 ? "Off" : "\(ble.unlockRSSI) dBm")", systemImage: "lock.open.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button("Lock Now") {
                manager.lockNow()
            }
            .buttonStyle(.bordered)
            Spacer()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.bordered)
            .foregroundColor(.red)
        }
        .padding(16)
    }

    // MARK: - Helpers

    private func toggleRow(_ title: String, _ binding: Binding<Bool>) -> some View {
        Toggle(title, isOn: binding)
            .toggleStyle(.switch)
            .controlSize(.small)
    }

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
        case .unlocked: return "Unlocked"
        case .locked(let reason):
            switch reason {
            case .away: return "Locked — Device Away"
            case .lost: return "Locked — Signal Lost"
            case .manual: return "Locked — Manual"
            case .timeout: return "Locked — Timeout"
            }
        case .screensaver: return "Screensaver"
        case .displaySleeping: return "Display Sleeping"
        }
    }

    private var signalStrength: CGFloat {
        guard let rssi = manager.rssi else { return 0 }
        // Map -100..-30 to 0..1
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
