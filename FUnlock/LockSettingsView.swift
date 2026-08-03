// LockSettingsView.swift
import SwiftUI

struct LockSettingsView: View {
    @AppStorage("pauseItunes") private var pauseItunes = false
    @AppStorage("sleepDisplay") private var sleepDisplay = false
    @AppStorage("lockOnIdle") private var lockOnIdle = true
    @AppStorage("manualLockNoAutoUnlock") private var manualLockNoAutoUnlock = false

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
                    Toggle(isOn: $manualLockNoAutoUnlock) {
                        Label(t("manual_lock_no_auto_unlock"), systemImage: "hand.raised.fill")
                        Text(t("manual_lock_no_auto_unlock_desc")).font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}