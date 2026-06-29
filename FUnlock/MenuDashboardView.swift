// MenuDashboardView.swift
// SwiftUI 控制中心 — 侧边栏导航布局 + 毛玻璃风格 + 全中文化 + 设备扫描

import SwiftUI
import Combine
import ServiceManagement

// MARK: - Tab 枚举

enum MenuTab: String, CaseIterable {
    case overview   = "overview"
    case device     = "device"
    case basic      = "basic"
    case unlock     = "unlock"
    case lock       = "lock"
    case network    = "network"
    case config     = "config"

    var icon: String {
        switch self {
        case .overview:  return "gauge.medium"
        case .device:    return "antenna.radiowaves.left.and.right"
        case .basic:     return "gearshape"
        case .unlock:    return "lock.open"
        case .lock:      return "lock"
        case .network:   return "wifi"
        case .config:    return "folder"
        }
    }

    var label: String { t(rawValue) }
}

// MARK: - 通用 Toggle 行组件

struct SettingToggleRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let description: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(iconColor)
                .frame(width: 28, height: 28)
                .background(iconColor.opacity(0.1))
                .cornerRadius(7)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(.green)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - 主视图

struct MenuDashboardView: View {
    @ObservedObject var manager: FUnManager
    @ObservedObject var fun: FUn

    // --- AppStorage ---
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

    // --- State ---
    @StateObject private var profileManager = ProfileManager.shared
    @State private var selectedTab: MenuTab = .overview
    @State private var showCalibration = false
    @State private var showOnboarding = false
    @State private var showAutomation = false
    @State private var showAbout = false
    @State private var showStats = false
    @State private var showAddProfile = false
    @State private var showDeleteProfile = false
    @State private var newProfileName = ""
    @State private var onboardingStep = 0
    @State private var sliderLock: Double = 0
    @State private var sliderUnlock: Double = 0
    @State private var isSliderDragging: Bool = false
    @State private var isScanning = false
    @State private var frozenDevices: [Device] = []
    @State private var scanTimer: Timer?
    @State private var toastMessage: String? = nil
    @State private var toastIcon: String = ""
    @State private var toastColor: Color = .green
    @State private var previousConnected: Bool? = nil

    var isThresholdApplied: Bool {
        Int(sliderLock) == manager.lockRSSI && Int(sliderUnlock) == (manager.unlockRSSI == 1 ? -95 : manager.unlockRSSI)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // 顶部设备状态栏
            deviceStatusBar
            Divider().padding(.horizontal, 8)

            // 侧边栏 + 内容区
            HStack(spacing: 0) {
                sidebarView
                Divider()
                contentView
            }
            .frame(height: 440)

            Divider().padding(.horizontal, 8)

            // 底部按钮
            footerSection
        }
        .frame(width: 440, height: 520)
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

    // MARK: - 顶部设备状态栏

    private var deviceStatusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            if let name = manager.monitoredDeviceName {
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                Text(t("no_device"))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - 侧边栏

    private var sidebarView: some View {
        VStack(spacing: 2) {
            ForEach(MenuTab.allCases, id: \.self) { tab in
                sidebarTabButton(tab)
            }
            Spacer()
        }
        .frame(width: 140)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial.opacity(0.5))
    }

