// AutomationView.swift
// 场景自动化配置面板

import SwiftUI
import Combine

struct AutomationView: View {
    @Binding var isPresented: Bool

    private static let eventScriptDir: URL = {
        let dir = try? FileManager.default.url(for: .applicationScriptsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return dir ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FUnlock")
    }()

    private struct EventItem {
        let name: String
        let icon: String
    }

    private let events: [EventItem] = [
        EventItem(name: "away",     icon: "lock.fill"),
        EventItem(name: "lost",     icon: "wifi.slash"),
        EventItem(name: "unlocked", icon: "lock.open.fill"),
        EventItem(name: "intruded", icon: "hand.raised.fill")
    ]

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                Spacer()
                Text(t("automation_title"))
                    .font(.headline)
                Spacer()
                Color.clear.frame(width: 24)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Form {
                Section {
                    ForEach(events, id: \.name) { event in
                        eventRow(event)
                    }
                } footer: {
                    Text(t("automation_hint"))
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 300, height: 300)
    }

    private func eventRow(_ event: EventItem) -> some View {
        let configured = isScriptConfigured()
        return HStack(spacing: 10) {
            Image(systemName: event.icon)
                .font(.body)
                .foregroundColor(configured ? .green : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(t("event_\(event.name)"))
                    .font(.callout)
                Text(configured ? t("automation_configured") : t("automation_not_configured"))
                    .font(.caption)
                    .foregroundColor(configured ? .green : .secondary)
            }

            Spacer()

            Button(action: { openEventDirectory() }) {
                Text(t("automation_setup"))
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
    }

    private func isScriptConfigured() -> Bool {
        let fileURL = Self.eventScriptDir.appendingPathComponent("event")
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir) && !isDir.boolValue
    }

    private func openEventDirectory() {
        let dir = Self.eventScriptDir
        // 确保目录存在
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("event")
        // 如果脚本文件不存在，创建一个示例文件提示用户
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            let example = """
            #!/bin/bash
            # FUnlock event script
            # 参数：$1 = 事件名（away / lost / unlocked / intruded），$2 = RSSI，$3 = 设备名，$4 = 时间戳
            echo "event=$1 rssi=$2 device=$3 time=$4"
            """
            try? example.write(to: fileURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path)
        }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
}
