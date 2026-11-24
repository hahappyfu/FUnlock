// IMSettingsCard.swift
// 设置页 iMessage 通知卡片：开关 / 收件人校验 / 授权状态 / 测试按钮 + 行内结果

import SwiftUI

struct IMSettingsCard: View {
    @AppStorage("iMessageNotify", store: ConfigStore.shared.defaults) private var iMessageNotify = false
    @AppStorage("iMessageNotifyRecipient", store: ConfigStore.shared.defaults) private var recipient = ""
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
        let digits = r.hasPrefix("+") ? String(r.dropFirst()) : r
        return digits.count >= 10 && digits.count <= 15 && digits.allSatisfy(\.isNumber)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FUnlockTheme.Space.sm) {
            HStack(spacing: FUnlockTheme.Space.sm) {
                IconTile(systemImage: "message.fill", tone: .neutral)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("im_settings_title"))
                        .font(.body)
                        .foregroundStyle(FUnlockTheme.Text.primary.color)
                    Text(t("im_settings_desc"))
                        .font(.caption)
                        .foregroundStyle(FUnlockTheme.Text.secondary.color)
                }
                Spacer(minLength: FUnlockTheme.Space.xs)
                Toggle("", isOn: $iMessageNotify)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel(Text(t("im_settings_title")))
            }

            if iMessageNotify {
                recipientRow
                authorizationRow
                Hairline()
                testRow
                if !testStateMessage.isEmpty {
                    Text(testStateMessage)
                        .font(.caption)
                        .foregroundStyle(testStateColor)
                }
            }
        }
    }

    // MARK: - 子视图

    private var recipientRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: FUnlockTheme.Space.xs) {
                Text(t("im_recipient_label"))
                    .font(.body)
                TextField(t("im_recipient_placeholder"), text: $recipient)
                    .font(.body)
                    .precisionField()
            }
            if !recipient.isEmpty && !recipientValid {
                Text(t("im_recipient_invalid"))
                    .font(.caption)
                    .foregroundStyle(FUnlockTheme.State.dangerText.color)
            }
        }
    }

    private var authorizationRow: some View {
        HStack(spacing: FUnlockTheme.Space.xs) {
            if case .failure(let msg) = testState, msg.contains("授权") {
                Text(t("im_unauthorized"))
                    .font(.caption)
                    .foregroundStyle(FUnlockTheme.State.dangerText.color)
                Spacer(minLength: 0)
                InstrumentButton(title: t("im_go_authorize"), kind: .secondary,
                                 action: openAutomationSettings)
            } else {
                Text(t("im_authorized"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(FUnlockTheme.State.safeText.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(FUnlockTheme.State.safeFill.color.opacity(0.12)))
                    .overlay(Capsule().strokeBorder(FUnlockTheme.State.safeFill.color.opacity(0.28),
                                                    lineWidth: 1))
                Spacer(minLength: 0)
            }
        }
    }

    private var testRow: some View {
        HStack(spacing: FUnlockTheme.Space.xs) {
            InstrumentButton(title: t("im_send_test"), kind: .secondary,
                             isEnabled: !isTesting && recipientValid, action: runTest)
            if isTesting {
                ProgressView().controlSize(.small)
            }
            Spacer(minLength: 0)
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
        case .success: return FUnlockTheme.State.safeText.color
        case .failure: return FUnlockTheme.State.dangerText.color
        case .idle: return FUnlockTheme.Text.secondary.color
        }
    }

    // MARK: - 动作

    private func runTest() {
        guard !isTesting, recipientValid else { return }
        isTesting = true
        testState = .idle
        // 规范化收件人写回 defaults，保证 AppleScript 使用国际格式
        ConfigStore.shared.set(normalizedRecipient, forKey: "iMessageNotifyRecipient")
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
