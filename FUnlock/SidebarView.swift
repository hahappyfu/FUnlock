// SidebarView.swift
// 分组侧边栏：常用 / 设置 / 诊断

import SwiftUI

struct SidebarView: View {
    @Binding var selectedTab: MenuTab
    @ObservedObject var manager: FUnManager

    private enum SidebarGroup: String, CaseIterable {
        case common = "sidebar_group_common"
        case settings = "sidebar_group_settings"
        case diagnostics = "sidebar_group_diagnostics"

        var tabs: [MenuTab] {
            switch self {
            case .common: return [.overview, .lock, .unlock]
            case .settings: return [.basic, .network, .config]
            case .diagnostics: return [.diagnostics]
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            deviceStatusRow
            List(selection: $selectedTab) {
                ForEach(SidebarGroup.allCases, id: \.self) { group in
                    Section(t(group.rawValue)) {
                        ForEach(group.tabs, id: \.self) { tab in
                            Label(tab.label, systemImage: tab.icon)
                                .tag(tab)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var deviceStatusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(manager.monitoredDeviceName ?? t("no_device"))
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }

    private var statusColor: Color {
        switch manager.state.screen {
        case .unlocked: return .green
        case .locked: return .orange
        case .screensaver: return .yellow
        case .displaySleeping: return .gray
        }
    }
}