    private func sidebarTabButton(_ tab: MenuTab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 8) {
                Image(systemName: tab.icon)
                    .font(.system(size: 14))
                    .frame(width: 20, alignment: .center)
                Text(tab.label)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                Spacer()
            }
            .foregroundColor(isSelected ? .accentColor : .primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            .cornerRadius(7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 内容区

    private var contentView: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                switch selectedTab {
                case .overview:  overviewContent
                case .device:    deviceContent
                case .basic:     basicContent
                case .unlock:    unlockContent
                case .lock:      lockContent
                case .network:   networkContent
                case .config:    configContent
                }
            }
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 总览页

    private var overviewContent: some View {
        VStack(spacing: 16) {
            // 信号仪表盘
            if manager.monitoredDeviceName != nil {
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .stroke(Color.gray.opacity(0.15), lineWidth: 10)
                            .frame(width: 108, height: 108)
                        Circle()
                            .trim(from: 0, to: signalStrength)
                            .stroke(
                                AngularGradient(
                                    gradient: Gradient(colors: [signalColor.opacity(0.4), signalColor]),
                                    center: .center
                                ),
                                style: StrokeStyle(lineWidth: 10, lineCap: .round)
                            )
                            .frame(width: 108, height: 108)
                            .rotationEffect(.degrees(-90))
                            .animation(.easeInOut(duration: 0.5), value: signalStrength)

                        VStack(spacing: 2) {
                            Text(manager.rssi.map { "\($0)" } ?? "—")
                                .font(.system(size: 30, weight: .thin, design: .monospaced))
                            Text("dBm")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.top, 12)

                    // 场景状态
                    HStack(spacing: 6) {
                        Circle().fill(scenarioColor).frame(width: 7, height: 7)
                        Text(scenarioText)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 14)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary)
                    Text(t("select_device"))
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Text(t("scan_hint"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }

            Divider().padding(.leading, 14)

            // 阈值调节（仅已绑定时显示）
            if manager.monitoredDeviceName != nil {
                VStack(spacing: 12) {
                    // 锁定阈值
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                            .frame(width: 16)
                        Text(t("lock"))
                            .font(.system(size: 12))
                            .frame(width: 30, alignment: .leading)
                        Button(action: { sliderLock = max(-95, sliderLock - 1) }) {
                            Image(systemName: "minus.circle").font(.caption)
                        }.buttonStyle(.plain)
                        Slider(value: $sliderLock, in: Double(-95)...Double(-30))
                        Button(action: { sliderLock = min(-30, sliderLock + 1) }) {
                            Image(systemName: "plus.circle").font(.caption)
                        }.buttonStyle(.plain)
                        Text("\(Int(sliderLock))")
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 32, alignment: .trailing)
                        Text("dBm").font(.system(size: 9)).foregroundColor(.secondary)
                    }

                    // 解锁阈值
                    HStack(spacing: 6) {
                        Image(systemName: "lock.open.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                            .frame(width: 16)
                        Text(t("unlock"))
                            .font(.system(size: 12))
                            .frame(width: 30, alignment: .leading)
                        Button(action: { sliderUnlock = max(-95, sliderUnlock - 1) }) {
                            Image(systemName: "minus.circle").font(.caption)
                        }.buttonStyle(.plain)
                        Slider(value: $sliderUnlock, in: Double(-95)...Double(-30))
                        Button(action: { sliderUnlock = min(-30, sliderUnlock + 1) }) {
                            Image(systemName: "plus.circle").font(.caption)
                        }.buttonStyle(.plain)
                        Text("\(Int(sliderUnlock))")
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 32, alignment: .trailing)
                        Text("dBm").font(.system(size: 9)).foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 14)

                // 应用阈值按钮
                Button(action: {
                    manager.setLockRSSI(Int(sliderLock))
                    manager.setUnlockRSSI(Int(sliderUnlock))
                }) {
                    HStack {
                        Image(systemName: isThresholdApplied ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                            .foregroundColor(isThresholdApplied ? .green : .accentColor)
                        Text(isThresholdApplied ? t("applied") : t("apply_thresholds"))
                            .font(.system(size: 13))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(isThresholdApplied ? 0.15 : 0.1))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)

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

                Divider().padding(.leading, 14)

                // 校准向导入口
                Button(action: { showCalibration = true }) {
                    HStack {
                        Image(systemName: "wand.and.stars")
                            .frame(width: 20)
                        Text(t("calibration_wizard"))
                            .font(.system(size: 13))
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

            // 附加功能入口
            Divider().padding(.leading, 14)
            otherEntriesSection
        }
        .padding(.horizontal, 12)
    }

    // MARK: - 设备页

    private var deviceContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 已绑定设备卡片
            if let deviceName = manager.monitoredDeviceName {
                HStack(spacing: 12) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                        .shadow(color: statusColor.opacity(0.6), radius: 3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(deviceName)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(statusText)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: { manager.unbindDevice() }) {
                        Text(t("unbind"))
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                .padding(12)
                .background(statusColor.opacity(0.06))
                .cornerRadius(10)

                Divider().padding(.leading, 8)
            }

            // 扫描状态 / 可用设备
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundColor(.accentColor)
                    Text(t("select_device"))
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if isScanning {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button(action: startScan) {
                            Text(t("start_search"))
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }

                // 扫描中旋转提示
                if isScanning && frozenDevices.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(t("scan_hint"))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }

                // 空状态
                if frozenDevices.isEmpty && !isScanning {
                    HStack {
                        Spacer()
                        VStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .font(.title2)
                                .foregroundColor(.secondary)
                            Text(t("scan_hint"))
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 16)
                        Spacer()
                    }
                } else {
                    // 设备列表
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(spacing: 4) {
                            ForEach(frozenDevices, id: \.uuid) { device in
                                DeviceRow(device: device) {
                                    manager.selectDevice(device)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 260)
                }
            }
        }
        .padding(.horizontal, 12)
        .onAppear { startScan() }
        .onDisappear { stopScan() }
    }

    private func startScan() {
        stopScan() // avoid duplicate timers
        isScanning = true
        frozenDevices = []
        manager.startScanning()
        // 每 1.5 秒从 manager.discoveredDevices 同步一次，按 RSSI 降序
        scanTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            DispatchQueue.main.async {
                let boundUUID = self.fun.monitoredUUID
                let sorted = manager.discoveredDevices
                    .filter { boundUUID == nil || $0.uuid != boundUUID }
                    .sorted { $0.rssi > $1.rssi }
                withAnimation(.easeInOut(duration: 0.3)) {
                    frozenDevices = sorted
                }
            }
        }
    }

    private func stopScan() {
        scanTimer?.invalidate()
        scanTimer = nil
        isScanning = false
        manager.stopScanning()
    }

    // MARK: - 基础设置页

    private var basicContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageTitle(t("basic_settings"))
            SettingToggleRow(
                icon: "power", iconColor: .green,
                title: t("enable"),
                description: t("enable_desc"),
                isOn: $enabled
            )
            sidebarDivider
            SettingToggleRow(
                icon: "arrow.up.circle", iconColor: .blue,
                title: t("launch_at_login"),
                description: t("launch_at_login_desc"),
                isOn: $launchAtLogin
            )
            .onChange(of: launchAtLogin) { v in
                if #available(macOS 13.0, *) {
                    do {
                        if v { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch { Log.sm.debug("SMAppService error: \(error)") }
                }
            }
        }
        .padding(.horizontal, 12)
    }

    // MARK: - 解锁设置页

    private var unlockContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageTitle(t("unlock_behavior"))
            SettingToggleRow(
                icon: "display", iconColor: .blue,
                title: t("wake_on_proximity"),
                description: t("wake_on_proximity_desc"),
                isOn: $wakeOnProximity
            )
            sidebarDivider
            SettingToggleRow(
                icon: "lock.open", iconColor: .orange,
                title: t("wake_without_unlock"),
                description: t("wake_without_unlock_desc"),
                isOn: $wakeWithoutUnlocking
            )
            sidebarDivider
            SettingToggleRow(
                icon: "sparkles.tv", iconColor: .purple,
                title: t("use_screensaver"),
                description: t("use_screensaver_desc"),
                isOn: $useScreensaver
            )
        }
        .padding(.horizontal, 12)
    }

