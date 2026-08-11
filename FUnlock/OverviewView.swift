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

    // 偏移量草稿（唤醒提前量 / 预解锁触发量，dB）
    @State private var wakeAdvance: Int = FUn.defaultWakeAdvance
    @State private var preUnlockTrigger: Int = FUn.defaultPreUnlockTrigger

    // 扫描状态
    @State private var isScanning = false
    @State private var frozenDevices: [Device] = []
    @State private var scanTimer: Timer?

    @State private var showUnbindConfirm = false
    @State private var isDeviceListExpanded = false

    /// RSSI 可视化范围（dBm）
    enum RSSIRange {
        static let min = -95.0
        static let max = -30.0
    }

    /// 禁用解锁时的 UI 回退阈值：以滑块最小值显示
    private var effectiveUnlockRSSI: Int {
        manager.unlockRSSI == FUn().UNLOCK_DISABLED ? Int(RSSIRange.min) : manager.unlockRSSI
    }

    var isThresholdApplied: Bool {
        Int(sliderLock) == manager.lockRSSI && Int(sliderUnlock) == effectiveUnlockRSSI
            && wakeAdvance == thresholdSettingValue("wakeAdvance", default: FUn.defaultWakeAdvance)
            && preUnlockTrigger == thresholdSettingValue("preUnlockTrigger", default: FUn.defaultPreUnlockTrigger)
    }

    private func thresholdSettingValue(_ key: String, default dft: Int) -> Int {
        UserDefaults.standard.object(forKey: key) as? Int ?? dft
    }

    private func xPos(_ v: Double, _ width: CGFloat) -> CGFloat {
        let minV = RSSIRange.min, maxV = RSSIRange.max
        return CGFloat((v - minV) / (maxV - minV)) * width
    }

    var body: some View {
        ScrollView {
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
        }
        .onAppear {
            sliderLock = Double(manager.lockRSSI)
            sliderUnlock = Double(effectiveUnlockRSSI)
            wakeAdvance = thresholdSettingValue("wakeAdvance", default: FUn.defaultWakeAdvance)
            preUnlockTrigger = thresholdSettingValue("preUnlockTrigger", default: FUn.defaultPreUnlockTrigger)
        }
        .onReceive(manager.$lockRSSI) { newValue in
            if Int(sliderLock) != newValue && !isSliderDragging {
                sliderLock = Double(newValue)
            }
        }
        .onReceive(manager.$unlockRSSI) { newValue in
            let expected = (newValue == FUn().UNLOCK_DISABLED ? Int(RSSIRange.min) : newValue)
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
                Label(manager.monitoredDeviceName ?? "", systemImage: deviceIconName(for: manager.monitoredDeviceName ?? ""))
                Spacer()
                Button(t("change_device")) { toggleDeviceList() }
                    .controlSize(.small)
                Button(t("unbind")) { showUnbindConfirm = true }
                    .controlSize(.small)
            }
            .alert(t("unbind_confirm_title"), isPresented: $showUnbindConfirm) {
                Button(t("ok"), role: .destructive) {
                    manager.unbindDevice()
                    isDeviceListExpanded = false
                    stopScan()
                }
                Button(t("cancel"), role: .cancel) {}
            } message: {
                Text(t("unbind_confirm_message"))
            }

            if isDeviceListExpanded {
                HStack {
                    Text(t("select_device"))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    if isScanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(t("start_search")) { startScan() }
                            .controlSize(.small)
                    }
                }

                if !frozenDevices.isEmpty {
                    ForEach(frozenDevices, id: \.uuid) { device in
                        DeviceRowView(device: device) {
                            manager.selectDevice(device)
                            stopScan()
                            withAnimation(.easeInOut(duration: 0.3)) {
                                isDeviceListExpanded = false
                            }
                        }
                    }
                }
            }
        }
    }

    private func toggleDeviceList() {
        withAnimation(.easeInOut(duration: 0.3)) {
            isDeviceListExpanded.toggle()
        }
        if isDeviceListExpanded {
            startScan()
        } else {
            stopScan()
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
                // 高频仪表盘数据：仅保留 0.1s 防闪烁过渡（原 0.5s easeInOut 让实时信号显得迟钝）
                .animation(.easeOut(duration: 0.1), value: signalStrength)

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

            ThresholdSliderRow(icon: "lock.fill", color: .orange, title: t("lock"),
                               value: $sliderLock, isDragging: $isSliderDragging)
            ThresholdSliderRow(icon: "lock.open.fill", color: .green, title: t("unlock"),
                               value: $sliderUnlock, isDragging: $isSliderDragging)

            ThresholdOffsetRow(icon: "sun.max.fill", color: .blue,
                               title: t("wake_advance"),
                               preText: t("subtitle_pre"), postText: t("wake_subtitle_post"),
                               derivedValue: Int(sliderUnlock) - wakeAdvance,
                               value: $wakeAdvance)
            ThresholdOffsetRow(icon: "bolt.fill", color: .purple,
                               title: t("pre_unlock_trigger"),
                               preText: t("subtitle_pre"), postText: t("pre_subtitle_post"),
                               derivedValue: Int(sliderUnlock) - preUnlockTrigger,
                               value: $preUnlockTrigger)

            Button {
                manager.setUnlockRSSI(Int(sliderUnlock))
                manager.setLockRSSI(Int(sliderLock))
                manager.setWakeAdvance(wakeAdvance)
                manager.setPreUnlockTrigger(preUnlockTrigger)
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

            ZStack(alignment: .leading) {
                // 底轨
                Capsule().fill(Color.gray.opacity(0.2)).frame(height: 6)
                // 锁定区（橙）到解锁区（绿）：标记两个阈值游标
                if let rssi = manager.rssi {
                    Circle()
                        .fill(signalColor)
                        .frame(width: 10, height: 10)
                        .position(x: xPos(Double(rssi), width), y: 0)
                        .shadow(radius: 1)
                }
                Circle().fill(Color.orange)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .position(x: xPos(Double(manager.lockRSSI), width), y: 0)
                Circle().fill(Color.green)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .position(x: xPos(Double(effectiveUnlockRSSI), width), y: 0)
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

// MARK: - 阈值滑块行

private struct ThresholdSliderRow: View {
    let icon: String
    let color: Color
    let title: String
    @Binding var value: Double
    @Binding var isDragging: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundColor(color).frame(width: 16)
            Text(title).frame(width: 30, alignment: .leading)
            Slider(value: $value, in: OverviewView.RSSIRange.min...OverviewView.RSSIRange.max,
                   onEditingChanged: { editing in isDragging = editing })
            Text("\(Int(value))")
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 34, alignment: .trailing)
            Text("dBm").font(.caption).foregroundColor(.secondary)
        }
    }
}

// MARK: - 偏移量输入行

/// 可填数字的偏移量行：主标题 + 带动态数值的简练副标题（dB，0-20）
private struct ThresholdOffsetRow: View {
    let icon: String
    let color: Color
    let title: String
    let preText: String
    let postText: String
    let derivedValue: Int
    @Binding var value: Int

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundColor(color).frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                (Text(preText)
                    .foregroundColor(.secondary)
                 + Text("\(derivedValue) dBm")
                    .fontWeight(.semibold)
                    .foregroundColor(.accentColor)
                 + Text(postText)
                    .foregroundColor(.secondary))
                    .font(.caption2)
                    .lineSpacing(2)
            }
            Spacer()
            // 输入框 + 单位：右侧固定宽度整体右对齐
            HStack(spacing: 4) {
                TextField("dB", value: $value, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 54)
                Text("dB")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            .frame(width: 88, alignment: .trailing)
        }
    }
}

// MARK: - 设备行

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