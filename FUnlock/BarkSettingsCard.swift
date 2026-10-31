// BarkSettingsCard.swift
// 设置页 Bark 推送通知卡片：开关 / Key 与服务器配置校验 / 单个测试按钮 + 行内结果

import SwiftUI

struct BarkSettingsCard: View {
    @AppStorage("barkNotify", store: ConfigStore.shared.defaults) private var barkNotify = false
    @AppStorage("barkNotifyKey", store: ConfigStore.shared.defaults) private var key = BarkNotifier.Defaults.key
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

    /// 即时校验：Key 非空即可（send 路径另有 Defaults 回退）
    private var keyValid: Bool {
        !normalizedKey.isEmpty
    }
    /// 即时校验：服务器留空走默认官方地址；填写则必须 https://（明文 http 会泄漏 Key）
    private var serverValid: Bool {
        normalizedServer.isEmpty || normalizedServer.hasPrefix("https://")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $barkNotify) {
                HStack(spacing: 10) {
                    LiquidIconBadge(icon: "bell.badge.fill", color: .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("bark_settings_title"))
                        Text(t("bark_settings_desc")).font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            .toggleStyle(.switch)
            if barkNotify {
                keyRow
                serverRow
                LiquidDivider()
                testRow
                if !testStateMessage.isEmpty {
                    Text(testStateMessage)
                        .font(.caption)
                        .foregroundColor(testStateColor)
                }
            }
        }
    }

    // MARK: - 子视图

    private var keyRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(t("bark_key_label"))
                TextField(t("bark_key_placeholder"), text: $key)
                    .textFieldStyle(.plain)
                    .liquidInputField()
            }
            if !key.isEmpty && !keyValid {
                Text(t("bark_key_invalid"))
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }

    private var serverRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(t("bark_server_label"))
                TextField(t("bark_server_placeholder"), text: $server)
                    .textFieldStyle(.plain)
                    .liquidInputField()
            }
            if !normalizedServer.isEmpty && !serverValid {
                Text(t("bark_server_https_only"))
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }

    private var testRow: some View {
        HStack {
            Button(t("bark_send_test")) {
                runTest()
            }
            .disabled(isTesting || !keyValid || !serverValid)
            if isTesting {
                ProgressView().controlSize(.small)
                    .padding(.leading, 4)
            }
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
        case .success: return .green
        case .failure: return .red
        case .idle: return .secondary
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
