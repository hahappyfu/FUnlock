// ConfigSettingsView.swift
import SwiftUI

struct ConfigSettingsView: View {
    @ObservedObject var manager: FUnManager
    @StateObject private var profileManager = ProfileManager.shared

    @State private var showAddProfile = false
    @State private var showDeleteProfile = false
    @State private var newProfileName = ""

    var body: some View {
        Form {
            Section {
                Picker(t("profile"), selection: $profileManager.activeProfileID) {
                    ForEach(profileManager.profiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                .onChange(of: profileManager.activeProfileID) { id in
                    profileManager.setActive(id)
                    profileManager.applyActiveProfile(to: manager)
                }

                HStack {
                    Spacer()
                    Button {
                        newProfileName = ""
                        showAddProfile = true
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    if profileManager.activeProfileID != "default" {
                        Button { showDeleteProfile = true } label: {
                            Image(systemName: "minus.circle")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .alert(t("profile_add"), isPresented: $showAddProfile) {
            TextField(t("profile_name_placeholder"), text: $newProfileName)
            Button(t("ok")) {
                guard !newProfileName.isEmpty else { return }
                profileManager.saveCurrentAsProfile(
                    name: newProfileName,
                    lockRSSI: manager.lockRSSI,
                    unlockRSSI: manager.unlockRSSI
                )
            }
            Button(t("cancel"), role: .cancel) {}
        } message: {
            Text(t("profile_add_hint"))
        }
        .alert(t("profile_delete_confirm"), isPresented: $showDeleteProfile) {
            Button(t("ok"), role: .destructive) {
                let id = profileManager.activeProfileID
                profileManager.activeProfileID = "default"
                profileManager.deleteProfile(id: id)
                profileManager.applyActiveProfile(to: manager)
            }
            Button(t("cancel"), role: .cancel) {}
        } message: {
            Text(t("profile_delete_hint"))
        }
    }
}