// ConfigSettingsView.swift
import SwiftUI
import UniformTypeIdentifiers

struct ConfigSettingsView: View {
    @ObservedObject var manager: FUnManager
    @StateObject private var profileManager = ProfileManager.shared

    @State private var showAddProfile = false
    @State private var showDeleteProfile = false
    @State private var newProfileName = ""

    var onToast: ((String, String, Color) -> Void)? = nil

    var body: some View {
        ScrollView {
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
                        Divider()
                            .frame(height: 12)
                        Button(action: importProfiles) {
                            Image(systemName: "arrow.down.doc")
                        }
                        Button(action: exportProfiles) {
                            Image(systemName: "arrow.up.doc")
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
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

    // MARK: - 导入/导出

    private func importProfiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let content = try? String(contentsOf: url, encoding: .utf8),
                  let stats = self.profileManager.importFrom(json: content) else {
                self.onToast?(t("profile_import_failed"), "xmark.circle", .red)
                return
            }
            self.onToast?(String(format: t("profile_import_done"), stats.added, stats.updated),
                          "checkmark.circle", .green)
        }
    }

    private func exportProfiles() {
        guard let json = profileManager.exportJSON() else {
            onToast?(t("profile_export_failed"), "xmark.circle", .red)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = t("profile_export_filename")
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try json.write(to: url, atomically: true, encoding: .utf8)
                self.onToast?(t("profile_export_done"), "checkmark.circle", .green)
            } catch {
                self.onToast?(t("profile_export_failed"), "xmark.circle", .red)
            }
        }
    }
}