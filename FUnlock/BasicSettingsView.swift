// BasicSettingsView.swift
import SwiftUI
import ServiceManagement

struct BasicSettingsView: View {
    @AppStorage("enabled") private var enabled = true
    @AppStorage("launchAtLogin") private var launchAtLogin = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $enabled) {
                    Label(t("enable"), systemImage: "power")
                    Text(t("enable_desc")).font(.caption).foregroundColor(.secondary)
                }
                Toggle(isOn: $launchAtLogin) {
                    Label(t("launch_at_login"), systemImage: "arrow.up.circle")
                    Text(t("launch_at_login_desc")).font(.caption).foregroundColor(.secondary)
                }
                .onChange(of: launchAtLogin) { v in
                    if #available(macOS 13.0, *) {
                        do {
                            if v { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch { Log.sm.debug("SMAppService error: \(error)") }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}