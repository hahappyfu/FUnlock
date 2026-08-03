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
    @State private var isDeviceListExpanded = false

    var isThresholdApplied: Bool {
        Int(sliderLock) == manager.lockRSSI && Int(sliderUnlock) == (manager.unlockRSSI == 1 ? -95 : manager.unlockRSSI)
    }

    private func xPos(_ v: Double, _ width: CGFloat) -> CGFloat {
        let minV = -95.0, maxV = -30.0
        return CGFloat((v - minV) / (maxV - minV)) * width
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
                    .position(x: xPos(Double(manager.unlockRSSI == 1 ? -95 : manager.unlockRSSI), width), y: 0)
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