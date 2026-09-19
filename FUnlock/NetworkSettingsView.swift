// NetworkSettingsView.swift
import SwiftUI
import AppKit

struct NetworkSettingsView: View {
    @ObservedObject var fun: FUn
    @AppStorage("pauseOnWiFi", store: ConfigStore.shared.defaults) private var pauseOnWiFi = false
    @AppStorage("pauseOnWiFiSSID", store: ConfigStore.shared.defaults) private var pauseOnWiFiSSID = ""
    @AppStorage("passiveMode", store: ConfigStore.shared.defaults) private var passiveMode = false

    /// 「使用当前 Wi-Fi」按钮的反馈文案（拿不到 SSID 时说明原因）
    @State private var wifiHint: String? = nil

    var body: some View {
        ScrollView {
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
                                fillCurrentWiFi()
                            }
                            .controlSize(.small)
                        }
                        if let hint = wifiHint {
                            Text(hint)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
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

    // MARK: - 读取当前 Wi-Fi

    /// 先确保定位授权（macOS 读 SSID 的前提），再取 SSID；失败时给出原因提示。
    private func fillCurrentWiFi() {
        wifiHint = nil
        NSApp.activate(ignoringOtherApps: true)
        WiFiMonitor.shared.requestLocationIfNeeded { granted in
            guard granted else {
                wifiHint = t("wifi_need_location")
                return
            }
            guard let ssid = WiFiMonitor.shared.currentSSID, !ssid.isEmpty else {
                wifiHint = t("wifi_unavailable")
                return
            }
            pauseOnWiFiSSID = ssid
            wifiHint = nil
        }
    }
}