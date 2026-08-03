# FUnlock UI 重设计（产品化）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 FUnlock 全部 SwiftUI 界面从自绘 440×520 侧边栏布局，重构为 macOS 13+ NavigationSplitView + Form 的系统设置风设计，实现产品化。

**Architecture:** 用 `NavigationSplitView`（侧边栏 + 内容区）替换自绘 HStack 布局；侧边栏用 `List`+`Section` 按「常用/设置/诊断」分组；内容区各页用 `Form` 原生分组。总览页成为主入口（信号盘 + 可视化阈值条 + 设备管理）。巨型文件 `MenuDashboardView.swift`（1043 行）拆为多个单职责视图文件。

**Tech Stack:** SwiftUI (macOS 13+)、NavigationSplitView、Form、List、@AppStorage、SF Symbols。部署目标 12.0 → 13.0。

---

## 文件结构

**创建：**
- `FUnlock/MainWindowView.swift` — NavigationSplitView 骨架、tab 切换、sheet 管理、toast
- `FUnlock/SidebarView.swift` — 分组侧边栏
- `FUnlock/OverviewView.swift` — 总览页（信号盘 + 阈值条 + 设备管理）
- `FUnlock/BasicSettingsView.swift` — 基础设置页
- `FUnlock/UnlockSettingsView.swift` — 解锁设置页
- `FUnlock/LockSettingsView.swift` — 锁定设置页
- `FUnlock/NetworkSettingsView.swift` — 网络设置页
- `FUnlock/ConfigSettingsView.swift` — 配置方案页

**修改：**
- `FUnlock/MenuDashboardView.swift` — 删除（拆分后弃用）
- `FUnlock/AppDelegate.swift` — setupSettingsWindow 改用它窗口、版本号
- `FUnlock.xcodeproj/project.pbxproj` — 部署目标 13.0、增删文件引用
- `FUnlock/Info.plist` — 部署目标 13.0
- `FUnlock/zh-Hans.lproj/Localizable.strings` 及其他 lproj — 新增翻译 key
- `FUnlock/DiagnosticsView.swift` — 仅删除 `onNavigate` 类型对 MenuTab 的依赖（若保留 MenuTab 枚举则不动）

**保留：** MenuTab 枚举（保留，供 DiagnosticsView 导航和决策日志 `goToTab` 使用）、FUnManager/FUn 业务层、CalibrationWizardView（仅样式统一）、AboutView/StatsView/AutomationView/OnboardingView（仅样式统一）。

---

### Task 1: 部署目标提升到 macOS 13.0

**Files:**
- Modify: `FUnlock.xcodeproj/project.pbxproj`
- Modify: `FUnlock/Info.plist`

- [ ] **Step 1: 修改 project.pbxproj 部署目标**

找到 `MACOSX_DEPLOYMENT_TARGET = 12.0;` 所在行，改为 `13.0`：

```pbxproj
MACOSX_DEPLOYMENT_TARGET = 13.0;
```

- [ ] **Step 2: 确认 Info.plist 无硬编码版本**

`FUnlock/Info.plist` 中 `LSMinimumSystemVersion` 是 `$(MACOSX_DEPLOYMENT_TARGET)` 变量引用，无需改。确认该值存在：

Run: `grep -n "LSMinimumSystemVersion" FUnlock/Info.plist`
Expected: `LSMinimumSystemVersion = $(MACOSX_DEPLOYMENT_TARGET);` 或变量引用形式

- [ ] **Step 3: 验证构建**

Run: `xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -configuration Debug build -quiet 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add FUnlock.xcodeproj/project.pbxproj
git commit -m "build: 部署目标提升到 macOS 13.0"
```

---

### Task 2: 定义 MenuTab 与主骨架（MainWindowView）

**Files:**
- Create: `FUnlock/MainWindowView.swift`

先确认 MenuTab 枚举保留在 MenuDashboardView.swift 中（Task 5 删除该文件时迁移到 MainWindowView.swift）。

- [ ] **Step 1: 创建 MainWindowView.swift**

