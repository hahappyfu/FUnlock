// MenuDashboardView.swift
// SwiftUI 控制中心 — 毛玻璃风格 + 全中文化 + 设备扫描

import SwiftUI
import Combine
import ServiceManagement

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

struct MenuDashboardView: View {
    @ObservedObject var manager: FUnManager
    @ObservedObject var fun: FUn

    @AppStorage("enabled") private var enabled = true
    @AppStorage("wakeOnProximity") private var wakeOnProximity = false
    @AppStorage("wakeWithoutUnlocking") private var wakeWithoutUnlocking = false
    @AppStorage("pauseItunes") private var pauseItunes = false
    @AppStorage("screensaver") private var useScreensaver = false
    @AppStorage("sleepDisplay") private var sleepDisplay = false
    @AppStorage("lockOnIdle") private var lockOnIdle = true
    @AppStorage("manualLockNoAutoUnlock") private var manualLockNoAutoUnlock = false
    @AppStorage("passiveMode") private var passiveMode = false
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("pauseOnWiFi") private var pauseOnWiFi = false
    @AppStorage("pauseOnWiFiSSID") private var pauseOnWiFiSSID = ""
    @StateObject private var profileManager = ProfileManager.shared
    @State private var showCalibration = false
    @State private var showOnboarding = false
    @State private var showAutomation = false
    @State private var showAbout = false
    @State private var showStats = false
    @State private var showAddProfile = false
    @State private var newProfileName = ""
    @State private var onboardingStep = 0
    @State private var sliderLock: Double = 0
    @State private var sliderUnlock: Double = 0
    @State private var isSliderDragging: Bool = false
    @State private var isScanning = false
    @State private var frozenDevices: [Device] = []
    @State private var toastMessage: String? = nil
    @State private var toastIcon: String = ""
    @State private var toastColor: Color = .green
    @State private var previousConnected: Bool? = nil

    var isThresholdApplied: Bool {
        Int(sliderLock) == manager.lockRSSI && Int(sliderUnlock) == (manager.unlockRSSI == 1 ? -95 : manager.unlockRSSI)
    }

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

            // 2.5 配置文件选择器
            if manager.monitoredDeviceName != nil {
                profileSelector
                Divider().padding(.horizontal, 12)
            }

