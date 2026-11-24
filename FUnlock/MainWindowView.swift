// MainWindowView.swift
// 4 分区主骨架：侧边栏 + 内容区 + 权限提示 + 底部操作栏 + Sheet 管理

import SwiftUI
import AppKit
import CoreBluetooth
import Combine

// MARK: - Tab 枚举（4 分区 + 旧 key 兼容路由）

enum MenuTab: String, CaseIterable, Identifiable {
    case overview    = "overview"
    case behavior    = "behavior"
    case scenarios   = "scenarios"
    case diagnostics = "diagnostics"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview:    "gauge.with.dots.needle.bottom.50percent"
        case .behavior:    "switch.2"
        case .scenarios:   "square.stack.3d.up"
        case .diagnostics: "waveform.path.ecg"
        }
    }

    var label: String { t(rawValue) }

    /// 旧版 Tab key（basic/unlock/lock/network/config）继续路由到新分区，
    /// 保证诊断页 `.goToTab` 按钮与外部 DistributedNotification 不会静默失效。
    static func resolve(_ raw: String) -> MenuTab? {
        switch raw {
        case "overview":                       .overview
        case "behavior", "basic", "unlock", "lock": .behavior
        case "scenarios", "network", "config": .scenarios
        case "diagnostics":                    .diagnostics
        default:                               nil
        }
    }
}

struct MainWindowView: View {
    var manager: FUnManager
    var fun: FUn

    @State private var selectedTab: MenuTab = .overview
    @State private var showCalibration = false
    @State private var showOnboarding = false
    @State private var showAbout = false
    @State private var onboardingStep = 0
    @State private var toastMessage: String? = nil
    @State private var toastIcon = ""
    @State private var toastColor: Color = .green
    /// 当前 toast 的世代标识：连续 showToast 时旧延迟任务据此放弃收尾
    @State private var currentToastID = UUID()
    @State private var previousConnected: Bool? = nil

    /// 权限状态（仅 UI 展示，不影响解锁逻辑；缺失期间每 5 秒刷新）
    @State private var axGranted = false
    @State private var btGranted = false
    @State private var permissionPollCancellable: AnyCancellable?

