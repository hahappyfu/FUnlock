// ScenariosSettingsView.swift
// Tab 3：场景与配置 —— 网络 / 多配置档 / 全量备份 / 事件脚本（恢复原不可达入口）
// 规格：docs/superpowers/specs/2026-11-24-precision-instrument-ui-redesign-spec.md §4.4

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ScenariosSettingsView: View {
    var manager: FUnManager
    var onToast: ((String, String, Color) -> Void)? = nil

    @AppStorage("pauseOnWiFi", store: ConfigStore.shared.defaults) private var pauseOnWiFi = false
    @AppStorage("pauseOnWiFiSSID", store: ConfigStore.shared.defaults) private var pauseOnWiFiSSID = ""
    @AppStorage("passiveMode", store: ConfigStore.shared.defaults) private var passiveMode = false

    @State private var profileManager = ProfileManager.shared
    @State private var showAddProfile = false
    @State private var showDeleteProfile = false
    @State private var newProfileName = ""
    @State private var showImportAllConfirm = false
    @State private var pendingImportJSON: String? = nil
    @State private var wifiHint: String? = nil
    @State private var scriptConfigured = false

    private struct EventItem: Identifiable {
        let name: String
        let icon: String
        var id: String { name }
    }

    private let events: [EventItem] = [
        EventItem(name: "away", icon: "lock.fill"),
        EventItem(name: "lost", icon: "wifi.slash"),
        EventItem(name: "unlocked", icon: "lock.open.fill"),
        EventItem(name: "intruded", icon: "hand.raised.fill")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FUnlockTheme.Space.sm) {
                networkCard
                profilesCard
                backupCard
                automationCard
            }
            .padding(.horizontal, FUnlockTheme.Space.md)
            .padding(.top, FUnlockTheme.Space.sm)
            .padding(.bottom, FUnlockTheme.Space.lg)
        }
        .onAppear { refreshScriptStatus() }
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

    // MARK: - 网络

    private var networkCard: some View {
        FUnlockCard {
            VStack(alignment: .leading, spacing: FUnlockTheme.Space.sm) {
                PrecisionToggleRow(icon: "wifi", tone: .neutral,
                                   title: t("pause_on_wifi"), subtitle: t("pause_on_wifi_desc"),
                                   isOn: $pauseOnWiFi)
                if pauseOnWiFi {
                    Hairline()
                    HStack(spacing: FUnlockTheme.Space.xs) {
                        Text(t("wifi_ssid"))
                            .font(.body)
                        TextField(t("wifi_ssid_placeholder"), text: $pauseOnWiFiSSID)
                            .font(.body.monospaced())
                            .precisionField()
                            .frame(maxWidth: .infinity)
                        InstrumentButton(title: t("current_wifi"), systemImage: "wifi",
                                         kind: .secondary, action: fillCurrentWiFi)
                    }
                    if let hint = wifiHint {
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(FUnlockTheme.Text.secondary.color)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                Hairline()
                PrecisionToggleRow(icon: "antenna.radiowaves.left.and.right", tone: .neutral,
                                   title: t("passive_mode"), subtitle: t("passive_mode_desc"),
                                   isOn: $passiveMode) { value in
                    manager.setPassiveMode(value)
                }
            }
        }
    }

    // MARK: - 配置档

    private var profilesCard: some View {
        FUnlockCard {
            VStack(alignment: .leading, spacing: FUnlockTheme.Space.sm) {
                Picker(t("profile"), selection: $profileManager.activeProfileID) {
                    ForEach(profileManager.profiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                .onChange(of: profileManager.activeProfileID) { _, id in
                    profileManager.setActive(id)
                    profileManager.applyActiveProfile(to: manager)
                }
                Hairline()
                HStack(spacing: FUnlockTheme.Space.xs) {
                    Spacer(minLength: 0)
                    InstrumentButton(title: t("profile_add"), systemImage: "plus", kind: .secondary) {
                        newProfileName = ""
                        showAddProfile = true
                    }
                    if profileManager.activeProfileID != "default" {
                        InstrumentButton(title: t("profile_delete"), systemImage: "trash",
                                         kind: .destructive) {
                            showDeleteProfile = true
                        }
                    }
                    InstrumentButton(title: t("profile_import"), systemImage: "arrow.down.doc",
                                     kind: .secondary, action: importProfiles)
                    InstrumentButton(title: t("profile_export"), systemImage: "arrow.up.doc",
                                     kind: .secondary, action: exportProfiles)
                }
            }
        }
    }

    // MARK: - 备份

    private var backupCard: some View {
        FUnlockCard {
            VStack(alignment: .leading, spacing: FUnlockTheme.Space.sm) {
                HStack(spacing: FUnlockTheme.Space.xs) {
                    Text(t("settings_backup_title"))
                        .font(.body)
                        .foregroundStyle(FUnlockTheme.Text.primary.color)
                    Spacer(minLength: 0)
                    InstrumentButton(title: t("settings_export_all"), kind: .secondary,
                                     action: exportAllSettings)
                    InstrumentButton(title: t("settings_import_all"), kind: .secondary,
                                     action: importAllSettings)
                }
                Hairline()
                Text(t("settings_backup_desc"))
                    .font(.caption)
                    .foregroundStyle(FUnlockTheme.Text.secondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 事件脚本（单卡，修复原 4 行共读同一文件的缺陷）

    private var automationCard: some View {
        FUnlockCard {
            VStack(alignment: .leading, spacing: FUnlockTheme.Space.sm) {
                HStack(spacing: FUnlockTheme.Space.xs) {
                    IconTile(systemImage: "terminal", tone: scriptConfigured ? .safe : .neutral)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("automation_title"))
                            .font(.body)
                            .foregroundStyle(FUnlockTheme.Text.primary.color)
                        Text(scriptConfigured ? t("automation_configured") : t("automation_not_configured"))
                            .font(.caption)
                            .foregroundStyle(scriptConfigured
                                             ? FUnlockTheme.State.safeText.color
                                             : FUnlockTheme.Text.secondary.color)
                    }
                    Spacer(minLength: FUnlockTheme.Space.xs)
                    InstrumentButton(title: t("automation_open_folder"), systemImage: "folder",
                                     kind: .secondary, action: openEventDirectory)
                }
                Text(t("automation_hint"))
                    .font(.caption)
                    .foregroundStyle(FUnlockTheme.Text.secondary.color)
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                    GridItem(.flexible(), alignment: .leading)],
                          spacing: FUnlockTheme.Space.xs) {
                    ForEach(events) { event in
                        eventTag(event)
                    }
                }
            }
        }
    }

    private func eventTag(_ event: EventItem) -> some View {
        HStack(spacing: 6) {
            Image(systemName: event.icon)
                .font(.caption)
                .foregroundStyle(FUnlockTheme.Text.secondary.color)
                .frame(width: 14)
            Text(t("event_\(event.name)"))
                .font(.caption)
                .foregroundStyle(FUnlockTheme.Text.primary.color)
            Spacer(minLength: 4)
            Text("$1=\(event.name)")
                .font(.caption2.monospaced())
                .foregroundStyle(FUnlockTheme.Text.tertiary.color)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: FUnlockTheme.Radius.sm)
                .fill(FUnlockTheme.Surface.well.color)
        )
    }

    // MARK: - Wi-Fi

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

    // MARK: - 配置档导入导出

    private func importProfiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            // 用户取消：静默返回，不弹红色错误
            guard response == .OK, let url = panel.url else { return }
            guard let content = try? String(contentsOf: url, encoding: .utf8),
                  let stats = profileManager.importFrom(json: content) else {
                onToast?(t("profile_import_failed"), "xmark.circle", .red)
                return
            }
            onToast?(String(format: t("profile_import_done"), stats.added, stats.updated),
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
                onToast?(t("profile_export_done"), "checkmark.circle", .green)
            } catch {
                onToast?(t("profile_export_failed"), "xmark.circle", .red)
            }
        }
    }

    // MARK: - 全量备份

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
                onToast?(t("settings_export_done"), "checkmark.circle", .green)
            } catch {
                onToast?(t("profile_export_failed"), "xmark.circle", .red)
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
            pendingImportJSON = content
            showImportAllConfirm = true
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
        // 阈值以导入文件为准：先 setUnlockRSSI（会联动 lock），再用导入的 lock 覆盖
        manager.setUnlockRSSI(ConfigStore.shared.get("unlockRSSI", fallback: manager.unlockRSSI))
        manager.setLockRSSI(ConfigStore.shared.get("lockRSSI", fallback: manager.lockRSSI))
        onToast?(String(format: t("settings_import_done"), stats.applied),
                 "checkmark.circle", .green)
    }

    // MARK: - 事件脚本目录

    /// 与旧 AutomationView 同源：Application Scripts 下唯一的 event 文件
    private static let eventScriptDir: URL = {
        let dir = try? FileManager.default.url(for: .applicationScriptsDirectory,
                                               in: .userDomainMask, appropriateFor: nil, create: true)
        return dir ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FUnlock")
    }()

    private var eventScriptURL: URL {
        Self.eventScriptDir.appendingPathComponent("event")
    }

    private func refreshScriptStatus() {
        var isDir: ObjCBool = false
        scriptConfigured = FileManager.default.fileExists(atPath: eventScriptURL.path, isDirectory: &isDir)
            && !isDir.boolValue
    }

    private func openEventDirectory() {
        try? FileManager.default.createDirectory(at: Self.eventScriptDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: eventScriptURL.path) {
            let example = """
            #!/bin/bash
            # FUnlock event script
            # 参数：$1 = 事件名（away / lost / unlocked / intruded），$2 = RSSI，$3 = 设备名，$4 = 时间戳
            echo "event=$1 rssi=$2 device=$3 time=$4"
            """
            try? example.write(to: eventScriptURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: eventScriptURL.path)
        }
        refreshScriptStatus()
        NSWorkspace.shared.activateFileViewerSelecting([eventScriptURL])
    }
}
