// BarkSettingsCard.swift
// 设置页 Bark 推送通知卡片：开关 / Key 与服务器校验 / 测试按钮 + 行内结果

import SwiftUI

struct BarkSettingsCard: View {
    @AppStorage("barkNotify", store: ConfigStore.shared.defaults) private var barkNotify = false
    @AppStorage("barkNotifyKey", store: ConfigStore.shared.defaults) private var key = ""
    @AppStorage("barkNotifyServer", store: ConfigStore.shared.defaults) private var server = BarkNotifier.Defaults.server
    @State private var isTesting = false
    @State private var testState: TestState = .idle

    private enum TestState {
        case idle
        case success
        case failure(String)
    }

    private var normalizedKey: String {
        BarkNotifier.normalizeKey(key)
    }
    private var normalizedServer: String {
        BarkNotifier.normalizeServer(server)
    }

    /// 即时校验：Key 必填（默认 Key 已移除，为空即无法发送）
    private var keyValid: Bool {
        !normalizedKey.isEmpty
    }
    /// 即时校验：服务器留空走默认官方地址；填写则必须 https://（大小写不敏感，防明文泄漏 Key）
    private var serverValid: Bool {
        BarkNotifier.isValidServer(server)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FUnlockTheme.Space.sm) {
            HStack(spacing: FUnlockTheme.Space.sm) {
                IconTile(systemImage: "bell.badge.fill", tone: .neutral)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("bark_settings_title"))
                        .font(.body)
                        .foregroundStyle(FUnlockTheme.Text.primary.color)
                    Text(t("bark_settings_desc"))
                        .font(.caption)
                        .foregroundStyle(FUnlockTheme.Text.secondary.color)
                }
                Spacer(minLength: FUnlockTheme.Space.xs)
                Toggle("", isOn: $barkNotify)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel(Text(t("bark_settings_title")))
            }

            if barkNotify {
                keyRow
                serverRow
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

    private var keyRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: FUnlockTheme.Space.xs) {
                Text(t("bark_key_label"))
                    .font(.body)
                TextField(t("bark_key_placeholder"), text: $key)
                    .font(.body)
                    .precisionField()
            }
            if !key.isEmpty && !keyValid {
                Text(t("bark_key_invalid"))
                    .font(.caption)
                    .foregroundStyle(FUnlockTheme.State.dangerText.color)
            }
        }
    }

    private var serverRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: FUnlockTheme.Space.xs) {
                Text(t("bark_server_label"))
                    .font(.body)
                TextField(t("bark_server_placeholder"), text: $server)
                    .font(.body)
                    .precisionField()
            }
            if !normalizedServer.isEmpty && !serverValid {
                Text(t("bark_server_https_only"))
                    .font(.caption)
                    .foregroundStyle(FUnlockTheme.State.dangerText.color)
            }
        }
    }

    private var testRow: some View {
        HStack(spacing: FUnlockTheme.Space.xs) {
            InstrumentButton(title: t("bark_send_test"), kind: .secondary,
                             isEnabled: !isTesting && keyValid && serverValid, action: runTest)
            if isTesting {
                ProgressView().controlSize(.small)
            }
            Spacer(minLength: 0)
        }
    }

    private var testStateMessage: String {
        switch testState {
        case .idle: return ""
        case .success: return t("bark_test_success")
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
        guard !isTesting, keyValid, serverValid else { return }
        isTesting = true
        testState = .idle
        // 规范化写回 defaults，保证发送路径读到无空白/无尾斜杠的值
        ConfigStore.shared.set(normalizedKey, forKey: "barkNotifyKey")
        ConfigStore.shared.set(normalizedServer, forKey: "barkNotifyServer")
        let body = IMMessageComposer.compose(.test).body
        BarkNotifier.shared.sendTestNotification(title: t("bark_test_title"), message: body) { result in
            isTesting = false
            switch result {
            case .success:
                testState = .success
            case .failure(let err):
                testState = .failure(err.message)
            }
        }
    }
}