```swift
// MainWindowView.swift
// NavigationSplitView 主骨架：分组侧边栏 + 内容区 + sheet 管理

import SwiftUI

struct MainWindowView: View {
    @ObservedObject var manager: FUnManager
    @ObservedObject var fun: FUn

    @State private var selectedTab: MenuTab? = .overview
    @State private var showCalibration = false
    @State private var showOnboarding = false
    @State private var showAutomation = false
    @State private var showAbout = false
    @State private var showStats = false
    @State private var onboardingStep = 0
    @State private var toastMessage: String? = nil
    @State private var toastIcon = ""
    @State private var toastColor: Color = .green
    @State private var previousConnected: Bool? = nil

    var body: some View {
        NavigationSplitView {
            SidebarView(selectedTab: $selectedTab, manager: manager)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            contentView
        }
        .frame(minWidth: 560, minHeight: 420)
        .overlay(alignment: .top) {
            if let msg = toastMessage {
                ToastView(message: msg, icon: toastIcon, color: toastColor)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 8)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: toastMessage)
        .onAppear {
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

    @ViewBuilder
    private var contentView: some View {
        switch selectedTab ?? .overview {
        case .overview:
            OverviewView(manager: manager, fun: fun,
                         showCalibration: $showCalibration)
        case .device:
            OverviewView(manager: manager, fun: fun,
                         showCalibration: $showCalibration)
        case .basic:
            BasicSettingsView()
        case .unlock:
            UnlockSettingsView()
        case .lock:
            LockSettingsView()
        case .network:
            NetworkSettingsView(fun: fun)
        case .config:
            ConfigSettingsView(manager: manager)
        case .diagnostics:
            DiagnosticsView(manager: manager,
                            onNavigate: { selectedTab = $0 })
        }
    }

    func showToast(_ message: String, icon: String, color: Color) {
        toastMessage = message
        toastIcon = icon
        toastColor = color
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation { toastMessage = nil }
        }
    }
}
```

注：`.device` case 暂时映射到 OverviewView（Task 4 统一后删除该 case）。

- [ ] **Step 2: 验证编译（预期失败——SidebarView 等尚未创建）**

Run: `xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -configuration Debug build -quiet 2>&1 | grep -E "error:" | head -20`
Expected: 报错 `cannot find 'SidebarView'`、`cannot find 'OverviewView'` 等（文件未加入工程）。此步仅确认错误类型正确，不用修。

- [ ] **Step 3: Commit（新文件加入工程在 Task 5 统一处理）**

```bash
git add FUnlock/MainWindowView.swift
git commit -m "feat(ui): 添加 NavigationSplitView 主骨架"
```

---

### Task 3: 分组侧边栏（SidebarView）

**Files:**
- Create: `FUnlock/SidebarView.swift`

- [ ] **Step 1: 创建 SidebarView.swift**

```swift
// SidebarView.swift
// 分组侧边栏：常用 / 设置 / 诊断

import SwiftUI

struct SidebarView: View {
    @Binding var selectedTab: MenuTab?
    @ObservedObject var manager: FUnManager

    private enum SidebarGroup: String, CaseIterable {
        case common = "sidebar_group_common"
        case settings = "sidebar_group_settings"
        case diagnostics = "sidebar_group_diagnostics"

        var tabs: [MenuTab] {
            switch self {
            case .common: return [.overview, .lock, .unlock]
            case .settings: return [.basic, .network, .config]
            case .diagnostics: return [.diagnostics]
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            deviceStatusRow
            List(selection: $selectedTab) {
                ForEach(SidebarGroup.allCases, id: \.self) { group in
                    Section(group.rawValue) {
                        ForEach(group.tabs, id: \.self) { tab in
                            Label(tab.label, systemImage: tab.icon)
                                .tag(tab)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var deviceStatusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(manager.monitoredDeviceName ?? t("no_device"))
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }

    private var statusColor: Color {
        switch manager.state.screen {
        case .unlocked: return .green
        case .locked: return .orange
        case .screensaver: return .yellow
        case .displaySleeping: return .gray
        }
    }
}
```

- [ ] **Step 2: 在 zh-Hans.lproj/Localizable.strings 添加分组标题**

追加：

```strings
"sidebar_group_common" = "常用";
"sidebar_group_settings" = "设置";
"sidebar_group_diagnostics" = "诊断";
```

同样追加到其他语言 lproj（可先用 zh-Hans 占位同值，Task 8 统一处理本地化）。

- [ ] **Step 3: Commit**

