// MainWindowView.swift
// NavigationSplitView 主骨架：分组侧边栏 + 内容区 + sheet 管理

import SwiftUI
import AppKit
import CoreBluetooth

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
    @ObservedObject var manager: FUnManager
    @ObservedObject var fun: FUn

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
    @State private var previousConnected: Bool? = nil

    /// 权限状态（仅 UI 展示用，不影响解锁逻辑；每 5 秒刷新一次）
    @State private var axGranted = false
    @State private var btGranted = false

    var body: some View {
        NavigationSplitView {
            SidebarView(selectedTab: $selectedTab, manager: manager)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                if !axGranted || !btGranted {
                    permissionBanner
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                }
                contentView
                    .padding(.bottom, 26)
            }
        }
        .frame(minWidth: 560, minHeight: 460)
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
            HStack {
                Button {
                    manager.lockNow()
                } label: {
                    Label(t("lock_now"), systemImage: "lock.fill")
                        .controlSize(.small)
                }
                Spacer()
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label(t("quit"), systemImage: "power")
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
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
            if !ConfigStore.shared.defaults.bool(forKey: "hasCompletedOnboarding") {
                showOnboarding = true
            }
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            refreshPermissions()
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
            NetworkSettingsView(fun: fun)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation { toastMessage = nil }
        }
    }

    // MARK: - 权限提醒

    /// 权限缺失时的顶部警告条（辅助功能 / 蓝牙），仅当任一权限缺失时显示
    @ViewBuilder
    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !axGranted {
                bannerRow(
                    message: t("permission_banner_ax"),
                    hint: t("permission_banner_ax_hint"),
                    action: { openSystemSettingsPane("com.apple.preference.security?Privacy_Accessibility") },
                    actionLabel: t("permission_banner_ax_action")
                )
            }
            if !btGranted {
                bannerRow(
                    message: t("permission_banner_bt"),
                    hint: nil,
                    action: { openSystemSettingsPane("com.apple.preference.security?Privacy_Bluetooth") },
                    actionLabel: t("permission_banner_bt_action")
                )
            }
        }
    }

    /// 单条权限提示：警告图标 + 文案（可选小字提示）+ 前往设置按钮
    private func bannerRow(message: String, hint: String?, action: @escaping () -> Void, actionLabel: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(message)
                    .font(.callout)
                if let hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            Button(actionLabel, action: action)
                .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }

    /// 刷新两个权限状态（仅影响警告条显示，不改任何解锁逻辑）
    private func refreshPermissions() {
        axGranted = AXIsProcessTrusted()
        btGranted = (CBManager.authorization == .allowedAlways)
    }

    /// 切换侧边栏显示/隐藏（等价于系统 NavigationSplitView 的 toolbar 切换按钮）
    private func toggleSidebar() {
        NSApp.keyWindow?.firstResponder?
            .tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
    }
}
