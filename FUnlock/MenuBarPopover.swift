// MenuBarPopover.swift
// 状态栏菜单（NSPopover + SwiftUI）：现代质感的信息卡 + 快捷操作
// 8 项功能 1:1 契约见 docs/superpowers/specs/2026-09-24-modern-observation-design.md 第 3 节

import SwiftUI

// MARK: - 动作

enum MenuBarAction {
    case openSettings, changePassword, checkUpdate, lockNow, showStats, quit
}

// MARK: - 视图

struct MenuBarPopoverView: View {
    var manager: FUnManager
    var fun: FUn
    let onAction: (MenuBarAction) -> Void

    @AppStorage("enabled", store: ConfigStore.shared.defaults) private var enabled = true
    @State private var updateStatus: UpdateStatus = .idle
    @State private var breathing = false

    enum UpdateStatus: Equatable {
        case idle, checking, downloading(Double), latest, failed
    }

    var body: some View {
        VStack(spacing: 0) {
            statusCard.padding(EdgeInsets(top: 12, leading: 12, bottom: 10, trailing: 12))
            Divider()
            enableRow
            Divider()
            actionRows
            Divider()
            quitRow
        }
        .frame(width: 282)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
        .onAppear { syncUpdateStatus() }
        .onChange(of: manager.updateState) { _, _ in syncUpdateStatus() }
    }

    /// 下载器状态同步到 5 态状态机（onAppear 恢复现场 + onChange 实时跟踪进度）
    private func syncUpdateStatus() {
        switch manager.updateState {
        case .downloading(let p): updateStatus = .downloading(p)
        case .completed: updateStatus = .latest
        case .failed: updateStatus = .failed
        default: break
        }
    }

    // MARK: 功能 1：设备状态英雄卡

    /// 信号档位：RSSI > -60 极佳；-75 ~ -60 良好；< -75 较弱
    enum SignalLevel: String, Equatable {
        case excellent, good, weak

        var main: String { t("mb_signal_\(rawValue)") }

        var proximity: String {
            switch self {
            case .excellent: return t("mb_signal_very_close")
            case .good: return t("mb_signal_close")
            case .weak: return t("mb_signal_far")
            }
        }

        /// 信号格数：档位内按子档细分（越近格数越多）
        func bars(for rssi: Double) -> Int {
            self == .excellent ? 5 : self == .good ? (rssi > -67 ? 4 : 3) : (rssi > -82 ? 2 : 1)
        }
    }

    /// 按有效 RSSI 分档（单测锁定 -60 / -75 边界）
    static func signalLevel(for rssi: Double) -> SignalLevel {
        rssi > -60 ? .excellent : (rssi > -75 ? .good : .weak)
    }

    static func signalBars(for rssi: Double) -> Int { signalLevel(for: rssi).bars(for: rssi) }

    /// 信号展示统一走快照，避免跨线程直读 fun.effectiveRSSI
    private var rssiSnapshot: Double { fun.signalSnapshot().effectiveRSSI }

    private var signalLevel: SignalLevel { Self.signalLevel(for: rssiSnapshot) }

    /// 与总览「无信号」同源判据：manager.rssi 在失联 3 次超时后被置 nil
    private var hasSignal: Bool { manager.rssi != nil }

    private var statusCard: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(LinearGradient(colors: [.blue.opacity(0.85), .indigo.opacity(0.85)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: deviceIcon)
                    .font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 0) {
                Text(deviceName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                HStack(spacing: 7) {
                    if hasSignal {
                        signalBarsView
                        Text("\(signalLevel.main) (\(signalLevel.proximity))")
                            .font(.system(size: 12, weight: .medium)).foregroundColor(.green)
                    } else {
                        Text(t("mb_signal_lost"))
                            .font(.system(size: 12, weight: .medium)).foregroundColor(.orange)
                    }
                    Spacer(minLength: 4)
                    statusDot
                    Text(screenStatus.text)
                        .font(.system(size: 10, weight: .semibold)).foregroundColor(screenStatus.color)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(screenStatus.color.opacity(0.12), in: Capsule())
                        .animation(.funSpring, value: screenStatus.text)
                }
                .padding(.top, 4)
                Text(signalText).font(.system(size: 10)).foregroundColor(.secondary).padding(.top, 2)
            }
        }
    }

    /// 屏幕状态三态：解锁（绿，呼吸）/ 锁定（橙）/ 失联（灰）
    private var screenStatus: (text: String, color: Color, alive: Bool) {
        switch manager.state.screen {
        case .unlocked: (t("mb_unlocked"), .green, true)
        case .locked, .screensaver, .displaySleeping:
            manager.connected ? (t("mb_locked"), .orange, false) : (t("mb_disconnected"), .secondary, false)
        }
    }

    /// 生命圆点：解锁/连接时 1.8s 周期呼吸微光（opacity 0.7→1.0, scale 0.95→1.15），失联褪为静止灰
    private var statusDot: some View {
        let breathe = Animation.easeInOut(duration: 0.9).repeatForever(autoreverses: true)
        return Circle()
            .fill(screenStatus.color)
            .frame(width: 7, height: 7)
            .shadow(color: screenStatus.color.opacity(breathing ? 0.9 : 0.25), radius: breathing ? 4.5 : 1.5)
            .scaleEffect(breathing ? 1.15 : 0.95)
            .opacity(breathing ? 1.0 : 0.7)
            .onAppear {
                guard screenStatus.alive else { return }
                withAnimation(breathe) { breathing = true }
            }
            .onChange(of: screenStatus.alive) { _, alive in
                withAnimation(alive ? breathe : .easeInOut(duration: 0.4)) { breathing = alive }
            }
    }

