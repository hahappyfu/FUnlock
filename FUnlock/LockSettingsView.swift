// LockSettingsView.swift
import SwiftUI

struct LockSettingsView: View {
    @AppStorage("pauseItunes", store: ConfigStore.shared.defaults) private var pauseItunes = false
    @AppStorage("sleepDisplay", store: ConfigStore.shared.defaults) private var sleepDisplay = false
    @AppStorage("lockOnIdle", store: ConfigStore.shared.defaults) private var lockOnIdle = true

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $pauseItunes) {
                        HStack(spacing: 10) {
                            LiquidIconBadge(icon: "pause.circle", color: .pink)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t("pause_on_lock"))
                                Text(t("pause_on_lock_desc")).font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.switch)
                    LiquidDivider()
                    Toggle(isOn: $sleepDisplay) {
                        HStack(spacing: 10) {
                            LiquidIconBadge(icon: "moon.fill", color: .purple)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t("sleep_display_on_lock"))
                                Text(t("sleep_display_on_lock_desc")).font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.switch)
                    LiquidDivider()
                    Toggle(isOn: $lockOnIdle) {
                        HStack(spacing: 10) {
                            LiquidIconBadge(icon: "keyboard", color: .orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t("defer_lock_on_input"))
                                Text(t("defer_lock_on_input_desc")).font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.switch)
                }
                .liquidGlassCard(cornerRadius: 16, padding: 14)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
    }
}
