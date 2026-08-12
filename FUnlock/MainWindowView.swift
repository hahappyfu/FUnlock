// MainWindowView.swift
// NavigationSplitView 主骨架：分组侧边栏 + 内容区 + sheet 管理

import SwiftUI
import AppKit

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
                .padding(.bottom, 26)
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
            if !ConfigStore.shared.defaults.bool(forKey: "hasCompletedOnboarding") {
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

    /// 切换侧边栏显示/隐藏（等价于系统 NavigationSplitView 的 toolbar 切换按钮）
    private func toggleSidebar() {
        NSApp.keyWindow?.firstResponder?
            .tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
    }
}
