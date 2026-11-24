// MenuBarPopover.swift
// 状态栏菜单（NSPopover + SwiftUI）：精密仪器风信息卡 + 8 项快捷操作
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
    /// 弹窗可见性：NSPopover 的 hosting view 常驻，靠 onAppear/onDisappear 区分开/关，
    /// 用于停掉离屏期间空转的无限动画
    @State private var popoverVisible = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum UpdateStatus: Equatable {
        case idle, checking, downloading(Double), latest, failed
    }

    var body: some View {
        VStack(spacing: 0) {
            statusCard
            Hairline()
            enableRow
            Hairline()
            actionRows
            Hairline()
            quitRow
                .padding(.bottom, 4)
        }
        .frame(width: 282)
        .background(FUnlockTheme.Surface.card.color)
        .clipShape(RoundedRectangle(cornerRadius: FUnlockTheme.Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: FUnlockTheme.Radius.lg)
                .strokeBorder(FUnlockTheme.Surface.border.color, lineWidth: 1)
        )
        .onAppear {
            syncUpdateStatus()
            popoverVisible = true
            syncBreathing(visible: true)
        }
        .onDisappear {
            popoverVisible = false
            syncBreathing(visible: false)
        }
        // transient popover 点外部关闭只做窗口 orderOut，视图树常驻导致 onDisappear 不触发，
        // 故监听 AppKit 系统通知启停呼吸动画（本进程仅此一个 NSPopover，无需按 object 过滤）；
        // didShow 兜住再次弹出时 onAppear 不重放的问题
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.didCloseNotification)) { _ in
            popoverVisible = false
            syncBreathing(visible: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.didShowNotification)) { _ in
            popoverVisible = true
            syncBreathing(visible: true)
        }
        .onChange(of: manager.updateState) { _, _ in syncUpdateStatus() }
        .onChange(of: reduceMotion) { _, _ in syncBreathing(visible: popoverVisible) }
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

    // MARK: - 统一状态语义

    private var presentation: StatusPresentation {
        StatusPresentation.resolve(screen: manager.state.screen,
                                   connected: manager.connected,
                                   hasDevice: manager.monitoredDeviceName != nil)
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

    private var deviceName: String { manager.monitoredDeviceName ?? t("mb_no_device") }

    /// 按设备名推断设备图标（Apple Watch / AirPods / iPhone 等）
    private var deviceIcon: String { deviceIconName(for: deviceName) }

    private var statusCard: some View {
        HStack(spacing: FUnlockTheme.Space.xs) {
            IconTile(systemImage: deviceIcon, tone: presentation.tone, size: 32)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    statusDot
                    Text(deviceName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(FUnlockTheme.Text.primary.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                        // 优先占用弹性空间，剩余才交给 Spacer，避免设备名被过早截断
                        .layoutPriority(1)
                    Spacer(minLength: 6)
                    StatusBadge(presentation: presentation, onElevatedSurface: true)
                        .fixedSize()
                }
                signalRow
            }
        }
        .padding(FUnlockTheme.Space.sm)
        .background(
            RoundedRectangle(cornerRadius: FUnlockTheme.Radius.md)
                .fill(FUnlockTheme.Surface.well.color)
        )
        .padding(FUnlockTheme.Space.sm)
    }

    private var signalRow: some View {
        HStack(spacing: 6) {
            Text(t("signal_quality_label"))
                .font(.caption2)
                .foregroundStyle(FUnlockTheme.Text.tertiary.color)
            if hasSignal {
                signalBarsView
                Text(signalLevel.main)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(signalLevel == .weak
                                     ? FUnlockTheme.State.amberText.color
                                     : FUnlockTheme.State.safeText.color)
            } else {
                Text(t("mb_signal_lost"))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(FUnlockTheme.State.amberText.color)
            }
            Spacer(minLength: 6)
            // 信号 dBm 数据：等宽字体确保数据权威性
            Text(signalText)
                .font(.caption2.monospacedDigit().weight(.medium))
                .foregroundStyle(FUnlockTheme.Text.secondary.color)
        }
    }

    /// 生命圆点：仅安全在场且弹窗可见时呼吸（Reduce Motion 下静止）
    private var statusDot: some View {
        Circle()
            .fill(presentation.tone.fillColor)
            .frame(width: 7, height: 7)
            .scaleEffect(breathing ? 1.15 : 0.95)
            .opacity(breathing ? 1.0 : 0.7)
            .onAppear { syncBreathing(visible: popoverVisible) }
            .onChange(of: presentation.tone) { _, _ in syncBreathing(visible: popoverVisible) }
            .accessibilityHidden(true)
    }

    /// 呼吸动画启停同步：仅在安全在场、弹窗可见且未开启 Reduce Motion 时运行
    private func syncBreathing(visible: Bool) {
        let shouldBreathe = presentation.tone == .safe && visible && !reduceMotion
        withAnimation(shouldBreathe
            ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
            : .easeInOut(duration: 0.2)) {
            breathing = shouldBreathe
        }
    }

    /// 5 格指示柱：填充透明度随档位平滑插值，避免频繁跳动闪烁
    private var signalBarsView: some View {
        let count = Self.signalBars(for: rssiSnapshot)
        return HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(i < count ? FUnlockTheme.State.safeFill.color
                                    : FUnlockTheme.Text.primary.color.opacity(0.12))
                    .frame(width: 4, height: 4 + CGFloat(i) * 2)
            }
        }
        .frame(height: 12, alignment: .bottom)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: count)
        .accessibilityHidden(true)
    }

    /// 信号数值文本：失联（manager.rssi == nil）或有效信号低于无信号档时显示 "-- dBm"
    static func signalText(effectiveRSSI: Double, hasSignal: Bool) -> String {
        guard hasSignal, effectiveRSSI > -100 else { return "-- dBm" }
        return String(format: "%.0f dBm", effectiveRSSI)
    }

    private var signalText: String { Self.signalText(effectiveRSSI: rssiSnapshot, hasSignal: hasSignal) }

    // MARK: 功能 2：自动解锁总开关（整行为单按钮，避免嵌套 Toggle 双重触发）

    private var enableRow: some View {
        ControlRow(
            icon: "power",
            tone: enabled ? .safe : .neutral,
            title: t("mb_enable"),
            trailing: AnyView(capsuleToggle)
        ) {
            withAnimation(reduceMotion ? nil : FUnlockTheme.Motion.fast) { enabled.toggle() }
        }
        // 自绘 Capsule 滑轨对读屏器不可见：把「开关」语义与当前档位补到整行按钮上
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(enabled ? t("mb_switch_on") : t("mb_switch_off"))
    }

    private var capsuleToggle: some View {
        Capsule()
            .fill(enabled ? FUnlockTheme.State.safeFill.color
                          : FUnlockTheme.Text.tertiary.color.opacity(0.35))
            .frame(width: 32, height: 18)
            .overlay(Capsule().strokeBorder(FUnlockTheme.Surface.border.color, lineWidth: 1))
            .overlay(alignment: enabled ? .trailing : .leading) {
                Circle()
                    .fill(FUnlockTheme.Surface.card.color)
                    .frame(width: 14, height: 14)
                    .padding(2)
            }
    }

    // MARK: 功能 3-7：设置 / 密码 / 更新 / 统计 / 锁屏

    private var actionRows: some View {
        VStack(spacing: 2) {
            ControlRow(icon: "gearshape", title: t("menu_open_settings"),
                       shortcut: "⌘,", keyShortcut: (",", .command)) {
                onAction(.openSettings)
            }
            ControlRow(icon: "key", title: t("menu_change_password")) {
                onAction(.changePassword)
            }
            ControlRow(icon: updateIcon, tone: updateTone, title: updateText,
                       trailing: AnyView(updateTrailing), isEnabled: !isUpdateInProgress) {
                startUpdateCheck()
            }
            Hairline()
            // 数据展示与危险操作：与上方系统配置类分组隔开
            ControlRow(icon: "chart.bar", title: t("menu_stats"),
                       shortcut: "⌘S", keyShortcut: ("s", .command)) {
                onAction(.showStats)
            }
            ControlRow(icon: "lock.fill", tone: .danger, title: t("menu_lock_now"),
                       shortcut: "⌃⌘Q", keyShortcut: ("q", [.command, .control])) {
                onAction(.lockNow)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var updateTrailing: some View {
        switch updateStatus {
        case .checking: ProgressView().controlSize(.small)
        case .downloading(let p):
            Text("\(Int(p * 100))%")
                .font(.caption2.monospacedDigit()).foregroundStyle(FUnlockTheme.Text.secondary.color)
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

    private var updateTone: StatusTone {
        switch updateStatus {
        case .latest: .safe
        case .failed: .danger
        default: .neutral
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
        withAnimation(reduceMotion ? nil : FUnlockTheme.Motion.fast) { updateStatus = .checking }
        manager.forceCheckUpdateResult { result in
            switch result {
            case .available:
                // 有新版：download 自动开始，进度由 onChange(of: updateState) 接管
                break
            case .upToDate:
                withAnimation(reduceMotion ? nil : FUnlockTheme.Motion.fast) { updateStatus = .latest }
            case .failed:
                withAnimation(reduceMotion ? nil : FUnlockTheme.Motion.fast) { updateStatus = .failed }
            }
        }
    }

    // MARK: 功能 8：退出

    private var quitRow: some View {
        ControlRow(icon: "rectangle.portrait.and.arrow.right", title: t("menu_quit"),
                   shortcut: "⌘Q", keyShortcut: ("q", .command)) {
            onAction(.quit)
        }
    }
}