```bash
git add FUnlock/SidebarView.swift FUnlock/zh-Hans.lproj/Localizable.strings
git commit -m "feat(ui): 添加分组侧边栏"
```

---

### Task 4: 总览页（OverviewView）

**Files:**
- Create: `FUnlock/OverviewView.swift`

- [ ] **Step 1: 创建 OverviewView.swift**

```swift
// OverviewView.swift
// 总览页：信号盘 + 可视化阈值条 + 设备管理 + 快捷操作

import SwiftUI
import Combine

struct OverviewView: View {
    @ObservedObject var manager: FUnManager
    @ObservedObject var fun: FUn
    @Binding var showCalibration: Bool

    @AppStorage("enabled") private var enabled = true

    // 阈值滑块状态（本地草稿，不即时写盘）
    @State private var sliderLock: Double = 0
    @State private var sliderUnlock: Double = 0
    @State private var isSliderDragging = false

    // 扫描状态
    @State private var isScanning = false
    @State private var frozenDevices: [Device] = []
    @State private var scanTimer: Timer?

    @State private var showUnbindConfirm = false

    var isThresholdApplied: Bool {
        Int(sliderLock) == manager.lockRSSI && Int(sliderUnlock) == (manager.unlockRSSI == 1 ? -95 : manager.unlockRSSI)
    }

    var body: some View {
        Form {
            if manager.monitoredDeviceName == nil {
                noDeviceSection
            } else {
                deviceStatusSection
                thresholdSection
                quickActionsSection
            }
        }
        .formStyle(.grouped)
        .onAppear {
            sliderLock = Double(manager.lockRSSI)
            sliderUnlock = Double(manager.unlockRSSI == 1 ? -95 : manager.unlockRSSI)
        }
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
        .onDisappear { stopScan() }
    }

    // MARK: 设备状态卡

    private var deviceStatusSection: some View {
        Section {
            VStack(spacing: 12) {
                signalRing
                HStack(spacing: 6) {
                    Circle().fill(scenarioColor).frame(width: 7, height: 7)
                    Text(scenarioText).font(.callout).foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)

            HStack {
                Label(manager.monitoredDeviceName ?? "", systemImage: "iphone")
                Spacer()
                Button(t("unbind")) { showUnbindConfirm = true }
                    .controlSize(.small)
            }
            .alert(t("unbind_confirm_title"), isPresented: $showUnbindConfirm) {
                Button(t("ok"), role: .destructive) { manager.unbindDevice() }
                Button(t("cancel"), role: .cancel) {}
            } message: {
                Text(t("unbind_confirm_message"))
            }
        }
    }

    // MARK: 环形信号盘

    private var signalRing: some View {
        ZStack {
            Circle()
                .stroke(Color.gray.opacity(0.15), lineWidth: 10)
                .frame(width: 110, height: 110)
            Circle()
                .trim(from: 0, to: signalStrength)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [signalColor.opacity(0.4), signalColor]),
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 10, lineCap: .round)
                )
                .frame(width: 110, height: 110)
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.5), value: signalStrength)

            VStack(spacing: 2) {
                Text(manager.rssi.map { "\($0)" } ?? "—")
                    .font(.system(size: 30, weight: .thin, design: .monospaced))
                Text("dBm")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.top, 8)
    }

    // MARK: 阈值分组

    private var thresholdSection: some View {
        Section(t("distance_threshold")) {
            thresholdBar

            HStack(spacing: 6) {
                Image(systemName: "lock.fill").foregroundColor(.orange).frame(width: 16)
                Text(t("lock")).frame(width: 30, alignment: .leading)
                Slider(value: $sliderLock, in: Double(-95)...Double(-30),
                       onEditingChanged: { editing in isSliderDragging = editing })
                Text("\(Int(sliderLock))")
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 34, alignment: .trailing)
                Text("dBm").font(.caption).foregroundColor(.secondary)
            }
            HStack(spacing: 6) {
                Image(systemName: "lock.open.fill").foregroundColor(.green).frame(width: 16)
                Text(t("unlock")).frame(width: 30, alignment: .leading)
                Slider(value: $sliderUnlock, in: Double(-95)...Double(-30),
                       onEditingChanged: { editing in isSliderDragging = editing })
                Text("\(Int(sliderUnlock))")
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 34, alignment: .trailing)
                Text("dBm").font(.caption).foregroundColor(.secondary)
            }

            Button {
                manager.setLockRSSI(Int(sliderLock))
                manager.setUnlockRSSI(Int(sliderUnlock))
            } label: {
                Label(isThresholdApplied ? t("applied") : t("apply_thresholds"),
                      systemImage: isThresholdApplied ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .disabled(isThresholdApplied)
        }
    }

    // MARK: 可视化阈值条

    private var thresholdBar: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let minV = -95.0, maxV = -30.0
            func x(_ v: Double) -> CGFloat { CGFloat((v - minV) / (maxV - minV)) * width }

            ZStack(alignment: .leading) {
                // 底轨
                Capsule().fill(Color.gray.opacity(0.2)).frame(height: 6)
                // 锁定区（橙）到解锁区（绿）：标记两个阈值游标
                if let rssi = manager.rssi {
                    Circle()
                        .fill(signalColor)
                        .frame(width: 10, height: 10)
                        .position(x: x(Double(rssi)), y: 0)
                        .shadow(radius: 1)
                }
                Circle().fill(Color.orange)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .position(x: x(Double(manager.lockRSSI)), y: 0)
                Circle().fill(Color.green)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .position(x: x(Double(manager.unlockRSSI == 1 ? -95 : manager.unlockRSSI)), y: 0)
            }
            .frame(height: 14)
            .frame(maxWidth: .infinity)
        }
        .frame(height: 18)
        .padding(.vertical, 4)
    }

    // MARK: 快捷操作

    private var quickActionsSection: some View {
        Section {
            Button {
                showCalibration = true
            } label: {
                Label(t("calibration_wizard"), systemImage: "wand.and.stars")
            }
            Button {
                manager.lockNow()
            } label: {
                Label(t("lock_now"), systemImage: "lock.fill")
            }
        }
    }

    // MARK: 未绑定设备引导卡

    private var noDeviceSection: some View {
        Section {
            VStack(spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 30))
                    .foregroundColor(.secondary)
                Text(t("select_device"))
                    .font(.headline)
                Text(t("scan_hint"))
                    .font(.callout)
                    .foregroundColor(.secondary)
                if isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Button(t("start_search")) { startScan() }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)

            if !frozenDevices.isEmpty {
                ForEach(frozenDevices, id: \.uuid) { device in
                    DeviceRowView(device: device) {
                        manager.selectDevice(device)
                        stopScan()
                    }
                }
            }
        }
    }

    // MARK: 扫描

    private func startScan() {
        stopScan()
        isScanning = true
        frozenDevices = []
        manager.startScanning()
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

    // MARK: 计算属性

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
}
```