    // MARK: - 锁定设置页

    private var lockContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageTitle(t("lock_behavior"))
            SettingToggleRow(
                icon: "pause.circle", iconColor: .red,
                title: t("pause_on_lock"),
                description: t("pause_on_lock_desc"),
                isOn: $pauseItunes
            )
            sidebarDivider
            SettingToggleRow(
                icon: "moon.fill", iconColor: .indigo,
                title: t("sleep_display_on_lock"),
                description: t("sleep_display_on_lock_desc"),
                isOn: $sleepDisplay
            )
            sidebarDivider
            SettingToggleRow(
                icon: "keyboard", iconColor: .gray,
                title: t("defer_lock_on_input"),
                description: t("defer_lock_on_input_desc"),
                isOn: $lockOnIdle
            )
            sidebarDivider
            SettingToggleRow(
                icon: "hand.raised.fill", iconColor: .orange,
                title: t("manual_lock_no_auto_unlock"),
                description: t("manual_lock_no_auto_unlock_desc"),
                isOn: $manualLockNoAutoUnlock
            )
        }
        .padding(.horizontal, 12)
    }

    // MARK: - 网络设置页

    private var networkContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageTitle(t("network_connection"))
            SettingToggleRow(
                icon: "wifi", iconColor: .blue,
                title: t("pause_on_wifi"),
                description: t("pause_on_wifi_desc"),
                isOn: $pauseOnWiFi
            )
            if pauseOnWiFi {
                HStack(spacing: 8) {
                    Text(t("wifi_ssid"))
                        .font(.system(size: 12))
                    TextField(t("wifi_ssid_placeholder"), text: $pauseOnWiFiSSID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                    Button(t("current_wifi")) {
                        pauseOnWiFiSSID = WiFiMonitor.shared.currentSSID ?? ""
                    }
                    .font(.system(size: 10))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            sidebarDivider
            SettingToggleRow(
                icon: "antenna.radiowaves.left.and.right", iconColor: .orange,
                title: t("passive_mode"),
                description: t("passive_mode_desc"),
                isOn: $passiveMode
            )
            .onChange(of: passiveMode) { v in fun.setPassiveMode(v) }
        }
        .padding(.horizontal, 12)
    }

    // MARK: - 配置页

    private var configContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            pageTitle(t("profile"))

            HStack(spacing: 8) {
                Image(systemName: "folder.badge.gearshape")
                    .foregroundColor(.accentColor)
                    .frame(width: 16)
                Text(t("profile"))
                    .font(.system(size: 13))
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

                // 删除当前非默认配置
                if profileManager.activeProfileID != "default" {
                    Button(action: { showDeleteProfile = true }) {
                        Image(systemName: "minus.circle")
                            .font(.callout)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.red)
                }
            }
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
            .alert(t("profile_delete_confirm"), isPresented: $showDeleteProfile) {
                Button(t("ok"), role: .destructive) {
                    let id = profileManager.activeProfileID
                    profileManager.activeProfileID = "default"
                    profileManager.deleteProfile(id: id)
                    profileManager.applyActiveProfile(to: manager)
                }
                Button(t("cancel"), role: .cancel) {}
            } message: {
                Text(t("profile_delete_hint"))
            }
        }
        .padding(.horizontal, 12)
    }

    // MARK: - 通用页面元素

    private func pageTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 17, weight: .bold))
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .padding(.top, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sidebarDivider: some View {
        Divider().padding(.leading, 42)
    }

    // MARK: - 附加功能入口（总览页底部）

    private var otherEntriesSection: some View {
        VStack(spacing: 0) {
            Button(action: { showAutomation = true }) {
                HStack {
                    Image(systemName: "bolt.fill").frame(width: 20)
                    Text(t("automation")).font(.system(size: 13))
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            sidebarDivider

            Button(action: { showStats = true }) {
                HStack {
                    Image(systemName: "chart.bar").frame(width: 20)
                    Text(t("unlock_stats")).font(.system(size: 13))
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            sidebarDivider

            Button(action: { showAbout = true }) {
                HStack {
                    Image(systemName: "info.circle").frame(width: 20)
                    Text(t("about_funlock")).font(.system(size: 13))
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            sidebarDivider

            Button(action: { exportDiagnostics() }) {
                HStack {
                    Image(systemName: "square.and.arrow.up").frame(width: 20)
                    Text(t("export_diagnostics")).font(.system(size: 13))
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
        .cornerRadius(10)
        .padding(.horizontal, 12)
    }

    // MARK: - 底部按钮

    private var footerSection: some View {
        HStack(spacing: 12) {
            Button(action: { manager.lockNow() }) {
                HStack { Image(systemName: "lock.fill"); Text(t("lock_now")) }
                    .font(.system(size: 13)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).tint(.orange)

            Button(action: { NSApplication.shared.terminate(nil) }) {
                HStack { Image(systemName: "power"); Text(t("quit")) }
                    .font(.system(size: 13)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).tint(.red)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
        var modelName = "Unknown"
        var size = 128
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: size)
        defer { buffer.deallocate() }
        if sysctlbyname("hw.model", buffer, &size, nil, 0) == 0 {
            modelName = String(cString: buffer)
        }
        let sysInfo = """
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Model: \(modelName)
        FUnlock: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))
        """
        try? sysInfo.write(to: tempDir.appendingPathComponent("system_info.txt"), atomically: true, encoding: .utf8)

        // 4. 打开 Finder
        NSWorkspace.shared.open(tempDir)
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

    // MARK: - 状态计算属性

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
