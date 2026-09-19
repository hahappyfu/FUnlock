// ConfigSettingsView.swift
import SwiftUI
import UniformTypeIdentifiers

struct ConfigSettingsView: View {
    @ObservedObject var manager: FUnManager
    @StateObject private var profileManager = ProfileManager.shared

    @State private var showAddProfile = false
    @State private var showDeleteProfile = false
    @State private var newProfileName = ""
    @State private var showImportAllConfirm = false
    @State private var pendingImportJSON: String? = nil

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

                Section {
                    HStack {
                        Text(t("settings_backup_title"))
                            .font(.callout)
                        Spacer()
                        Button(t("settings_export_all")) { exportAllSettings() }
                        Button(t("settings_import_all")) { importAllSettings() }
                    }
                    Text(t("settings_backup_desc"))
                        .font(.caption)
                        .foregroundColor(.secondary)
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
        .alert(t("settings_import_all_confirm"), isPresented: $showImportAllConfirm) {
            Button(t("ok"), role: .destructive) { applyPendingImport() }
            Button(t("cancel"), role: .cancel) { pendingImportJSON = nil }
        } message: {
            Text(t("settings_import_all_confirm_desc"))
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

    // MARK: - 全量设置导出/导入

    private func exportAllSettings() {
        guard let json = ConfigStore.shared.exportAllSettings() else {
            onToast?(t("profile_export_failed"), "xmark.circle", .red)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = t("settings_export_filename")
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try json.write(to: url, atomically: true, encoding: .utf8)
                self.onToast?(t("settings_export_done"), "checkmark.circle", .green)
            } catch {
                self.onToast?(t("profile_export_failed"), "xmark.circle", .red)
            }
        }
    }

    private func importAllSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let content = try? String(contentsOf: url, encoding: .utf8) else { return }
            self.pendingImportJSON = content
            self.showImportAllConfirm = true
        }
    }

    /// 确认替换后落盘：写入全部 key，再重载内存态（档位、阈值、Wi-Fi 暂停等）
    private func applyPendingImport() {
        guard let json = pendingImportJSON else { return }
        pendingImportJSON = nil
        guard let stats = ConfigStore.shared.importAllSettings(json: json) else {
            onToast?(t("settings_import_failed"), "xmark.circle", .red)
            return
        }
        profileManager.load()
        // 阈值以导入文件为准（applyActiveProfile 可能按 default 档位改写并落盘）。
        // 先 setUnlockRSSI（会联动 lock），再用导入的 lock 值覆盖，保证两者都还原。
        manager.setUnlockRSSI(ConfigStore.shared.get("unlockRSSI", fallback: manager.unlockRSSI))
        manager.setLockRSSI(ConfigStore.shared.get("lockRSSI", fallback: manager.lockRSSI))
        onToast?(String(format: t("settings_import_done"), stats.applied),
                 "checkmark.circle", .green)
    }
}