- [ ] **Step 2: 添加设备行视图（同文件内）**

```swift
// OverviewView.swift 文件末尾追加

private struct DeviceRowView: View {
    let device: Device
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack {
                Image(systemName: "iphone")
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.description)
                        .lineLimit(1)
                    if let mac = device.macAddr {
                        Text(mac.replacingOccurrences(of: "-", with: ":").uppercased())
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                Text("\(device.rssi) dBm")
                    .font(.caption)
                    .foregroundColor(rssiColor(device.rssi))
            }
        }
    }

    private func rssiColor(_ rssi: Int) -> Color {
        if rssi >= -50 { return .green }
        if rssi >= -70 { return .yellow }
        return .red
    }
}
```

- [ ] **Step 3: 添加翻译 key（zh-Hans 等）**

```strings
"distance_threshold" = "距离阈值";
```

- [ ] **Step 4: Commit**

```bash
git add FUnlock/OverviewView.swift FUnlock/zh-Hans.lproj/Localizable.strings
git commit -m "feat(ui): 添加总览页（信号盘+阈值条+设备管理）"
```

---

### Task 5: 各设置页独立视图

**Files:**
- Create: `FUnlock/BasicSettingsView.swift`, `FUnlock/UnlockSettingsView.swift`, `FUnlock/LockSettingsView.swift`, `FUnlock/NetworkSettingsView.swift`, `FUnlock/ConfigSettingsView.swift`

- [ ] **Step 1: 创建 BasicSettingsView.swift**

