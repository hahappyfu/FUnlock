// MainWindowView.swift
// NavigationSplitView 主骨架：分组侧边栏 + 内容区 + sheet 管理

import SwiftUI
import AppKit
import CoreBluetooth
import Combine

// MARK: - Tab 枚举

enum MenuTab: String, CaseIterable {
    case overview   = "overview"
    case basic      = "basic"
    case unlock     = "unlock"
    case lock       = "lock"
    case network    = "network"
    case config     = "config"
    case diagnostics = "diagnostics"

    var icon: String {
        switch self {
        case .overview:  return "gauge.medium"
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

struct MainWindowView: View {
    var manager: FUnManager
    var fun: FUn

    @State private var selectedTab: MenuTab = .overview
    @State private var showCalibration = false
    @State private var showOnboarding = false
    @State private var showAutomation = false
    @State private var showAbout = false
    @State private var showStats = false
    @State private var onboardingStep = 0
    @State private var toastMessage: String? = nil
    @State private var toastIcon = ""
    @State private var toastColor: Color = .green
    /// 当前 toast 的世代标识：连续 showToast 时旧延迟任务据此放弃收尾，避免提前关闭新 toast
    @State private var currentToastID = UUID()
    @State private var previousConnected: Bool? = nil

    @Environment(\.colorScheme) private var colorScheme
    /// 权限状态（仅 UI 展示用，不影响解锁逻辑；权限缺失期间每 5 秒刷新一次）
    @State private var axGranted = false
    @State private var btGranted = false
    /// 权限轮询订阅：仅权限缺失时存活（banner 可见期），授予后停止，不再常驻 Timer
    @State private var permissionPollCancellable: AnyCancellable?

    init(manager: FUnManager, fun: FUn, initialTab: MenuTab = .overview) {
        self.manager = manager
        self.fun = fun
        self._selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selectedTab: $selectedTab, manager: manager)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                if !axGranted || !btGranted {
                    permissionBanner
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                }
                contentView
                    .padding(.bottom, 26)
            }
        }
        .frame(minWidth: 560, minHeight: 460)
        .background {
            ZStack {
                // 超薄材质垫底，硬件加速透射桌面壁纸
                Rectangle().fill(.ultraThinMaterial)
                // 极光自发光网格在毛玻璃之上向视窗内晕染，避免双层 Material 互叠变牛奶白
                LiquidAuroraMesh(opacity: colorScheme == .dark ? 0.25 : 0.50)
                // 晶体表面薄霜（轻微润色，维持极致通透度）
                Color.white.opacity(colorScheme == .dark ? 0.03 : 0.08)
            }
            .ignoresSafeArea()
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
        }
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
                showToast(t("toast_bt_connected"), icon: "antenna.radiowaves.left.and.right", color: .green)
            } else {
                showToast(t("toast_bt_disconnected"), icon: "wifi.slash", color: .orange)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuShowStats)) { _ in
            showStats = true
        }
        .onReceive(DistributedNotificationCenter.default.publisher(for: NSNotification.Name("com.funlock.selectTab"))) { notif in
            if let tabName = notif.object as? String, let tab = MenuTab(rawValue: tabName) {
                withAnimation(.funSpring) {
                    selectedTab = tab
                }
            }
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

    private var bottomBar: some View {
        VStack(spacing: 0) {
            LiquidDivider()
            HStack(spacing: 10) {
                LiquidPillButton(title: t("lock_now"), systemImage: "lock.fill") {
                    manager.lockNow()
                }
                Spacer()
                LiquidPillButton(title: t("quit"), systemImage: "power") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
        .background(Color.white.opacity(colorScheme == .dark ? 0.03 : 0.08))
    }

    @ViewBuilder
    private var contentView: some View {
        switch selectedTab {
        case .overview:
            OverviewView(manager: manager, fun: fun,
                         showCalibration: $showCalibration)
        case .basic:
            BasicSettingsView()
        case .unlock:
            UnlockSettingsView()
        case .lock:
            LockSettingsView()
        case .network:
            NetworkSettingsView(manager: manager)
        case .config:
            ConfigSettingsView(manager: manager, onToast: { message, icon, color in
                self.showToast(message, icon: icon, color: color)
            })
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
            // 已被后续 toast 覆盖：旧任务的到期收尾直接丢弃，交由最新世代的定时器关闭
            guard currentToastID == toastID else { return }
            withAnimation { toastMessage = nil }
        }
    }

    // MARK: - 权限提醒

    /// 权限缺失时的顶部警告条（辅助功能 / 蓝牙），仅当任一权限缺失时显示
    @ViewBuilder
    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !axGranted {
                LiquidAmberBanner(
                    message: t("permission_banner_ax"),
                    hint: t("permission_banner_ax_hint"),
                    actionLabel: t("permission_banner_ax_action")
                ) {
                    openSystemSettingsPane("com.apple.preference.security?Privacy_Accessibility")
                }
            }
            if !btGranted {
                LiquidAmberBanner(
                    message: t("permission_banner_bt"),
                    actionLabel: t("permission_banner_bt_action")
                ) {
                    openSystemSettingsPane("com.apple.preference.security?Privacy_Bluetooth")
                }
            }
        }
    }

    /// 刷新两个权限状态（仅影响警告条显示，不改任何解锁逻辑）
    private func refreshPermissions() {
        axGranted = AXIsProcessTrusted()
        btGranted = (CBManager.authorization == .allowedAlways)
    }

    /// 权限轮询生命周期：缺失时启动 5s 轮询，授予后立即停（辅助功能权限无可靠的变更通知，轮询是缺失期的最小手段）
    private func updatePermissionPolling() {
        let needed = !axGranted || !btGranted
        if needed, permissionPollCancellable == nil {
            // View 为 struct：闭包捕获值拷贝即可，@State 写入走引用语义
            permissionPollCancellable = Timer.publish(every: 5, on: .main, in: .common)
                .autoconnect()
                .sink { _ in refreshPermissions() }
        } else if !needed, let cancellable = permissionPollCancellable {
            cancellable.cancel()
            permissionPollCancellable = nil
        }
    }

    /// 切换侧边栏显示/隐藏（等价于系统 NavigationSplitView 的 toolbar 切换按钮）
    private func toggleSidebar() {
        NSApp.keyWindow?.firstResponder?
            .tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
    }
}
