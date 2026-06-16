// MenuDashboardView.swift
// SwiftUI 控制中心 — 毛玻璃风格 + 全中文化 + 设备扫描

import SwiftUI
import Combine

@available(macOS 12.0, *)
struct MenuDashboardView: View {
    @ObservedObject var manager: FUnManager
    @ObservedObject var fun: FUn

    @AppStorage("enabled") private var enabled = true
    @AppStorage("wakeOnProximity") private var wakeOnProximity = false
    @AppStorage("wakeWithoutUnlocking") private var wakeWithoutUnlocking = false
    @AppStorage("pauseItunes") private var pauseItunes = false
    @AppStorage("screensaver") private var useScreensaver = false
    @AppStorage("sleepDisplay") private var sleepDisplay = false
    @AppStorage("passiveMode") private var passiveMode = false
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @State private var showCalibration = false
    @State private var sliderLock: Double = 0
    @State private var sliderUnlock: Double = 0
    @State private var showApplied = false
    @State private var isScanning = false
    @State private var frozenDevices: [Device] = []

    var body: some View {
        VStack(spacing: 0) {
            // 1. 顶部：设备区域
            deviceSection
            Divider().padding(.horizontal, 12)

            // 2. 信号仪表（仅在已绑定时显示）
            if manager.monitoredDeviceName != nil {
                signalSection
                Divider().padding(.horizontal, 12)
            }

            // 3. 开关区域
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    toggleSection
                    otherSection
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }

            Divider().padding(.horizontal, 12)

            // 4. 底部按钮
            footerSection
        }
        .frame(width: 320, height: manager.monitoredDeviceName != nil ? 520 : 400)
        .background(.regularMaterial)
        .onAppear {
            sliderLock = Double(manager.lockRSSI)
            sliderUnlock = Double(manager.unlockRSSI == 1 ? -95 : manager.unlockRSSI)
        }
        .sheet(isPresented: $showCalibration) {
            CalibrationWizardView(manager: manager, isPresented: $showCalibration)
        }
    }

    // MARK: - 设备区域

    private var deviceSection: some View {
        VStack(spacing: 0) {
            if let deviceName = manager.monitoredDeviceName {
                // 已绑定设备
                HStack(spacing: 12) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 12, height: 12)
                        .shadow(color: statusColor.opacity(0.6), radius: 4)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(deviceName)
                            .font(.headline)
                            .lineLimit(1)
                        Text(statusText)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button(action: { manager.unbindDevice() }) {
                        Text("解绑")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                .padding(14)
                .background(statusColor.opacity(0.06))

            } else {
                // 未绑定 — 搜索按钮 + 设备列表
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundColor(.accentColor)
                        Text("选择要绑定的设备")
                            .font(.headline)
                        Spacer()
                        if isScanning {
                            ProgressView().controlSize(.mini)
                        } else {
                            Button(action: {
                                isScanning = true
                                frozenDevices = []
                                manager.startScanning()
                                // 3秒后冻结列表
                                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                                    frozenDevices = manager.discoveredDevices.sorted(by: { $0.rssi > $1.rssi })
                                    isScanning = false
                                    manager.stopScanning()
                                }
                            }) {
                                Text("开始搜索")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }

                    if frozenDevices.isEmpty && !isScanning {
                        HStack {
                            Spacer()
                            VStack(spacing: 6) {
                                Image(systemName: "magnifyingglass")
                                    .font(.title2)
                                    .foregroundColor(.secondary)
                                Text("点击「开始搜索」扫描附近设备")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 20)
                            Spacer()
                        }
                    } else {
                        ScrollView(.vertical, showsIndicators: true) {
                            VStack(spacing: 4) {
                                ForEach(isScanning ? manager.discoveredDevices.sorted(by: { $0.rssi > $1.rssi }) : frozenDevices, id: \.uuid) { device in
                                    DeviceRow(device: device) {
                                        manager.selectDevice(device)
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 160)
                    }
                }
                .padding(14)
                .background(Color.accentColor.opacity(0.04))
            }
        }
        .onAppear { manager.startScanning() }
        .onDisappear { manager.stopScanning() }
    }

    // MARK: - 设备行

    private struct DeviceRow: View {
        let device: Device
        let onSelect: () -> Void

        var body: some View {
            Button(action: onSelect) {
                HStack {
                    Image(systemName: "iphone")
                        .foregroundColor(.accentColor)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.description)
                            .font(.callout)
                            .lineLimit(1)
                        if let mac = device.macAddr {
                            Text(mac.replacingOccurrences(of: "-", with: ":").uppercased())
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    Text("\(device.rssi) dBm")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(rssiColor(device.rssi))
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
            .cornerRadius(6)
        }

        private func rssiColor(_ rssi: Int) -> Color {
            if rssi >= -50 { return .green }
            if rssi >= -70 { return .yellow }
            return .red
        }
    }

    // MARK: - 信号仪表

    private var signalSection: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.15), lineWidth: 10)
                    .frame(width: 90, height: 90)
                Circle()
                    .trim(from: 0, to: signalStrength)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [signalColor.opacity(0.4), signalColor]),
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .frame(width: 90, height: 90)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.5), value: signalStrength)

                VStack(spacing: 1) {
                    Text(manager.rssi.map { "\($0)" } ?? "—")
                        .font(.system(size: 26, weight: .bold, design: .monospaced))
                    Text("dBm")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 8)

            // 校准按钮
            Button(action: { showCalibration = true }) {
                HStack {
                    Image(systemName: "wand.and.stars")
                    Text("自动校准向导")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color.accentColor.opacity(0.08))
            .cornerRadius(8)

            // 阈值调节
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .frame(width: 16)
                    Text("锁定")
                        .font(.caption)
                        .frame(width: 30, alignment: .leading)
                    Slider(value: $sliderLock, in: Double(-95)...Double(-30))
                    Text("\(Int(sliderLock))")
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 35, alignment: .trailing)
                    Text("dBm")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 8) {
                    Image(systemName: "lock.open.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                        .frame(width: 16)
                    Text("解锁")
                        .font(.caption)
                        .frame(width: 30, alignment: .leading)
                    Slider(value: $sliderUnlock, in: Double(-95)...Double(-30))
                    Text("\(Int(sliderUnlock))")
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 35, alignment: .trailing)
                    Text("dBm")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }

            Button(action: {
                manager.setLockRSSI(Int(sliderLock))
                manager.setUnlockRSSI(Int(sliderUnlock))
                showApplied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showApplied = false }
            }) {
                HStack {
                    Image(systemName: showApplied ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                        .foregroundColor(showApplied ? .green : .accentColor)
                    Text(showApplied ? "已应用" : "应用阈值")
                        .font(.callout)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(showApplied ? 0.15 : 0.1))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)

            .onReceive(manager.$lockRSSI) { newValue in
                if Int(sliderLock) != newValue {
                    sliderLock = Double(newValue)
                }
            }
            .onReceive(manager.$unlockRSSI) { newValue in
                let expected = (newValue == 1 ? -95 : newValue)
                if Int(sliderUnlock) != expected {
                    sliderUnlock = Double(expected)
                }
            }
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(10)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - 开关

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
                .onChange(of: passiveMode) { v in fun.setPassiveMode(v) }
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
                    Image(systemName: "info.circle").frame(width: 20)
                    Text("关于 BLEUnlock").font(.callout)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(10)
    }

    // MARK: - 底部

    private var footerSection: some View {
        HStack(spacing: 12) {
            Button(action: { manager.lockNow() }) {
                HStack { Image(systemName: "lock.fill"); Text("立即锁定") }
                    .font(.callout).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).tint(.orange)

            Button(action: { NSApplication.shared.terminate(nil) }) {
                HStack { Image(systemName: "power"); Text("退出") }
                    .font(.callout).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).tint(.red)
        }
        .padding(14)
    }

    // MARK: - 组件

    private func toggleRow(_ title: String, isOn: Binding<Bool>, icon: String) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(.accentColor)
                    .frame(width: 20)
                Text(title).font(.callout)
            }
        }
        .toggleStyle(.switch).controlSize(.small)
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var divider: some View {
        Divider().padding(.leading, 44)
    }

    // MARK: - 状态

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

    private var signalStrength: CGFloat {
        guard let rssi = manager.rssi else { return 0 }
        return min(max(CGFloat(rssi + 100) / 70.0, 0), 1)
    }

    private var signalColor: Color {
        if signalStrength > 0.7 { return .green }
        if signalStrength > 0.4 { return .yellow }
        return .red
    }
}