```swift
// BasicSettingsView.swift
import SwiftUI

struct BasicSettingsView: View {
    @AppStorage("enabled") private var enabled = true
    @AppStorage("launchAtLogin") private var launchAtLogin = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $enabled) {
                    Label(t("enable"), systemImage: "power")
                    Text(t("enable_desc")).font(.caption).foregroundColor(.secondary)
                }
                Toggle(isOn: $launchAtLogin) {
                    Label(t("launch_at_login"), systemImage: "arrow.up.circle")
                    Text(t("launch_at_login_desc")).font(.caption).foregroundColor(.secondary)
                }
                .onChange(of: launchAtLogin) { v in
                    if #available(macOS 13.0, *) {
                        do {
                            if v { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch { Log.sm.debug("SMAppService error: \(error)") }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
```

- [ ] **Step 2: 创建 UnlockSettingsView.swift**

```swift
// UnlockSettingsView.swift
import SwiftUI

struct UnlockSettingsView: View {
    @AppStorage("wakeOnProximity") private var wakeOnProximity = false
    @AppStorage("wakeWithoutUnlocking") private var wakeWithoutUnlocking = false
    @AppStorage("screensaver") private var useScreensaver = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $wakeOnProximity) {
                    Label(t("wake_on_proximity"), systemImage: "display")
                    Text(t("wake_on_proximity_desc")).font(.caption).foregroundColor(.secondary)
                }
                Toggle(isOn: $wakeWithoutUnlocking) {
                    Label(t("wake_without_unlock"), systemImage: "lock.open")
                    Text(t("wake_without_unlock_desc")).font(.caption).foregroundColor(.secondary)
                }
                Toggle(isOn: $useScreensaver) {
                    Label(t("use_screensaver"), systemImage: "sparkles.tv")
                    Text(t("use_screensaver_desc")).font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
```

- [ ] **Step 3: 创建 LockSettingsView.swift**

```swift
// LockSettingsView.swift
import SwiftUI

struct LockSettingsView: View {
    @AppStorage("pauseItunes") private var pauseItunes = false
    @AppStorage("sleepDisplay") private var sleepDisplay = false
    @AppStorage("lockOnIdle") private var lockOnIdle = true
    @AppStorage("manualLockNoAutoUnlock") private var manualLockNoAutoUnlock = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $pauseItunes) {
                    Label(t("pause_on_lock"), systemImage: "pause.circle")
                    Text(t("pause_on_lock_desc")).font(.caption).foregroundColor(.secondary)
                }
                Toggle(isOn: $sleepDisplay) {
                    Label(t("sleep_display_on_lock"), systemImage: "moon.fill")
                    Text(t("sleep_display_on_lock_desc")).font(.caption).foregroundColor(.secondary)
                }
                Toggle(isOn: $lockOnIdle) {
                    Label(t("defer_lock_on_input"), systemImage: "keyboard")
                    Text(t("defer_lock_on_input_desc")).font(.caption).foregroundColor(.secondary)
                }
                Toggle(isOn: $manualLockNoAutoUnlock) {
                    Label(t("manual_lock_no_auto_unlock"), systemImage: "hand.raised.fill")
                    Text(t("manual_lock_no_auto_unlock_desc")).font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
```

- [ ] **Step 4: 创建 NetworkSettingsView.swift**

```swift
// NetworkSettingsView.swift
import SwiftUI

struct NetworkSettingsView: View {
    @ObservedObject var fun: FUn
    @AppStorage("pauseOnWiFi") private var pauseOnWiFi = false
    @AppStorage("pauseOnWiFiSSID") private var pauseOnWiFiSSID = ""
    @AppStorage("passiveMode") private var passiveMode = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $pauseOnWiFi) {
                    Label(t("pause_on_wifi"), systemImage: "wifi")
                    Text(t("pause_on_wifi_desc")).font(.caption).foregroundColor(.secondary)
                }
                if pauseOnWiFi {
                    HStack {
                        Text(t("wifi_ssid"))
                        TextField(t("wifi_ssid_placeholder"), text: $pauseOnWiFiSSID)
                            .textFieldStyle(.roundedBorder)
                        Button(t("current_wifi")) {
                            pauseOnWiFiSSID = WiFiMonitor.shared.currentSSID ?? ""
                        }
                        .controlSize(.small)
                    }
                }
                Toggle(isOn: $passiveMode) {
                    Label(t("passive_mode"), systemImage: "antenna.radiowaves.left.and.right")
                    Text(t("passive_mode_desc")).font(.caption).foregroundColor(.secondary)
                }
                .onChange(of: passiveMode) { v in fun.setPassiveMode(v) }
            }
        }
        .formStyle(.grouped)
    }
}
```