            // 3. 开关区域
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 10) {
                    toggleSection
                    wifiSection
                    otherSection
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }

            Divider().padding(.horizontal, 12)

            // 4. 底部按钮
            footerSection
        }
        .frame(width: 320, height: manager.monitoredDeviceName != nil ? 600 : 440)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            if let msg = toastMessage {
                ToastView(message: msg, icon: toastIcon, color: toastColor)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 8)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: toastMessage)
        .onAppear {
            sliderLock = Double(manager.lockRSSI)
            sliderUnlock = Double(manager.unlockRSSI == 1 ? -95 : manager.unlockRSSI)
            previousConnected = manager.connected
            if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
                showOnboarding = true
            }
        }
        .onReceive(manager.$connected) { connected in
            guard let prev = previousConnected, prev != connected else {
                previousConnected = connected
                return
            }
            previousConnected = connected
            if connected {
                showToast(t("toast_bt_connected"), icon: "antenna.radiowaves.left.and.right", color: .green)
            } else {
                showToast(t("toast_bt_disconnected"), icon: "wifi.slash", color: .orange)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuShowStats)) { _ in
            showStats = true
        }
        .sheet(isPresented: $showCalibration) {
            CalibrationWizardView(manager: manager, isPresented: $showCalibration)
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(step: $onboardingStep, isPresented: $showOnboarding)
        }
        .sheet(isPresented: $showAutomation) {
            AutomationView(isPresented: $showAutomation)
        }
        .sheet(isPresented: $showAbout) {
            AboutView()
        }
        .sheet(isPresented: $showStats) {
            StatsView(isPresented: $showStats)
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
                        Text(t("unbind"))
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
                        Text(t("select_device"))
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
                                Text(t("start_search"))
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
                                Text(t("scan_hint"))
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

    // MARK: - 配置文件选择器

    private var profileSelector: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.badge.gearshape")
                .foregroundColor(.accentColor)
                .frame(width: 16)

            Text(t("profile"))
                .font(.callout)

            Spacer()

            Picker("", selection: $profileManager.activeProfileID) {
                ForEach(profileManager.profiles) { profile in
                    Text(profile.name).tag(profile.id)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 100)
            .onChange(of: profileManager.activeProfileID) { id in
                profileManager.setActive(id)
                profileManager.applyActiveProfile(to: manager)
                // 同步滑块
                sliderLock = Double(manager.lockRSSI)
                sliderUnlock = Double(manager.unlockRSSI == 1 ? -95 : manager.unlockRSSI)
            }

            Button(action: {
                newProfileName = ""
                showAddProfile = true
            }) {
                Image(systemName: "plus.circle")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .alert(t("profile_add"), isPresented: $showAddProfile) {
            TextField(t("profile_name_placeholder"), text: $newProfileName)
            Button(t("ok")) {
                guard !newProfileName.isEmpty else { return }
                profileManager.saveCurrentAsProfile(
                    name: newProfileName,
                    lockRSSI: manager.lockRSSI,
                    unlockRSSI: manager.unlockRSSI
                )
            }
            Button(t("cancel"), role: .cancel) {}
        } message: {
            Text(t("profile_add_hint"))
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

            // 场景状态文字
            HStack(spacing: 4) {
                Circle()
                    .fill(scenarioColor)
                    .frame(width: 6, height: 6)
                Text(scenarioText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // 校准按钮
            Button(action: { showCalibration = true }) {
                HStack {
                    Image(systemName: "wand.and.stars")
                    Text(t("calibration_wizard"))
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
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .frame(width: 16)
                    Text(t("lock"))
                        .font(.caption)
                        .frame(width: 30, alignment: .leading)
                    Button(action: { sliderLock = max(-95, sliderLock - 1) }) {
                        Image(systemName: "minus.circle").font(.caption)
                    }.buttonStyle(.plain)
                    Slider(value: $sliderLock, in: Double(-95)...Double(-30))
                    Button(action: { sliderLock = min(-30, sliderLock + 1) }) {
                        Image(systemName: "plus.circle").font(.caption)
                    }.buttonStyle(.plain)
                    Text("\(Int(sliderLock))")
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 35, alignment: .trailing)
                    Text("dBm")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 6) {
                    Image(systemName: "lock.open.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                        .frame(width: 16)
                    Text(t("unlock"))
                        .font(.caption)
                        .frame(width: 30, alignment: .leading)
                    Button(action: { sliderUnlock = max(-95, sliderUnlock - 1) }) {
                        Image(systemName: "minus.circle").font(.caption)
                    }.buttonStyle(.plain)
                    Slider(value: $sliderUnlock, in: Double(-95)...Double(-30))
                    Button(action: { sliderUnlock = min(-30, sliderUnlock + 1) }) {
                        Image(systemName: "plus.circle").font(.caption)
                    }.buttonStyle(.plain)
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
            }) {
                HStack {
                    Image(systemName: isThresholdApplied ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                        .foregroundColor(isThresholdApplied ? .green : .accentColor)
                    Text(isThresholdApplied ? t("applied") : t("apply_thresholds"))
                        .font(.callout)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(isThresholdApplied ? 0.15 : 0.1))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)

            .onReceive(manager.$lockRSSI) { newValue in
                if Int(sliderLock) != newValue && !isSliderDragging {
                    sliderLock = Double(newValue)
                }
            }
            .onReceive(manager.$unlockRSSI) { newValue in
                let expected = (newValue == 1 ? -95 : newValue)
                if Int(sliderUnlock) != expected && !isSliderDragging {
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
            toggleRow(t("enable"), isOn: $enabled, icon: "power")
            divider
            toggleRow(t("wake_on_proximity"), isOn: $wakeOnProximity, icon: "display")
            divider
            toggleRow(t("wake_without_unlock"), isOn: $wakeWithoutUnlocking, icon: "lock.open")
            divider
            toggleRow(t("pause_on_lock"), isOn: $pauseItunes, icon: "pause.circle")
            divider
            toggleRow(t("use_screensaver"), isOn: $useScreensaver, icon: "sparkles.tv")
            divider
            toggleRow(t("sleep_display_on_lock"), isOn: $sleepDisplay, icon: "moon.fill")
            divider
            toggleRow(t("defer_lock_on_input"), isOn: $lockOnIdle, icon: "keyboard")
            divider
            toggleRow(t("manual_lock_no_auto_unlock"), isOn: $manualLockNoAutoUnlock, icon: "hand.raised.fill")
            divider
            toggleRow(t("passive_mode"), isOn: $passiveMode, icon: "antenna.radiowaves.left.and.right")
                .onChange(of: passiveMode) { v in fun.setPassiveMode(v) }
            divider
            toggleRow(t("launch_at_login"), isOn: $launchAtLogin, icon: "arrow.up.circle")
                .onChange(of: launchAtLogin) { v in
                    if #available(macOS 13.0, *) {
                        do {
                            if v { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch { print("SMAppService error: \(error)") }
                    }
                }
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(10)
    }

    // MARK: - Wi-Fi 设置

    private var wifiSection: some View {
        VStack(spacing: 0) {
            toggleRow(t("pause_on_wifi"), isOn: $pauseOnWiFi, icon: "wifi")
            if pauseOnWiFi {
                divider
                HStack(spacing: 8) {
                    Text(t("wifi_ssid"))
                        .font(.callout)
                    TextField(t("wifi_ssid_placeholder"), text: $pauseOnWiFiSSID)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout)
                    Button(t("current_wifi")) {
                        pauseOnWiFiSSID = WiFiMonitor.shared.currentSSID ?? ""
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(10)
    }

    private var otherSection: some View {
        VStack(spacing: 0) {
            Button(action: { showAutomation = true }) {
                HStack {
                    Image(systemName: "bolt.automation").frame(width: 20)
                    Text(t("automation")).font(.callout)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            divider

            Button(action: { showStats = true }) {
                HStack {
                    Image(systemName: "chart.bar").frame(width: 20)
                    Text(t("unlock_stats")).font(.callout)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            divider

            Button(action: { showAbout = true }) {
                HStack {
                    Image(systemName: "info.circle").frame(width: 20)
                    Text(t("about_funlock")).font(.callout)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            divider

            Button(action: { exportDiagnostics() }) {
                HStack {
                    Image(systemName: "square.and.arrow.up").frame(width: 20)
                    Text(t("export_diagnostics")).font(.callout)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(10)
    }

    // MARK: - 导出诊断信息

    private func exportDiagnostics() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("FUnlock_Diagnostics")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // 清理旧目录内容
        if let contents = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) {
            for item in contents { try? FileManager.default.removeItem(at: item) }
        }

        // 1. 复制 events.log
        if let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let logSrc = supportDir.appendingPathComponent("FUnlock/events.log")
            try? FileManager.default.copyItem(at: logSrc, to: tempDir.appendingPathComponent("events.log"))
        }

        // 2. 导出当前设置
        let prefs: [String: Any] = [
            "lockRSSI": manager.lockRSSI,
            "unlockRSSI": manager.unlockRSSI,
            "enabled": UserDefaults.standard.bool(forKey: "enabled"),
            "device": UserDefaults.standard.string(forKey: "device") ?? "none",
            "deviceName": UserDefaults.standard.string(forKey: "deviceName") ?? "none",
            "wakeOnProximity": UserDefaults.standard.bool(forKey: "wakeOnProximity"),
            "pauseItunes": UserDefaults.standard.bool(forKey: "pauseItunes"),
            "screensaver": UserDefaults.standard.bool(forKey: "screensaver"),
            "sleepDisplay": UserDefaults.standard.bool(forKey: "sleepDisplay"),
            "lockOnIdle": UserDefaults.standard.bool(forKey: "lockOnIdle"),
            "passiveMode": UserDefaults.standard.bool(forKey: "passiveMode"),
        ]
        if let plistData = try? PropertyListSerialization.data(fromPropertyList: prefs, format: .xml, options: 0) {
            try? plistData.write(to: tempDir.appendingPathComponent("settings.plist"))
        }

        // 3. 系统信息
        var modelSize = ""
        var size = 0
        var sizeLen = MemoryLayout.size(ofValue: size)
        sysctlbyname("hw.model", &modelSize, &sizeLen, nil, 0)
        let sysInfo = """
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Model: \(modelSize)
        FUnlock: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))
        """
        try? sysInfo.write(to: tempDir.appendingPathComponent("system_info.txt"), atomically: true, encoding: .utf8)

        // 4. 打开 Finder
        NSWorkspace.shared.open(tempDir)
    }

    // MARK: - 底部

    private var footerSection: some View {
        HStack(spacing: 12) {
            Button(action: { manager.lockNow() }) {
                HStack { Image(systemName: "lock.fill"); Text(t("lock_now")) }
                    .font(.callout).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).tint(.orange)

            Button(action: { NSApplication.shared.terminate(nil) }) {
                HStack { Image(systemName: "power"); Text(t("quit")) }
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
        case .unlocked: return t("status_unlocked")
        case .locked(let reason):
            switch reason {
            case .away: return t("status_locked_away")
            case .lost: return t("status_locked_lost")
            case .manual: return t("status_locked_manual")
            case .timeout: return t("status_locked_timeout")
            }
        case .screensaver: return t("status_screensaver")
        case .displaySleeping: return t("status_display_sleeping")
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

    private var scenarioText: String {
        guard let rssi = manager.rssi else { return t("scenario_no_signal") }
        if rssi >= -45 { return t("scenario_very_close") }
        if rssi >= manager.unlockRSSI { return t("scenario_in_range") }
        if rssi >= manager.lockRSSI { return t("scenario_approaching") }
        if rssi >= manager.lockRSSI - 10 { return t("scenario_weakening") }
        return t("scenario_far")
    }

    private var scenarioColor: Color {
        guard let rssi = manager.rssi else { return .gray }
        if rssi >= manager.unlockRSSI { return .green }
        if rssi >= manager.lockRSSI { return .orange }
        return .red
    }

    // MARK: - Toast

    func showToast(_ message: String, icon: String, color: Color) {
        toastMessage = message
        toastIcon = icon
        toastColor = color
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation { toastMessage = nil }
        }
    }
}

// MARK: - 引导页

private struct OnboardingView: View {
    @Binding var step: Int
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 20) {
            // 步骤指示器
            HStack(spacing: 6) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(i <= step ? Color.accentColor : Color.gray.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.top, 16)

            // 内容
            VStack(spacing: 12) {
                Image(systemName: stepIcon)
                    .font(.system(size: 40))
                    .foregroundColor(.accentColor)
                    .padding(.top, 8)

                Text(stepTitle)
                    .font(.title3.bold())

                Text(stepDescription)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Spacer()

            // 按钮
            VStack(spacing: 8) {
                if step < 2 {
                    Button(action: { withAnimation { step += 1 } }) {
                        Text(t("onboarding_next"))
                            .font(.callout.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button(action: finishOnboarding) {
                        Text(t("onboarding_skip"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: {
                        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                        isPresented = false
                    }) {
                        Text(t("onboarding_start"))
                            .font(.callout.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .frame(width: 300, height: 320)
        .background(.regularMaterial)
    }

    private func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        isPresented = false
    }

    private var stepIcon: String {
        switch step {
        case 0: return "lock.open.fill"
        case 1: return "antenna.radiowaves.left.and.right"
        default: return "wand.and.stars"
        }
    }

    private var stepTitle: String {
        switch step {
        case 0: return t("onboarding_title_0")
        case 1: return t("onboarding_title_1")
        default: return t("onboarding_title_2")
        }
    }

    private var stepDescription: String {
        switch step {
        case 0: return t("onboarding_desc_0")
        case 1: return t("onboarding_desc_1")
        default: return t("onboarding_desc_2")
        }
    }
}

// MARK: - 场景自动化

private struct AutomationView: View {
    @Binding var isPresented: Bool

    private static let eventScriptDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("jp.sone.BLEUnlock/event")
    }()

    private struct EventItem {
        let name: String
        let icon: String
        let fileName: String
    }

    private let events: [EventItem] = [
        EventItem(name: "away",   icon: "lock.fill",        fileName: "away"),
        EventItem(name: "lost",   icon: "wifi.slash",       fileName: "lost"),
        EventItem(name: "unlocked", icon: "lock.open.fill", fileName: "unlocked"),
        EventItem(name: "intruded", icon: "hand.raised.fill", fileName: "intruded")
    ]

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                Spacer()
                Text(t("automation_title"))
                    .font(.headline)
                Spacer()
                Color.clear.frame(width: 24)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // 事件列表
            VStack(spacing: 0) {
                ForEach(events, id: \.name) { event in
                    if event.name != events.first?.name {
                        Divider().padding(.leading, 44)
                    }
                    eventRow(event)
                }
            }
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(10)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            // 说明文字
            Text(t("automation_hint"))
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            Spacer()
        }
        .frame(width: 300, height: 300)
        .background(.regularMaterial)
    }

    private func eventRow(_ event: EventItem) -> some View {
        let configured = isScriptConfigured(event.fileName)
        return HStack(spacing: 10) {
            Image(systemName: event.icon)
                .font(.system(size: 14))
                .foregroundColor(configured ? .green : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(t("event_\(event.name)"))
                    .font(.callout)
                Text(configured ? t("automation_configured") : t("automation_not_configured"))
                    .font(.caption)
                    .foregroundColor(configured ? .green : .secondary)
            }

            Spacer()

            Button(action: { openEventDirectory(event.fileName) }) {
                Text(t("automation_setup"))
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func isScriptConfigured(_ fileName: String) -> Bool {
        let fileURL = Self.eventScriptDir.appendingPathComponent(fileName)
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir) && !isDir.boolValue
    }

    private func openEventDirectory(_ eventName: String) {
        let dir = Self.eventScriptDir
        // 确保目录存在
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent(eventName)
        // 如果脚本文件不存在，创建一个空的示例文件提示用户
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            let example = "#!/bin/bash\n# \(eventName) event script\n# Add your commands here\n\n"
            try? example.write(to: fileURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path)
        }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
}

// MARK: - 解锁统计面板

private struct StatsView: View {
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

// MARK: - Toast

struct ToastView: View {
    let message: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(color)
            Text(message)
                .font(.callout)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .cornerRadius(10)
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }
}
