// BasicSettingsView.swift
import SwiftUI
import ServiceManagement

struct BasicSettingsView: View {
    @AppStorage("enabled", store: ConfigStore.shared.defaults) private var enabled = true
    @AppStorage("launchAtLogin", store: ConfigStore.shared.defaults) private var launchAtLogin = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $enabled) {
                        HStack(spacing: 10) {
                            LiquidIconBadge(icon: "power", color: .green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t("enable"))
                                Text(t("enable_desc")).font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.switch)
                    LiquidDivider()
                    Toggle(isOn: $launchAtLogin) {
                        HStack(spacing: 10) {
                            LiquidIconBadge(icon: "arrow.up.circle", color: .blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t("launch_at_login"))
                                Text(t("launch_at_login_desc")).font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.switch)
                    .onChange(of: launchAtLogin) { _, v in
                        if #available(macOS 13.0, *) {
                            do {
                                if v { try SMAppService.mainApp.register() }
                                else { try SMAppService.mainApp.unregister() }
                            } catch { Log.sm.error("SMAppService error: \(error)") }
                        }
                    }
                }
                .liquidGlassCard(cornerRadius: 16, padding: 14)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
    }
}