- [ ] **Step 5: 创建 ConfigSettingsView.swift**

```swift
// ConfigSettingsView.swift
import SwiftUI

struct ConfigSettingsView: View {
    @ObservedObject var manager: FUnManager
    @StateObject private var profileManager = ProfileManager.shared

    @State private var showAddProfile = false
    @State private var showDeleteProfile = false
    @State private var newProfileName = ""

    var body: some View {
        Form {
            Section {
                Picker(t("profile"), selection: $profileManager.activeProfileID) {
                    ForEach(profileManager.profiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                .onChange(of: profileManager.activeProfileID) { id in
                    profileManager.setActive(id)
                    profileManager.applyActiveProfile(to: manager)
                }

                HStack {
                    Spacer()
                    Button {
                        newProfileName = ""
                        showAddProfile = true
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    if profileManager.activeProfileID != "default" {
                        Button { showDeleteProfile = true } label: {
                            Image(systemName: "minus.circle")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
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
}
```

- [ ] **Step 6: Commit**

```bash
git add FUnlock/BasicSettingsView.swift FUnlock/UnlockSettingsView.swift FUnlock/LockSettingsView.swift FUnlock/NetworkSettingsView.swift FUnlock/ConfigSettingsView.swift
git commit -m "feat(ui): 拆分各设置页为独立 Form 视图"
```

---

### Task 6: 迁移 MenuTab 枚举并删除 MenuDashboardView

**Files:**
- Modify: `FUnlock/MainWindowView.swift`（迁移 MenuTab）
- Delete: `FUnlock/MenuDashboardView.swift`

- [ ] **Step 1: 将 MenuTab 枚举迁移到 MainWindowView.swift 顶部**

在 MainWindowView.swift 的 `import` 之后、`struct MainWindowView` 之前插入：

```swift
// MARK: - Tab 枚举

enum MenuTab: String, CaseIterable {
    case overview   = "overview"
    case device     = "device"
    case basic      = "basic"
    case unlock     = "unlock"
    case lock       = "lock"
    case network    = "network"
    case config     = "config"
    case diagnostics = "diagnostics"

    var icon: String {
        switch self {
        case .overview:  return "gauge.medium"
        case .device:    return "antenna.radiowaves.left.and.right"
        case .basic:     return "gearshape"
        case .unlock:    return "lock.open"
        case .lock:      return "lock"
        case .network:   return "wifi"
        case .config:    return "folder"
        case .diagnostics: return "waveform.path.ecg"
        }
    }

    var label: String { t(rawValue) }
}
```

- [ ] **Step 2: 删除 MenuDashboardView.swift**

```bash
git rm FUnlock/MenuDashboardView.swift
```

- [ ] **Step 3: 更新 AppDelegate.swift 的引用**

将 `FUnlock/AppDelegate.swift:588` 附近：

```swift
let dashboard = MenuDashboardView(manager: manager, fun: fun)
let hostingVC = NSHostingController(rootView: dashboard)
settingsWindow = NSWindow(contentViewController: hostingVC)
settingsWindow.title = "FUnlock"
settingsWindow.styleMask = [.titled, .closable, .resizable]
settingsWindow.contentMinSize = NSSize(width: 440, height: 480)
settingsWindow.contentMaxSize = NSSize(width: 520, height: 800)
settingsWindow.isReleasedWhenClosed = false
settingsWindow.center()
```

替换为：

```swift
let dashboard = MainWindowView(manager: manager, fun: fun)
let hostingVC = NSHostingController(rootView: dashboard)
settingsWindow = NSWindow(contentViewController: hostingVC)
settingsWindow.title = "FUnlock"
settingsWindow.styleMask = [.titled, .closable, .resizable]
settingsWindow.contentMinSize = NSSize(width: 560, height: 420)
settingsWindow.isReleasedWhenClosed = false
settingsWindow.center()
```

- [ ] **Step 4: 更新 pbxproj（删除 MenuDashboardView，添加 8 个新文件）**

