// MainWindowView.swift
// NavigationSplitView 主骨架：分组侧边栏 + 内容区 + sheet 管理

import SwiftUI

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
        }
        .frame(minWidth: 560, minHeight: 420)
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
            if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
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
            ConfigSettingsView(manager: manager)
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
}
