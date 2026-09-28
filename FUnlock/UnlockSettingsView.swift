// UnlockSettingsView.swift
import SwiftUI

struct UnlockSettingsView: View {
    @AppStorage("wakeOnProximity", store: ConfigStore.shared.defaults) private var wakeOnProximity = false
    @AppStorage("wakeWithoutUnlocking", store: ConfigStore.shared.defaults) private var wakeWithoutUnlocking = false
    @AppStorage("screensaver", store: ConfigStore.shared.defaults) private var useScreensaver = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $wakeOnProximity) {
                        HStack(spacing: 10) {
                            LiquidIconBadge(icon: "display", color: .cyan)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t("wake_on_proximity"))
                                Text(t("wake_on_proximity_desc")).font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.switch)
                    LiquidDivider()
                    Toggle(isOn: $wakeWithoutUnlocking) {
                        HStack(spacing: 10) {
                            LiquidIconBadge(icon: "lock.open", color: .teal)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t("wake_without_unlock"))
                                Text(t("wake_without_unlock_desc")).font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.switch)
                    LiquidDivider()
                    Toggle(isOn: $useScreensaver) {
                        HStack(spacing: 10) {
                            LiquidIconBadge(icon: "sparkles.tv", color: .indigo)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t("use_screensaver"))
                                Text(t("use_screensaver_desc")).font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.switch)
                }
                .liquidGlassCard(cornerRadius: 16, padding: 14)

                // iMessage 通知卡：独立晶体卡片
                IMSettingsCard()
                    .liquidGlassCard(cornerRadius: 16, padding: 14)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
    }
}
