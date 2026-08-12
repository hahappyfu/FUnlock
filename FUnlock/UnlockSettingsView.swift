// UnlockSettingsView.swift
import SwiftUI

struct UnlockSettingsView: View {
    @AppStorage("wakeOnProximity", store: ConfigStore.shared.defaults) private var wakeOnProximity = false
    @AppStorage("wakeWithoutUnlocking", store: ConfigStore.shared.defaults) private var wakeWithoutUnlocking = false
    @AppStorage("screensaver", store: ConfigStore.shared.defaults) private var useScreensaver = false

    var body: some View {
        ScrollView {
            Form {
                Section {
                    Toggle(isOn: $wakeOnProximity) {
                        Label(t("wake_on_proximity"), systemImage: "display")
                        Text(t("wake_on_proximity_desc")).font(.caption).foregroundColor(.secondary)
                    }
                    Toggle(isOn: $wakeWithoutUnlocking) {
                        Label(t("wake_without_unlock"), systemImage: "lock.open")
                        Text(t("wake_without_unlock_desc")).font(.caption).foregroundColor(.secondary)
                    }
                    Toggle(isOn: $useScreensaver) {
                        Label(t("use_screensaver"), systemImage: "sparkles.tv")
                        Text(t("use_screensaver_desc")).font(.caption).foregroundColor(.secondary)
                    }
                }
                Section {
                    IMSettingsCard()
                }
            }
            .formStyle(.grouped)
        }
    }
}