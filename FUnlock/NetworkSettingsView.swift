// NetworkSettingsView.swift
import SwiftUI

struct NetworkSettingsView: View {
    @ObservedObject var fun: FUn
    @AppStorage("pauseOnWiFi") private var pauseOnWiFi = false
    @AppStorage("pauseOnWiFiSSID") private var pauseOnWiFiSSID = ""
    @AppStorage("passiveMode") private var passiveMode = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $pauseOnWiFi) {
                    Label(t("pause_on_wifi"), systemImage: "wifi")
                    Text(t("pause_on_wifi_desc")).font(.caption).foregroundColor(.secondary)
                }
                if pauseOnWiFi {
                    HStack {
                        Text(t("wifi_ssid"))
                        TextField(t("wifi_ssid_placeholder"), text: $pauseOnWiFiSSID)
                            .textFieldStyle(.roundedBorder)
                        Button(t("current_wifi")) {
                            pauseOnWiFiSSID = WiFiMonitor.shared.currentSSID ?? ""
                        }
                        .controlSize(.small)
                    }
                }
                Toggle(isOn: $passiveMode) {
                    Label(t("passive_mode"), systemImage: "antenna.radiowaves.left.and.right")
                    Text(t("passive_mode_desc")).font(.caption).foregroundColor(.secondary)
                }
                .onChange(of: passiveMode) { v in fun.setPassiveMode(v) }
            }
        }
        .formStyle(.grouped)
    }
}