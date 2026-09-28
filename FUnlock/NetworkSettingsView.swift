// NetworkSettingsView.swift
import SwiftUI
import AppKit

struct NetworkSettingsView: View {
    var manager: FUnManager
    @AppStorage("pauseOnWiFi", store: ConfigStore.shared.defaults) private var pauseOnWiFi = false
    @AppStorage("pauseOnWiFiSSID", store: ConfigStore.shared.defaults) private var pauseOnWiFiSSID = ""
    @AppStorage("passiveMode", store: ConfigStore.shared.defaults) private var passiveMode = false

    /// 「使用当前 Wi-Fi」按钮的反馈文案（拿不到 SSID 时说明原因）
    @State private var wifiHint: String? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $pauseOnWiFi) {
                        HStack(spacing: 10) {
                            LiquidIconBadge(icon: "wifi", color: .blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t("pause_on_wifi"))
                                Text(t("pause_on_wifi_desc")).font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.switch)
                    if pauseOnWiFi {
                        LiquidDivider()
                        // 输入槽与右侧胶囊按钮在同一 HStack 中，默认 center 对齐确保中轴严格对齐
                        HStack(alignment: .center, spacing: 8) {
                            Text(t("wifi_ssid"))
                            TextField(t("wifi_ssid_placeholder"), text: $pauseOnWiFiSSID)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, design: .monospaced))
                                .liquidInputField()
                                .frame(maxWidth: .infinity)
                            LiquidPillButton(title: t("current_wifi"), systemImage: "wifi") {
                                fillCurrentWiFi()
                            }
                        }
                        if let hint = wifiHint {
                            Text(hint)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    LiquidDivider()
                    Toggle(isOn: $passiveMode) {
                        HStack(spacing: 10) {
                            LiquidIconBadge(icon: "antenna.radiowaves.left.and.right", color: .purple)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t("passive_mode"))
                                Text(t("passive_mode_desc")).font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.switch)
                    .onChange(of: passiveMode) { _, v in manager.setPassiveMode(v) }
                }
                .liquidGlassCard(cornerRadius: 16, padding: 14)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 12)
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