在 `FUnlock.xcodeproj/project.pbxproj` 中：
1. 删除所有 `MenuDashboardView.swift` 的 PBXBuildFile/PBXFileReference/group/Sources 引用（4 处）
2. 仿照现有模式，为 8 个新文件添加 PBXFileReference + PBXBuildFile + group 成员 + Sources 条目（用全局唯一的 24 位十六进制 ID，如以 `AA0000DD` 开头递增）

示例新增条目（文件引用，ID 需唯一）：

```pbxproj
		AA0000DD00000001 /* MainWindowView.swift */ = {isa = PBXBuildFile; fileRef = AA0000DD00000011 /* MainWindowView.swift */; };
		AA0000DD00000002 /* SidebarView.swift */ = {isa = PBXBuildFile; fileRef = AA0000DD00000012 /* SidebarView.swift */; };
		AA0000DD00000003 /* OverviewView.swift */ = {isa = PBXBuildFile; fileRef = AA0000DD00000013 /* OverviewView.swift */; };
		AA0000DD00000004 /* BasicSettingsView.swift */ = {isa = PBXBuildFile; fileRef = AA0000DD00000014 /* BasicSettingsView.swift */; };
		AA0000DD00000005 /* UnlockSettingsView.swift */ = {isa = PBXBuildFile; fileRef = AA0000DD00000015 /* UnlockSettingsView.swift */; };
		AA0000DD00000006 /* LockSettingsView.swift */ = {isa = PBXBuildFile; fileRef = AA0000DD00000016 /* LockSettingsView.swift */; };
		AA0000DD00000007 /* NetworkSettingsView.swift */ = {isa = PBXBuildFile; fileRef = AA0000DD00000017 /* NetworkSettingsView.swift */; };
		AA0000DD00000008 /* ConfigSettingsView.swift */ = {isa = PBXBuildFile; fileRef = AA0000DD00000018 /* ConfigSettingsView.swift */; };
```

```pbxproj
		AA0000DD00000011 /* MainWindowView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MainWindowView.swift; sourceTree = "<group>"; };
		AA0000DD00000012 /* SidebarView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SidebarView.swift; sourceTree = "<group>"; };
		AA0000DD00000013 /* OverviewView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = OverviewView.swift; sourceTree = "<group>"; };
		AA0000DD00000014 /* BasicSettingsView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = BasicSettingsView.swift; sourceTree = "<group>"; };
		AA0000DD00000015 /* UnlockSettingsView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = UnlockSettingsView.swift; sourceTree = "<group>"; };
		AA0000DD00000016 /* LockSettingsView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = LockSettingsView.swift; sourceTree = "<group>"; };
		AA0000DD00000017 /* NetworkSettingsView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = NetworkSettingsView.swift; sourceTree = "<group>"; };
		AA0000DD00000018 /* ConfigSettingsView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ConfigSettingsView.swift; sourceTree = "<group>"; };
```

在 group children 列表追加 8 个 fileRef，在 Sources build phase 追加 8 个 buildFile 引用。

- [ ] **Step 5: 验证编译**

