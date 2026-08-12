// LockSettingsView.swift
import SwiftUI

struct LockSettingsView: View {
    @AppStorage("pauseItunes", store: ConfigStore.shared.defaults) private var pauseItunes = false
    @AppStorage("sleepDisplay", store: ConfigStore.shared.defaults) private var sleepDisplay = false
    @AppStorage("lockOnIdle", store: ConfigStore.shared.defaults) private var lockOnIdle = true

    var body: some View {
        ScrollView {
            Form {
                Section {
                    Toggle(isOn: $pauseItunes) {
                        Label(t("pause_on_lock"), systemImage: "pause.circle")
                        Text(t("pause_on_lock_desc")).font(.caption).foregroundColor(.secondary)
                    }
                    Toggle(isOn: $sleepDisplay) {
                        Label(t("sleep_display_on_lock"), systemImage: "moon.fill")
                        Text(t("sleep_display_on_lock_desc")).font(.caption).foregroundColor(.secondary)
                    }
                    Toggle(isOn: $lockOnIdle) {
                        Label(t("defer_lock_on_input"), systemImage: "keyboard")
                        Text(t("defer_lock_on_input_desc")).font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}