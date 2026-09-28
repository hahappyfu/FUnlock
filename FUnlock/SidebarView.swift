// SidebarView.swift
// 分组侧边栏：常用 / 设置 / 诊断

import SwiftUI

struct SidebarView: View {
    @Binding var selectedTab: MenuTab
    var manager: FUnManager

    @Environment(\.colorScheme) private var colorScheme

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
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 6)
            List {
                ForEach(SidebarGroup.allCases, id: \.self) { group in
                    Section(t(group.rawValue)) {
                        ForEach(group.tabs, id: \.self) { tab in
                            SidebarRow(tab: tab, isSelected: selectedTab == tab, colorScheme: colorScheme) {
                                selectedTab = tab
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            // 让全视窗极光底座直接贯透侧边栏，消除与主内容区之间的生硬接缝
            .scrollContentBackground(.hidden)
        }
    }

    /// 手绘晶体胶囊行：绕开原生 List selection 的选中底色（死黑方块），选中态由自绘高亮呈现
    private struct SidebarRow: View {
        let tab: MenuTab
        let isSelected: Bool
        let colorScheme: ColorScheme
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: tab.icon)
                        .font(.system(size: 13))
                        .foregroundColor(isSelected ? .accentColor : .secondary)
                        .shadow(color: isSelected ? Color.accentColor.opacity(0.5) : .clear, radius: 3)
                        .frame(width: 18)
                    Text(tab.label)
                        .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                        .foregroundColor(isSelected ? .primary : .secondary)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected
                              ? Color.accentColor.opacity(colorScheme == .dark ? 0.25 : 0.15)
                              : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            isSelected
                                ? LinearGradient(colors: [Color.white.opacity(0.65), Color.accentColor.opacity(0.35)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing)
                                : LinearGradient(colors: [.clear, .clear],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 0.8
                        )
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// 设备状态微胶囊：半透白底 + 0.6px 白光高光环 + 发光状态原点，设备名保持高对比
    private var deviceStatusRow: some View {
        HStack(spacing: 8) {
            statusDot
            Text(manager.monitoredDeviceName ?? t("no_device"))
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.22))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.34 : 0.72),
                            Color.white.opacity(0.10),
                            Color.white.opacity(colorScheme == .dark ? 0.16 : 0.30)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.6
                )
        )
    }

    /// 状态原点：微发光纯色原点（静态微投影，无常驻循环动画消耗电池）
    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
            .shadow(color: statusColor.opacity(manager.state.screen == .unlocked ? 0.6 : 0.2), radius: 2.5)
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