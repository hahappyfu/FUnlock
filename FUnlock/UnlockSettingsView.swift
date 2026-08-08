// UnlockSettingsView.swift
import SwiftUI

struct UnlockSettingsView: View {
    @AppStorage("wakeOnProximity") private var wakeOnProximity = false
    @AppStorage("wakeWithoutUnlocking") private var wakeWithoutUnlocking = false
    @AppStorage("screensaver") private var useScreensaver = false
    @AppStorage("iMessageNotify") private var iMessageNotify = false
    @AppStorage("iMessageNotifyRecipient") private var iMessageNotifyRecipient = ""
    @State private var isTesting = false
    @State private var showResultAlert = false
    @State private var testSucceeded = false
    @State private var testMessage = ""

    private enum TestKind {
        case lock, unlock

        var emoji: String { self == .lock ? "🔒" : "🔓" }
        var label: String { self == .lock ? "锁定" : "解锁" }
    }

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
                    Toggle(isOn: $iMessageNotify) {
                        Label("iMessage 通知", systemImage: "message.fill")
                        Text("开启后解锁/锁屏时发送 iMessage 到 Apple Watch").font(.caption).foregroundColor(.secondary)
                    }
                    if iMessageNotify {
                        HStack {
                            Text("收件人")
                            TextField("your@apple.id", text: $iMessageNotifyRecipient)
                                .textFieldStyle(.roundedBorder)
                        }
                        if !iMessageNotifyRecipient.isEmpty {
                            HStack {
                                Button("测试锁定") {
                                    runTest(kind: .lock)
                                }
                                .disabled(isTesting)
                                Button("测试解锁") {
                                    runTest(kind: .unlock)
                                }
                                .disabled(isTesting)
                                if isTesting {
                                    ProgressView().controlSize(.small)
                                        .padding(.leading, 4)
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .alert("iMessage 测试", isPresented: $showResultAlert) {
            Button(testSucceeded ? "已收到" : "好") {}
        } message: {
            Text(testSucceeded ? "已发送，请确认 Apple Watch 是否收到" : testMessage)
        }
    }

    private func runTest(kind: TestKind) {
        guard !isTesting else { return }
        isTesting = true
        let title = "\(kind.emoji) Funlock 手动测试：\(kind.label)"
        let message = "请确认 Apple Watch 是否收到"
        iMessageNotifier.shared.sendTestNotification(title: title, message: message) { result in
            isTesting = false
            switch result {
            case .success:
                testSucceeded = true
            case .failure(let err):
                testSucceeded = false
                testMessage = err.message
            }
            showResultAlert = true
        }
    }
}