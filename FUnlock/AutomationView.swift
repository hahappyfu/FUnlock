// AutomationView.swift
// 场景自动化配置面板

import SwiftUI
import Combine

struct AutomationView: View {
    @Binding var isPresented: Bool

    private static let eventScriptDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleId = Bundle.main.bundleIdentifier ?? "com.fuhahah.FUnlock"
        return appSupport.appendingPathComponent("\(bundleId)/event")
    }()

    private struct EventItem {
        let name: String
        let icon: String
        let fileName: String
    }

    private let events: [EventItem] = [
        EventItem(name: "away",   icon: "lock.fill",        fileName: "away"),
        EventItem(name: "lost",   icon: "wifi.slash",       fileName: "lost"),
        EventItem(name: "unlocked", icon: "lock.open.fill", fileName: "unlocked"),
        EventItem(name: "intruded", icon: "hand.raised.fill", fileName: "intruded")
    ]

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
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

            Divider()

            // 事件列表
            VStack(spacing: 0) {
                ForEach(events, id: \.name) { event in
                    if event.name != events.first?.name {
                        Divider().padding(.leading, 44)
                    }
                    eventRow(event)
                }
            }
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(10)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            // 说明文字
            Text(t("automation_hint"))
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            Spacer()
        }
        .frame(width: 300, height: 300)
        .background(.regularMaterial)
    }

    private func eventRow(_ event: EventItem) -> some View {
        let configured = isScriptConfigured(event.fileName)
        return HStack(spacing: 10) {
            Image(systemName: event.icon)
                .font(.system(size: 14))
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

            Button(action: { openEventDirectory(event.fileName) }) {
                Text(t("automation_setup"))
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func isScriptConfigured(_ fileName: String) -> Bool {
        let fileURL = Self.eventScriptDir.appendingPathComponent(fileName)
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir) && !isDir.boolValue
    }

    private func openEventDirectory(_ eventName: String) {
        let dir = Self.eventScriptDir
        // 确保目录存在
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent(eventName)
        // 如果脚本文件不存在，创建一个空的示例文件提示用户
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            let example = "#!/bin/bash\n# \(eventName) event script\n# Add your commands here\n\n"
            try? example.write(to: fileURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path)
        }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
}
