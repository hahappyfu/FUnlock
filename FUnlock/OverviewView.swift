// OverviewView.swift
// 总览仪表：信号仪表盘 + 设备绑定与切换 + 交互式距离标尺 + 校准入口

import SwiftUI

struct OverviewView: View {
    var manager: FUnManager
    var fun: FUn
    @Binding var showCalibration: Bool

    @AppStorage("enabled", store: ConfigStore.shared.defaults) private var enabled = true

    // 扫描状态
    @State private var isScanning = false
    @State private var frozenDevices: [DeviceSnapshot] = []
    @State private var scanTask: Task<Void, Never>?
    @State private var showUnbindConfirm = false
    @State private var isDeviceListExpanded = false

    /// 主读数是唯一允许使用 @ScaledMetric 的例外（规格 §2.6）
    @ScaledMetric(relativeTo: .largeTitle) private var readoutSize: CGFloat = 30

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FUnlockTheme.Space.sm) {
                header
                if manager.monitoredDeviceName == nil {
                    noDeviceCard
                } else {
                    signalCard
                    FUnlockCard {
                        RangeRailView(manager: manager)
                    }
                }
            }
            .padding(.horizontal, FUnlockTheme.Space.md)
            .padding(.top, FUnlockTheme.Space.sm)
            .padding(.bottom, FUnlockTheme.Space.lg)
        }
        .onDisappear { stopScan() }
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.stopDeviceDiscoveryNotification)) { _ in
            // 设置窗口关闭/隐藏：停掉 UI 扫描任务并收起发现列表
            stopScan()
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                isDeviceListExpanded = false
            }
        }
        .onDisappear {
            stopScan()
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
    }

    // MARK: - 标题行

    private var header: some View {
        HStack(spacing: FUnlockTheme.Space.xs) {
            Text(t("overview"))
                .font(.title2.weight(.semibold))
                .foregroundStyle(FUnlockTheme.Text.primary.color)
            Spacer(minLength: FUnlockTheme.Space.xs)
            InstrumentButton(title: t("calibration_wizard"), systemImage: "wand.and.stars",
                             kind: .primary) {
                showCalibration = true
            }
        }
    }

    // MARK: - 信号主卡

    private var signalCard: some View {
        FUnlockCard {
            VStack(spacing: FUnlockTheme.Space.sm) {
                gauge
                HStack(spacing: 6) {
                    Text(t("distance_scenario_label"))
                        .font(.caption2)
                        .foregroundStyle(FUnlockTheme.Text.secondary.color)
                    Circle()
                        .fill(scenarioColor)
                        .frame(width: 7, height: 7)
                    Text(scenarioText)
                        .font(.callout)
                        .foregroundStyle(FUnlockTheme.Text.secondary.color)
                }
                Hairline()
                deviceRow
                if isDeviceListExpanded {
                    Hairline()
                    scanSection
                }
            }
        }
    }

    private var gauge: some View {
        ZStack {
            Circle()
                .stroke(FUnlockTheme.Surface.well.color, lineWidth: 10)
                .frame(width: 110, height: 110)
            Circle()
                .trim(from: 0, to: signalStrength)
                .stroke(signalColor, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .frame(width: 110, height: 110)
                .rotationEffect(.degrees(-90))
                // 高频仪表盘数据：仅保留 0.1s 防闪烁过渡
                .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: signalStrength)

            VStack(spacing: 2) {
                Text(manager.rssi.map { "\($0)" } ?? "—")
                    .font(.system(size: readoutSize, weight: .light, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(FUnlockTheme.Text.primary.color)
                Text("dBm")
                    .font(.caption)
                    .foregroundStyle(FUnlockTheme.Text.secondary.color)
            }
        }
        .padding(.top, FUnlockTheme.Space.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(manager.rssi.map { "\($0)" } ?? "—") dBm, \(scenarioText)"))
    }

    private var deviceRow: some View {
        HStack(spacing: FUnlockTheme.Space.xs) {
            Label(manager.monitoredDeviceName ?? "", systemImage: deviceIconName(for: manager.monitoredDeviceName ?? ""))
                .font(.body)
                .foregroundStyle(FUnlockTheme.Text.primary.color)
                .lineLimit(1)
            Spacer(minLength: FUnlockTheme.Space.xs)
            InstrumentButton(title: t("change_device"), kind: .secondary, action: toggleDeviceList)
            InstrumentButton(title: t("unbind"), kind: .destructive) {
                showUnbindConfirm = true
            }
        }
    }

    @ViewBuilder
    private var scanSection: some View {
        HStack(spacing: FUnlockTheme.Space.xs) {
            Text(t("select_device"))
                .font(.subheadline)
                .foregroundStyle(FUnlockTheme.Text.secondary.color)
            Spacer(minLength: 0)
            if isScanning {
                ProgressView().controlSize(.small)
            } else {
                InstrumentButton(title: t("start_search"), kind: .secondary, action: startScan)
            }
        }
        if !frozenDevices.isEmpty {
            VStack(spacing: 2) {
                ForEach(frozenDevices, id: \.uuid) { device in
                    DeviceRowView(device: device) {
                        manager.selectDevice(device)
                        stopScan()
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                            isDeviceListExpanded = false
                        }
                    }
                }
            }
        }
    }

    // MARK: - 未绑定设备引导

    private var noDeviceCard: some View {
        FUnlockCard {
            VStack(spacing: FUnlockTheme.Space.sm) {
                VStack(spacing: FUnlockTheme.Space.xs) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.title2)
                        .foregroundStyle(FUnlockTheme.Text.secondary.color)
                    Text(t("select_device"))
                        .font(.headline)
                        .foregroundStyle(FUnlockTheme.Text.primary.color)
                    Text(t("scan_hint"))
                        .font(.callout)
                        .foregroundStyle(FUnlockTheme.Text.secondary.color)
                    if isScanning {
                        ProgressView().controlSize(.small)
                    } else {
                        InstrumentButton(title: t("start_search"), kind: .primary, action: startScan)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, FUnlockTheme.Space.md)

                if !frozenDevices.isEmpty {
                    Hairline()
                    VStack(spacing: 2) {
                        ForEach(frozenDevices, id: \.uuid) { device in
                            DeviceRowView(device: device) {
                                manager.selectDevice(device)
                                stopScan()
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 扫描

    private func toggleDeviceList() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            isDeviceListExpanded.toggle()
        }
        if isDeviceListExpanded {
            startScan()
        } else {
            stopScan()
        }
    }

    private func startScan() {
        stopScan()
        isScanning = true
        frozenDevices = []
        manager.startScanning()
        scanTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { break }
                let boundUUID = fun.monitoredUUID
                let sorted = manager.discoveredDevices
                    .filter { boundUUID == nil || $0.uuid != boundUUID }
                    .sorted { $0.rssi > $1.rssi }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    frozenDevices = sorted
                }
            }
        }
    }

    private func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        manager.stopScanning()
    }

    // MARK: - 计算属性

    /// 距离场景（兼容 UNLOCK_DISABLED / LOCK_DISABLED 哨兵，供单测）
    enum ScenarioLevel: Equatable {
        case noSignal, veryClose, inRange, approaching, weakening, far

        var textKey: String {
            switch self {
            case .noSignal: "scenario_no_signal"
            case .veryClose: "scenario_very_close"
            case .inRange: "scenario_in_range"
            case .approaching: "scenario_approaching"
            case .weakening: "scenario_weakening"
            case .far: "scenario_far"
            }
        }

        var color: Color {
            switch self {
            case .veryClose, .inRange: FUnlockTheme.State.safeFill.color
            case .approaching, .weakening: FUnlockTheme.State.amberFill.color
            case .far: FUnlockTheme.State.dangerFill.color
            case .noSignal: FUnlockTheme.Text.secondary.color
            }
        }
    }

    static func scenarioLevel(lockRSSI: Int, unlockRSSI: Int, rssi: Int?) -> ScenarioLevel {
        guard let rssi else { return .noSignal }
        if rssi >= -45 { return .veryClose }
        let unlockDisabled = unlockRSSI == FUn.UNLOCK_DISABLED
        if !unlockDisabled && rssi >= unlockRSSI { return .inRange }
        // 锁定阈值解析：禁用哨兵时回退到解锁阈值（引擎 resolvedLockThreshold 同语义）
        let effectiveLock: Int
        if lockRSSI == FUn.LOCK_DISABLED {
            effectiveLock = unlockDisabled ? SignalHysteresisEngine.rssiRange.lowerBound : unlockRSSI
        } else {
            effectiveLock = lockRSSI
        }
        if rssi >= effectiveLock { return .approaching }
        if rssi >= effectiveLock - 10 { return .weakening }
        return .far
    }

    private var scenarioLevel: ScenarioLevel {
        Self.scenarioLevel(lockRSSI: manager.lockRSSI, unlockRSSI: manager.unlockRSSI, rssi: manager.rssi)
    }

    private var scenarioText: String { t(scenarioLevel.textKey) }

    private var scenarioColor: Color { scenarioLevel.color }

    private var signalStrength: CGFloat {
        guard let rssi = manager.rssi else { return 0 }
        return min(max(CGFloat(rssi + 100) / 70.0, 0), 1)
    }

    private var signalColor: Color {
        if signalStrength > 0.7 { return FUnlockTheme.State.safeFill.color }
        if signalStrength > 0.4 { return FUnlockTheme.State.amberFill.color }
        return FUnlockTheme.State.dangerFill.color
    }
}

// MARK: - 设备行

private struct DeviceRowView: View {
    let device: DeviceSnapshot
    let onSelect: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: FUnlockTheme.Space.xs) {
                Image(systemName: "iphone")
                    .foregroundStyle(FUnlockTheme.Text.secondary.color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name)
                        .font(.body)
                        .foregroundStyle(FUnlockTheme.Text.primary.color)
                        .lineLimit(1)
                    if let mac = device.macAddr {
                        Text(mac.replacingOccurrences(of: "-", with: ":").uppercased())
                            .font(.caption.monospaced())
                            .foregroundStyle(FUnlockTheme.Text.tertiary.color)
                    }
                }
                Spacer(minLength: FUnlockTheme.Space.xs)
                Text("\(device.rssi) dBm")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(rssiColor(device.rssi))
            }
            .padding(.horizontal, FUnlockTheme.Space.xs)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: FUnlockTheme.Radius.md)
                    .fill(isHovering ? FUnlockTheme.Surface.well.color : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : FUnlockTheme.Motion.fast, value: isHovering)
        .onHover { isHovering = $0 }
    }

    /// 与菜单栏信号档位同源（-60 / -75 单测锁定）
    private func rssiColor(_ rssi: Int) -> Color {
        switch MenuBarPopoverView.signalLevel(for: Double(rssi)) {
        case .excellent: FUnlockTheme.State.safeFill.color
        case .good: FUnlockTheme.State.amberFill.color
        case .weak: FUnlockTheme.State.dangerFill.color
        }
    }
}
