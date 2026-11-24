// SidebarView.swift
// 4 分区侧边栏：顶部状态徽标 + 设备/信号，底部版本条（恢复关于入口）

import SwiftUI

struct SidebarView: View {
    @Binding var selectedTab: MenuTab
    var manager: FUnManager
    var onOpenAbout: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            List {
                ForEach(MenuTab.allCases) { tab in
                    SidebarRow(tab: tab, isSelected: selectedTab == tab) {
                        selectedTab = tab
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            versionBar
        }
        .background(FUnlockTheme.Surface.sidebar.color)
    }

    // MARK: - 顶部状态

    private var presentation: StatusPresentation {
        StatusPresentation.resolve(screen: manager.state.screen,
                                   connected: manager.connected,
                                   hasDevice: manager.monitoredDeviceName != nil)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            StatusBadge(presentation: presentation, onElevatedSurface: true)
            HStack(spacing: 6) {
                Text(manager.monitoredDeviceName ?? t("no_device"))
                    .font(.callout)
                    .foregroundStyle(FUnlockTheme.Text.primary.color)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(manager.rssi.map { "\($0) dBm" } ?? "-- dBm")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(FUnlockTheme.Text.secondary.color)
            }
        }
        .padding(.horizontal, FUnlockTheme.Space.sm)
        .padding(.top, FUnlockTheme.Space.sm)
        .padding(.bottom, FUnlockTheme.Space.xs)
    }

    // MARK: - 行

    private struct SidebarRow: View {
        let tab: MenuTab
        let isSelected: Bool
        let action: () -> Void

        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            Button(action: action) {
                HStack(spacing: FUnlockTheme.Space.xs) {
                    Image(systemName: tab.icon)
                        .font(.callout)
                        .foregroundStyle(isSelected ? FUnlockTheme.Accent.base.color
                                                    : FUnlockTheme.Text.secondary.color)
                        .frame(width: 18)
                    Text(tab.label)
                        .font(.body.weight(isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? FUnlockTheme.Text.primary.color
                                                    : FUnlockTheme.Text.secondary.color)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, FUnlockTheme.Space.xs)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: FUnlockTheme.Radius.md)
                        .fill(isSelected ? FUnlockTheme.Accent.base.color.opacity(0.12) : .clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .animation(reduceMotion ? nil : FUnlockTheme.Motion.fast, value: isSelected)
        }
    }

    // MARK: - 版本条

    private var versionBar: some View {
        Button(action: onOpenAbout) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.caption)
                Text("FUnlock \(versionString)")
                    .font(.caption.monospacedDigit())
                Spacer(minLength: 0)
            }
            .foregroundStyle(FUnlockTheme.Text.secondary.color)
            .padding(.horizontal, FUnlockTheme.Space.sm)
            .padding(.vertical, FUnlockTheme.Space.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { Hairline() }
        .accessibilityLabel(Text(t("about_funlock")))
    }

    private var versionString: String {
        guard let info = Bundle.main.infoDictionary,
              let version = info["CFBundleShortVersionString"] as? String,
              let build = info["CFBundleVersion"] as? String else { return "" }
        return "\(version) (\(build))"
    }
}