Run: `xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -configuration Debug build -quiet 2>&1 | grep -E "error:" | head -30`
Expected: 无 error（若 SidebarView 等未加入工程则报 cannot find 错误，说明 pbxproj 遗漏）

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(ui): 迁移 MenuTab 并删除旧 MenuDashboardView"
```

---

### Task 7: 样式统一——附属 sheet

**Files:**
- Modify: `FUnlock/CalibrationWizardView.swift`
- Modify: `FUnlock/StatsView.swift`
- Modify: `FUnlock/AutomationView.swift`
- Modify: `FUnlock/AboutView.swift`
- Modify: `FUnlock/OnboardingView.swift`

- [ ] **Step 1: CalibrationWizardView 统一为 Form 分组 + 步骤化标题**

将 body 的根容器改为 `Form { ... }.formStyle(.grouped)`，步骤标题（step 1/2/3）用 Section header 的 `.textCase(nil)`。仅改样式，不改业务流程（startUnlockCalibration/startLockCountdown/startSampling/averageSamples/abortCalibration/applyValues 保持）。

- [ ] **Step 2: StatsView / AutomationView / AboutView / OnboardingView 统一样式**

将各视图的自定义 VStack + 固定字号 + 背景，替换为 `Form { ... }.formStyle(.grouped)` 分组样式，字号改用系统语义字体（`.body`/`.caption`/`.headline`）。功能与绑定参数（`isPresented` 等）不变。

- [ ] **Step 3: 验证编译**

Run: `xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -configuration Debug build -quiet 2>&1 | grep -E "error:" | head -30`
Expected: 无 error

- [ ] **Step 4: Commit**

```bash
git add FUnlock/CalibrationWizardView.swift FUnlock/StatsView.swift FUnlock/AutomationView.swift FUnlock/AboutView.swift FUnlock/OnboardingView.swift
git commit -m "style(ui): 附属界面统一为 Form 分组风格"
```

---

### Task 8: 本地化补充与清理

**Files:**
- Modify: 所有 `FUnlock/*.lproj/Localizable.strings`

- [ ] **Step 1: 检查并补齐所有新增翻译 key**

在全部 lproj 中检查以下 key 是否存在，缺失则补齐（非中文语言可先填英文值）：

```
sidebar_group_common
sidebar_group_settings
sidebar_group_diagnostics
distance_threshold
```

Run: `for d in FUnlock/*.lproj; do echo "== $d"; grep -c "distance_threshold" "$d/Localizable.strings" || true; done`
Expected: 每个 lproj 输出 1

- [ ] **Step 2: 检查旧 MenuDashboardView 遗留 key 是否还有引用**

旧 key（如 `apply_thresholds`、`applied`、`calibration_wizard`、`lock_now`、`unbind` 等）在新代码中继续使用，保留；若某 key 完全无引用可保留不删（避免破坏其他语言文件）。不做删除。

- [ ] **Step 3: Commit**

```bash
git add FUnlock/*.lproj/Localizable.strings
git commit -m "i18n: 补齐 UI 重设计新增翻译"
```

---

### Task 9: 全量测试与验证

**Files:**
- Modify: 无（验证为主）

- [ ] **Step 1: 运行全量测试**

Run: `xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -configuration Debug test -quiet 2>&1 | grep -E "Test Suite|Test Case.*passed|Test Case.*failed|error:" | tail -20`
Expected: All tests passed，无 error

- [ ] **Step 2: Release 构建**

Run: `xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -configuration Release build -quiet 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: 手动验证清单**

- 窗口自由缩放（最小 560×420），侧边栏宽可拖
- 三组侧边栏（常用/设置/诊断）选中态与导航正确
- 总览页信号盘：有信号显示 dBm 与场景文字、无信号显示空态
- 阈值条：拖动滑块预览、应用后写盘、阈值游标位置正确
- 设备管理：绑定后显示设备卡与解绑、未绑定显示引导卡与扫描列表
- 深色模式全部页面正常
- 4 个 sheet（校准/自动化/关于/统计）样式统一、功能正常
- 阈值应用/校准/统计/自动化功能路径无回归

- [ ] **Step 4: Commit（如有验证期间的修复）**

```bash
git add -A
git commit -m "fix(ui): UI 重设计验证修复"
```

---

## 自审记录

- **Spec 覆盖**：NavigationSplitView（Task 2/6）、分组侧边栏（Task 3）、总览页信号盘/阈值条/设备管理（Task 4）、各设置页 Form 化（Task 5）、附属 sheet 统一（Task 7）、macOS 13 部署目标（Task 1）、本地化（Task 8）、测试验证（Task 9）。
- **设备页归属**：spec 补充决策「并入总览页」，Task 4 实现扫描/解绑/引导卡，Task 2 中 `.device` case 临时映射 OverviewView 并在 Task 6 前确认无需独立页。
- **MenuTab 保留**：.device case 保留在枚举中（DiagnosticsView 的 goToTab 与决策日志引用 rawValue），仅导航映射到 OverviewView。
- **Placeholder 扫描**：无 TBD/TODO；所有文件含完整代码。
- **Type 一致性**：`OverviewView(manager:fun:showCalibration:)` 与 MainWindowView 调用一致；`NetworkSettingsView(fun:)`、`ConfigSettingsView(manager:)`、`DiagnosticsView(manager:onNavigate:)` 签名与 MainWindowView 匹配；`MenuTab` 的 icon/label/rawValue 与旧枚举一致。
