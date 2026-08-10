// IMSettingsCard.swift
// 设置页 iMessage 通知卡片：开关 / 收件人校验 / 授权状态 / 单个测试按钮 + 行内结果

import SwiftUI

struct IMSettingsCard: View {
    @AppStorage("iMessageNotify") private var iMessageNotify = false
    @AppStorage("iMessageNotifyRecipient") private var recipient = ""
    @State private var isTesting = false
    @State private var testState: TestState = .idle

    private enum TestState {
        case idle
        case success
        case failure(String)
    }

    /// 收件人规范化结果（用于校验与发送）
    private var normalizedRecipient: String {
        IMMessageComposer.normalizeRecipient(recipient)
    }

    /// 即时校验：手机号（10-15 位纯数字）或邮箱
    private var recipientValid: Bool {
        let r = normalizedRecipient
        guard !r.isEmpty else { return false }
        if r.contains("@") {
            let parts = r.split(separator: "@")
            return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".")
        }
        return r.count >= 10 && r.count <= 15 && r.allSatisfy(\.isNumber)
    }

    var body: some View {
        Toggle(isOn: $iMessageNotify) {
            Label(t("im_settings_title"), systemImage: "message.fill")
            Text(t("im_settings_desc")).font(.caption).foregroundColor(.secondary)
        }
        if iMessageNotify {
            recipientRow
            authorizationRow
            Divider()
            testRow
            if !testStateMessage.isEmpty {
                Text(testStateMessage)
                    .font(.caption)
                    .foregroundColor(testStateColor)
            }
        }
    }

    // MARK: - 子视图

    private var recipientRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(t("im_recipient_label"))
                TextField(t("im_recipient_placeholder"), text: $recipient)
                    .textFieldStyle(.roundedBorder)
            }
            if !recipient.isEmpty && !recipientValid {
                Text(t("im_recipient_invalid"))
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }

    private var authorizationRow: some View {
        HStack {
            if case .failure(let msg) = testState, msg.contains("授权") {
                Text(t("im_unauthorized"))
                    .foregroundColor(.red)
                Spacer()
                Button(t("im_go_authorize")) {
                    openAutomationSettings()
                }
            } else {
                Text(t("im_authorized"))
                    .foregroundColor(.green)
            }
        }
    }

    private var testRow: some View {
        HStack {
            Button(t("im_send_test")) {
                runTest()
            }
            .disabled(isTesting || !recipientValid)
            if isTesting {
                ProgressView().controlSize(.small)
                    .padding(.leading, 4)
            }
        }
    }

    private var testStateMessage: String {
        switch testState {
        case .idle: return ""
        case .success: return t("im_test_success")
        case .failure(let msg): return msg
        }
    }

    private var testStateColor: Color {
        switch testState {
        case .success: return .green
        case .failure: return .red
        case .idle: return .secondary
        }
    }

    // MARK: - 动作

    private func runTest() {
        guard !isTesting, recipientValid else { return }
        isTesting = true
        testState = .idle
        // 规范化收件人写回 defaults，保证 AppleScript 使用国际格式
        UserDefaults.standard.set(normalizedRecipient, forKey: "iMessageNotifyRecipient")
        let (title, body) = IMMessageComposer.compose(.test)
        iMessageNotifier.shared.sendTestNotification(title: title, message: body) { result in
            isTesting = false
            switch result {
            case .success:
                testState = .success
            case .failure(let err):
                testState = .failure(err.message)
            }
        }
    }

    private func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
}