    init(manager: FUnManager, fun: FUn, initialTab: MenuTab = .overview) {
        self.manager = manager
        self.fun = fun
        self._selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
            SidebarView(selectedTab: $selectedTab, manager: manager) {
                showAbout = true
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                if !axGranted || !btGranted {
                    permissionNotices
                        .padding(.horizontal, FUnlockTheme.Space.md)
                        .padding(.top, FUnlockTheme.Space.sm)
                        .padding(.bottom, FUnlockTheme.Space.xs)
                }
                contentView
                    .padding(.bottom, FUnlockTheme.Space.lg)
            }
        }
            bottomBar
        }
        .frame(minWidth: 560, minHeight: 460)
        .background {
            // 精密仪器风：实体画布底，无材质、无极光、无渐变
            FUnlockTheme.Surface.canvas.color.ignoresSafeArea()
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    toggleSidebar()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help(t("sidebar_toggle"))
            }
        }
        .overlay(alignment: .top) {
            if let msg = toastMessage {
                ToastView(message: msg, icon: toastIcon, color: toastColor)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, FUnlockTheme.Space.xs)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: toastMessage)
        .onAppear {
            previousConnected = manager.connected
            refreshPermissions()
            updatePermissionPolling()
            if !ConfigStore.shared.defaults.bool(forKey: "hasCompletedOnboarding") {
                showOnboarding = true
            }
        }
        .onDisappear {
            permissionPollCancellable?.cancel()
            permissionPollCancellable = nil
        }
        .onChange(of: axGranted) { _, _ in updatePermissionPolling() }
        .onChange(of: btGranted) { _, _ in updatePermissionPolling() }
        .onChange(of: manager.connected) { _, connected in
            guard let prev = previousConnected, prev != connected else {
                previousConnected = connected
                return
            }
            previousConnected = connected
            if connected {
                showToast(t("toast_bt_connected"), icon: "antenna.radiowaves.left.and.right", color: FUnlockTheme.State.safeFill.color)
            } else {
                showToast(t("toast_bt_disconnected"), icon: "wifi.slash", color: FUnlockTheme.State.amberFill.color)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuShowStats)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) { selectedTab = .diagnostics }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("com.funlock.bluetoothStateChanged"))) { _ in
            refreshPermissions()
        }
        .onReceive(DistributedNotificationCenter.default.publisher(for: NSNotification.Name("com.funlock.selectTab"))) { notif in
            if let raw = notif.object as? String, let tab = MenuTab.resolve(raw) {
                withAnimation(.easeInOut(duration: 0.2)) { selectedTab = tab }
            }
        }
        .sheet(isPresented: $showCalibration) {
            CalibrationWizardView(manager: manager, isPresented: $showCalibration)
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(step: $onboardingStep, isPresented: $showOnboarding) {
                // 关闭引导后立即打开校准向导
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    showCalibration = true
                }
            }
        }
        .sheet(isPresented: $showAbout) {
            AboutView()
        }
    }

    // MARK: - 底部操作栏

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(spacing: FUnlockTheme.Space.xs) {
                InstrumentButton(title: t("lock_now"), systemImage: "lock.fill",
                                 kind: .destructive) {
                    manager.lockNow()
                }
                Spacer()
                InstrumentButton(title: t("quit"), systemImage: "power",
                                 kind: .secondary) {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.horizontal, FUnlockTheme.Space.md)
            .padding(.vertical, FUnlockTheme.Space.xs)
        }
        .background(FUnlockTheme.Surface.canvas.color)
    }

    // MARK: - 内容

    @ViewBuilder
    private var contentView: some View {
        switch selectedTab {
        case .overview:
            OverviewView(manager: manager, fun: fun, showCalibration: $showCalibration)
        case .behavior:
            BehaviorSettingsView()
        case .scenarios:
            ScenariosSettingsView(manager: manager) { message, icon, color in
                showToast(message, icon: icon, color: color)
            }
        case .diagnostics:
            DiagnosticsView(manager: manager,
                            onNavigate: { selectedTab = $0 })
        }
    }

    func showToast(_ message: String, icon: String, color: Color) {
        toastMessage = message
        toastIcon = icon
        toastColor = color
        let toastID = UUID()
        currentToastID = toastID
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard currentToastID == toastID else { return }
            withAnimation { toastMessage = nil }
        }
    }

    // MARK: - 权限提醒

    @ViewBuilder
    private var permissionNotices: some View {
        VStack(alignment: .leading, spacing: FUnlockTheme.Space.xs) {
            if !axGranted {
                InlineNotice(
                    tone: .warning,
                    title: t("permission_banner_ax"),
                    message: t("permission_banner_ax_hint"),
                    actionTitle: t("permission_banner_ax_action")
                ) {
                    openAccessibilitySettings()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        refreshPermissions()
                    }
                }
            }
            if !btGranted {
                InlineNotice(
                    tone: .warning,
                    title: t("permission_banner_bt"),
                    actionTitle: t("permission_banner_bt_action")
                ) {
                    openBluetoothSettings()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        refreshPermissions()
                    }
                }
            }
        }
    }

    private func refreshPermissions() {
        axGranted = AXIsProcessTrusted()
        let btAuth = (CBManager.authorization == .allowedAlways)
        let btPoweredOn = (fun.centralMgr?.state == .poweredOn)
        btGranted = btAuth || btPoweredOn
    }

    /// 权限轮询生命周期：缺失时启动 5s 轮询，授予后立即停
    private func updatePermissionPolling() {
        let needed = !axGranted || !btGranted
        if needed, permissionPollCancellable == nil {
            permissionPollCancellable = Timer.publish(every: 5, on: .main, in: .common)
                .autoconnect()
                .sink { _ in refreshPermissions() }
        } else if !needed, let cancellable = permissionPollCancellable {
            cancellable.cancel()
            permissionPollCancellable = nil
        }
    }

    private func toggleSidebar() {
        NSApp.keyWindow?.firstResponder?
            .tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
    }
}
