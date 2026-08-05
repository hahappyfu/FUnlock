// MenuBarPopover.swift
// 状态栏菜单（NSPopover + SwiftUI）：现代质感的信息卡 + 快捷操作

import SwiftUI
import Combine

// MARK: - 视图

struct MenuBarPopoverView: View {
    @ObservedObject var manager: FUnManager
    @ObservedObject var fun: FUn
    let onAction: (MenuBarAction) -> Void

    @AppStorage("enabled") private var enabled = true
    @State private var updateStatus: UpdateStatus = .idle
    @State private var updateCheckRequested = false

    enum UpdateStatus: Equatable {
        case idle
        case checking
        case downloading(Double)
        case latest
        case failed
    }

    var body: some View {
        VStack(spacing: 0) {
            statusCard
                .padding(EdgeInsets(top: 12, leading: 12, bottom: 10, trailing: 12))
            Divider()
            enableRow
            Divider()
            actionRows
            Divider()
            quitRow
        }
        .frame(width: 282)
        .background(.ultraThinMaterial)
        .onAppear {
            // 观察下载进度（下载器自动开始后 updateState 会更新）
            if updateCheckRequested { return }
            switch manager.updateState {
            case .downloading(let p): updateStatus = .downloading(p)
            case .completed: updateStatus = .latest
            case .failed: updateStatus = .failed
            default: break
            }
        }
        .onChange(of: manager.updateState) { state in
            switch state {
            case .downloading(let p): updateStatus = .downloading(p)
            case .completed: updateStatus = .latest
            case .failed: updateStatus = .failed
            default: break
            }
        }
    }

    // MARK: - 状态卡

    /// 信号档位：RSSI > -60 极佳；-75 ~ -60 良好；< -75 较弱
    enum SignalLevel: Equatable {
        case excellent
        case good
        case weak

        var main: String {
            switch self {
            case .excellent: return t("mb_signal_excellent")
            case .good: return t("mb_signal_good")
            case .weak: return t("mb_signal_weak")
            }
        }

        var proximity: String {
            switch self {
            case .excellent: return t("mb_signal_very_close")
            case .good: return t("mb_signal_close")
            case .weak: return t("mb_signal_far")
            }
        }

        var color: Color {
            .accentColor
        }

        /// 信号格数：档位内按子档细分（越近格数越多）
        func bars(for rssi: Double) -> Int {
            switch self {
            case .excellent: return 5
            case .good: return rssi > -67 ? 4 : 3
            case .weak: return rssi > -82 ? 2 : 1
            }
        }
    }

    /// 按有效 RSSI 分档
    static func signalLevel(for rssi: Double) -> SignalLevel {
        if rssi > -60 { return .excellent }
        if rssi > -75 { return .good }
        return .weak
    }

    static func signalBars(for rssi: Double) -> Int {
        signalLevel(for: rssi).bars(for: rssi)
    }

    private var signalLevel: SignalLevel {
        MenuBarPopoverView.signalLevel(for: fun.effectiveRSSI)
    }