    /// 按设备名推断设备图标（Apple Watch / AirPods / iPhone 等）
    private var deviceIcon: String { deviceIconName(for: deviceName) }

    private var deviceName: String { manager.monitoredDeviceName ?? t("mb_no_device") }

    /// 5 格指示柱：填充透明度随档位平滑插值，避免频繁跳动闪烁
    private var signalBarsView: some View {
        let count = Self.signalBars(for: rssiSnapshot)
        return HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.green.opacity(i < count ? 1 : 0.2))
                    .frame(width: 4, height: 4 + CGFloat(i) * 2)
            }
        }
        .frame(height: 12, alignment: .bottom)
        .animation(.funSpring, value: count)
    }

    /// 信号数值文本：失联（manager.rssi == nil）或有效信号低于无信号档时显示 "-- dBm"
    static func signalText(effectiveRSSI: Double, hasSignal: Bool) -> String {
        guard hasSignal, effectiveRSSI > -100 else { return "-- dBm" }
        return String(format: "%.0f dBm", effectiveRSSI)
    }

    private var signalText: String { Self.signalText(effectiveRSSI: rssiSnapshot, hasSignal: hasSignal) }

    // MARK: 功能 2：自动解锁总开关（整行为单按钮，避免嵌套 Toggle 双重触发）

    private var enableRow: some View {
        MenuRowButton(icon: "power",
                      iconColor: enabled ? .green : .secondary,
                      title: t("mb_enable"),
                      titleColor: enabled ? .primary : .secondary,
                      hoverTint: .primary,
                      trailing: AnyView(Capsule()
                          .fill(enabled ? Color.green : Color.gray.opacity(0.45))
                          .frame(width: 32, height: 18)
                          .overlay(alignment: enabled ? .trailing : .leading) {
                              Circle().fill(.white).frame(width: 14, height: 14).padding(2)
                          })) {
            withAnimation(.funSpring) { enabled.toggle() }
        }
    }

    // MARK: 功能 3-7：设置 / 密码 / 更新 / 统计 / 锁屏

    private var actionRows: some View {
        VStack(spacing: 2) {
            MenuRowButton(icon: "gearshape", iconColor: .secondary, title: t("menu_open_settings"),
                          titleColor: .primary, hoverTint: .primary, shortcut: (",", .command, "⌘,")) {
                onAction(.openSettings)
            }
            MenuRowButton(icon: "key", iconColor: .secondary, title: t("menu_change_password"),
                          titleColor: .primary, hoverTint: .primary) {
                onAction(.changePassword)
            }
            MenuRowButton(icon: updateIcon, iconColor: updateIconColor, title: updateText,
                          titleColor: .primary, hoverTint: .primary,
                          trailing: AnyView(updateTrailing), disabled: isUpdateInProgress) {
                startUpdateCheck()
            }
            Divider().padding(.vertical, 3)
            // 数据展示与危险操作：与上方系统配置类分组隔开
            MenuRowButton(icon: "chart.bar", iconColor: .secondary, title: t("menu_stats"),
                          titleColor: .primary, hoverTint: .primary, shortcut: ("s", .command, "⌘S")) {
                onAction(.showStats)
            }
            MenuRowButton(icon: "lock.fill", iconColor: .red, title: t("menu_lock_now"),
                          titleColor: .red, hoverTint: .red, shortcut: ("q", [.command, .control], "⌃⌘Q")) {
                onAction(.lockNow)
            }
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var updateTrailing: some View {
        switch updateStatus {
        case .checking: ProgressView().controlSize(.small)
        case .downloading(let p):
            Text("\(Int(p * 100))%")
                .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
        default: EmptyView()
        }
    }

    private var isUpdateInProgress: Bool {
        switch updateStatus {
        case .checking, .downloading: true
        default: false
        }
    }

    private var updateIcon: String {
        switch updateStatus {
        case .idle, .checking: "arrow.clockwise"
        case .downloading: "arrow.down.circle"
        case .latest: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var updateIconColor: Color {
        switch updateStatus {
        case .latest: .green
        case .failed: .red
        default: .secondary
        }
    }

    private var updateText: String {
        switch updateStatus {
        case .idle: t("menu_check_update")
        case .checking: t("menu_checking")
        case .downloading: t("menu_downloading")
        case .latest: t("already_latest")
        case .failed: t("mb_update_failed")
        }
    }

    private func startUpdateCheck() {
        guard updateStatus != .checking else { return }
        withAnimation(.funSpring) { updateStatus = .checking }
        manager.forceCheckUpdate { version in
            DispatchQueue.main.async {
                guard version == nil else { return }
                withAnimation(.funSpring) { updateStatus = .latest }
                // 有新版：download 自动开始，进度由 onChange(of: updateState) 接管
            }
        }
    }

    // MARK: 功能 8：退出

    private var quitRow: some View {
        MenuRowButton(icon: "rectangle.portrait.and.arrow.right", iconColor: .primary,
                      title: t("menu_quit"), titleColor: .primary, hoverTint: .primary,
                      shortcut: ("q", .command, "⌘Q")) {
            onAction(.quit)
        }
    }
}