    private var statusCard: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.blue.opacity(0.85), .indigo.opacity(0.85)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: deviceIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 0) {
                // 第一行：设备名称（粗体 13pt）
                HStack(spacing: 6) {
                    Text(deviceName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Circle()
                        .fill(connectionColor)
                        .frame(width: 6, height: 6)
                }
                // 第二行：信号条 + 语义化描述（12pt）+ 屏幕状态胶囊
                HStack(spacing: 7) {
                    signalBarsView
                    (Text(signalLevel.main)
                        .foregroundColor(Color.accentColor)
                        + Text(" (\(signalLevel.proximity))")
                            .foregroundColor(.secondary))
                        .font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 4)
                    Text(screenStateText)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(screenStateColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(screenStateColor.opacity(0.12), in: Capsule())
                }
                .padding(.top, 4)
                // 第三行：原始信号数值（10pt 次级灰，辅助信息）
                Text(signalText)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
            }
        }
    }

    /// 按设备名推断设备图标（Apple Watch / AirPods / iPhone 等）
    private var deviceIcon: String {
        let name = deviceName
        if name.contains("Watch") { return "applewatch" }
        if name.contains("AirPods") { return "airpods" }
        if name.contains("iPad") { return "ipad" }
        if name.contains("MacBook") || name.contains("Mac") { return "laptopcomputer" }
        if name.contains("iPhone") { return "iphone" }
        return "iphone"
    }

    private var deviceName: String {
        manager.monitoredDeviceName ?? t("mb_no_device")
    }

    private var connectionColor: Color {
        guard manager.connected || manager.monitoredDeviceName != nil else { return .secondary.opacity(0.4) }
        return manager.state.screen == .unlocked ? .green : .blue
    }

    private var signalBarsView: some View {
        let level = signalLevel
        let rssi = fun.effectiveRSSI
        return HStack(spacing: 1.5) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < level.bars(for: rssi) ? level.color : level.color.opacity(0.22))
                    .frame(width: 3, height: 4 + CGFloat(i) * 2)
            }
        }
        .frame(height: 12, alignment: .bottom)
    }

    private var signalText: String {
        let rssi = fun.effectiveRSSI
        guard rssi > -100 else { return "-- dBm" }
        return String(format: "%.0f dBm", rssi)
    }

    private var screenStateText: String {
        switch manager.state.screen {
        case .unlocked: return t("mb_unlocked")
        case .locked, .screensaver, .displaySleeping:
            return manager.connected ? t("mb_locked") : t("mb_disconnected")
        }
    }

    private var screenStateColor: Color {
        switch manager.state.screen {
        case .unlocked: return .green
        case .locked, .screensaver, .displaySleeping:
            return manager.connected ? .orange : .secondary
        }
    }

    // MARK: - 启用开关

    private var enableRow: some View {
        Button {
            enabled.toggle()
        } label: {
            HStack {
                Image(systemName: "power")
                    .font(.system(size: 12))
                    .foregroundColor(enabled ? .green : .secondary)
                Text(t("mb_enable"))
                    .font(.system(size: 13))
                    .foregroundColor(enabled ? .primary : .secondary)
                Spacer()
                // 自定义开关：整行为单个 Button，避免嵌套 Toggle 控件双重触发
                Capsule()
                    .fill(enabled ? Color.green : Color.gray.opacity(0.45))
                    .frame(width: 32, height: 18)
                    .overlay(alignment: enabled ? .trailing : .leading) {
                        Circle()
                            .fill(.white)
                            .frame(width: 14, height: 14)
                            .padding(2)
                    }
                    .animation(.easeInOut(duration: 0.15), value: enabled)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 操作区

    private var actionRows: some View {
        VStack(spacing: 2) {
            Button {
                onAction(.lockNow)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12))
                        .frame(width: 16)
                        .foregroundColor(.red)
                    Text(t("menu_lock_now"))
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            row(icon: "gearshape", title: t("menu_open_settings")) { onAction(.openSettings) }
            row(icon: "key", title: t("menu_change_password")) { onAction(.changePassword) }
            updateRow
            Divider()
                .padding(.vertical, 3)
            // 数据展示类：与上方系统配置类操作分组隔开
            row(icon: "chart.bar", title: t("menu_stats")) { onAction(.showStats) }
        }
        .padding(.vertical, 5)
    }

    private func row(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 16)
                    .foregroundColor(.secondary)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var updateRow: some View {
        Button {
            startUpdateCheck()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: updateIcon)
                    .font(.system(size: 12))
                    .frame(width: 16)
                    .foregroundColor(.secondary)
                Text(updateText)
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                Spacer()
                if case .checking = updateStatus {
                    ProgressView()
                        .controlSize(.small)
                } else if case .downloading(let p) = updateStatus {
                    Text("\(Int(p * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isUpdateInProgress)
    }

    private var isUpdateInProgress: Bool {
        switch updateStatus {
        case .checking, .downloading: return true
        default: return false
        }
    }

    private var updateIcon: String {
        switch updateStatus {
        case .idle, .checking: return "arrow.clockwise"
        case .downloading: return "arrow.down.circle"
        case .latest: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var updateText: String {
        switch updateStatus {
        case .idle: return t("menu_check_update")
        case .checking: return t("menu_checking")
        case .downloading: return t("menu_downloading")
        case .latest: return t("already_latest")
        case .failed: return t("mb_update_failed")
        }
    }

    private func startUpdateCheck() {
        guard updateStatus != .checking else { return }
        updateStatus = .checking
        manager.forceCheckUpdate { version in
            DispatchQueue.main.async {
                guard version == nil else { return }
                self.updateStatus = .latest
                // 有新版：download 自动开始，进度由 onChange(of: updateState) 接管
            }
        }
    }

    // MARK: - 退出

    private var quitRow: some View {
        Button {
            onAction(.quit)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(t("menu_quit"))
                    .font(.system(size: 13))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 动作

enum MenuBarAction {
    case openSettings
    case changePassword
    case checkUpdate
    case lockNow
    case showStats
    case quit
}
