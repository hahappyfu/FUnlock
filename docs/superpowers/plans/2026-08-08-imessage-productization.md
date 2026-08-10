# 实现计划：iMessage 通知产品化

- 日期：2026-08-08
- 关联规格：`docs/superpowers/specs/2026-08-08-imessage-productization-design.md`（已批准）
- 分支：feat/diagnostics-tab
- 测试基线：358 通过
- 验证命令：`xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' test`

## 执行模式

每个任务由 implementer 子代理执行（TDD：先写/改测试 → 实现 → 跑该测试类通过 → 主控 review 后 commit）。任务间按依赖顺序执行。

## 文件结构

| 文件 | 状态 | 说明 |
|------|------|------|
| `FUnlock/IMMessageComposer.swift` | 新建 | 纯函数：事件 → (title, body)、normalizeRecipient |
| `FUnlock/iMessageNotifier.swift` | 修改 | 事件 API：send(_:)、防抖按类型、保留 scriptRunner/parseScriptError/friendlyError |
| `FUnlock/FUnManager.swift` | 修改 | 第 408/702 行两处调用改为事件 API |
| `FUnlock/IMSettingsCard.swift` | 新建 | 设置页卡片（开关/收件人/授权状态/测试按钮/行内结果） |
| `FUnlock/UnlockSettingsView.swift` | 修改 | iMessage 区块替换为 IMSettingsCard |
| `FUnlockTests/IMMessageComposerTests.swift` | 新建 | 文案/时间/降级/normalizeRecipient 测试 |
| `FUnlockTests/iMessageNotifierTests.swift` | 修改 | 适配事件 API，新增防抖/静默失败测试 |
| `FUnlock/Base.lproj/Localizable.strings` + 7 语言 | 修改 | 新增 iMessage key |

## 任务 1：IMMessageComposer（纯函数）

新建 `FUnlock/IMMessageComposer.swift` 与 `FUnlockTests/IMMessageComposerTests.swift`。

```swift
enum IMEvent {
    case locked(reason: String, rssi: Double?, deviceName: String?)
    case unlocked(rssi: Double?, deviceName: String?)
    case test
}

enum IMMessageComposer {
    static func compose(_ event: IMEvent) -> (title: String, body: String)
    static func normalizeRecipient(_ raw: String) -> String
}
```

要点：
- `normalizeRecipient`：去空格/`-`/`+` 前缀；若为纯数字且以 86 开头、共 13 位则保留；`+86 138-1234 5678 → 8613812345678`；邮箱原样返回（去首尾空白）
- 文案全部经 `t("im_...")` 取（key 见任务 5，先在 Base.lproj 加 zh 文案；测试环境 `t()` 返回 key 本身即可，断言用 key 存在性 + 组装逻辑而非具体中文）
- 时间格式：今天/昨天 + HH:mm（Calendar.isDateInToday/isDateInYesterday）
- 降级：deviceName 为空省略设备名段；rssi 为 nil 省略信号段；两者都有时合并为一段「设备名 信号 x dBm」（正文最低限度 = 时间段）；用数组 `join(" · ")` 组装
- 锁定标题 `t("im_title_locked")`、解锁 `t("im_title_unlocked")`；测试事件与解锁共用文案
- 信号显示：`Int(rssi.rounded())` 取整；信号段模板 `im_body_signal`（含设备名时前缀拼接设备名，无独立设备段模板）

测试（IMMessageComposerTests）：
1. 锁定事件 → 标题含「已锁定」key、正文含时间与设备名与信号
2. 解锁事件 → 标题含「已解锁」key
3. 跨天时间 → 昨天分支（构造昨天 23:59 的 Date 传参，或让 compose 接受 `now: Date = .now` 便于注入）
4. deviceName 为 nil → 正文不含设备名段
5. rssi 为 nil → 正文不含信号段
6. normalizeRecipient：`+86 138-1234 5678` → `8613812345678`；`abc@icloud.com` 不变；`(010) 1234-5678` 按数字清洗规则处理（定义清楚：仅去除空格/横线/括号/加号）

验证：跑 `-only-testing:FUnlockTests/IMMessageComposerTests` 通过后提交（消息：`test: IMMessageComposer 文案组装与收件人格式化`）。

## 任务 2：iMessageNotifier 事件 API

修改 `FUnlock/iMessageNotifier.swift`：

- 新增 `func send(_ event: IMEvent)`：guard 开关/收件人 → 按事件类型防抖（key = "lock"/"unlock"/"test"，30s）→ queue.async → compose → runAppleScript → 失败静默丢弃
- 防抖 key 改为事件类型而非 title（现有 `lastSendTime[title]` 改为 `lastSendTime[typeKey]`）
- 保留 `sendTestNotification(title:message:completion:)` 签名不变（兼容现有测试与 UI，内部改走 `.test` 事件，completion 失败消息经 `friendlyError` 已含中文，无需额外加工）——若改签名则同步更新 FUnlockTests/iMessageNotifierTests.swift 中全部 6 处调用
- `sendNotification(title:message:)` 删除（FUnManager 两处调用在任务 3 迁移后再删，任务 2 内保留以避免编译断裂）

测试更新（iMessageNotifierTests）：
1. `testLockedEventDebouncedByType`：scriptRunner 计数，连续两次 `send(.locked(...))` 仅 1 次执行；`send(.unlocked(...))` 与 `.test` 不受影响
2. `testLockedEventSilentFailure`：scriptRunner 返回错误字符串，`send(.locked(...))` 不抛异常、completion 不调用（无 completion 即无断言路径，验证"无崩溃 + 不发送到 UI"）
3. 既有 12 个测试保持通过（sendTestNotification 相关 5 个 + 错误映射 7 个）

验证：`-only-testing:FUnlockTests/iMessageNotifierTests` 通过后提交（消息：`feat: iMessageNotifier 语义化事件 API 与按类型防抖`）。

## 任务 3：FUnManager 调用处迁移

修改 `FUnlock/FUnManager.swift` 两处：

- 第 408 行（锁屏）：`iMessageNotifier.shared.sendNotification(title: "🔒 Funlock: Mac已锁屏", message: "reason=\(reason)")` → `iMessageNotifier.shared.send(.locked(reason: reason, rssi: fun.effectiveRSSI, deviceName: monitoredDeviceName))`
- 第 702 行（解锁）：`iMessageNotifier.shared.sendNotification(...)` → `iMessageNotifier.shared.send(.unlocked(rssi: fun.effectiveRSSI, deviceName: monitoredDeviceName))`
- 删除 `sendNotification` 方法本体（若任务 2 已无其他调用）

验证：全量 `xcodebuild ... test`（358+ 通过），构建编译无误后提交（消息：`refactor: FUnManager 改用 iMessageNotifier 事件 API`）。

## 任务 4：IMSettingsCard 设置卡片

新建 `FUnlock/IMSettingsCard.swift`，将 `UnlockSettingsView` 的 iMessage 区块（第 39-67 行 + alert）整体替换为卡片。

要点：
- `@AppStorage("iMessageNotify")` 开关 + 副标题（`t("im_settings_desc")`）
- 开启后显示收件人输入：`TextField(t("im_recipient_placeholder"), text:)`，onChange 即时校验：手机号（清洗后 10-15 位纯数字）或邮箱（含 `@` 且格式合理）；非法时下方红字 `t("im_recipient_invalid")`；合法时不打扰
- 授权状态行：`@AppStorage` 无持久化（规格：按上次发送结果标记）→ 用 `@State private var lastError: String?`；`lastError == nil` → 绿勾 `t("im_authorized")`；非 nil 且为未授权（消息含「授权」）→ `t("im_unauthorized")` + 「去授权 →」按钮（`NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)`）
- 单个「发送测试通知」按钮（禁用条件：isTesting 或收件人非法或为空）：`sendTestNotification(title: t("im_test_title"), message: t("im_test_body"))` → 行内结果：成功绿字 `t("im_test_success")`；失败红字（未授权文案 + 内联「去授权」按钮；其他错误直接展示 err.message）
- 移除 TestKind enum、isTesting/showResultAlert/testSucceeded/testMessage 旧状态、alert
- 删除 `sendNotification`/`sendTestNotification` 旧 UI 调用链后，UnlockSettingsView 主体只剩唤醒/屏保三个 Toggle Section

验证：build + 全量测试通过；手动 `open` 部署前先在 Xcode 或直接跑测试确认编译。提交（消息：`feat: IMSettingsCard 卡片式 iMessage 设置与行内测试反馈`）。

## 任务 5：本地化（8 语言）

在 `FUnlock/{Base,da,de,ja,nb,sv,tr,zh-Hans}.lproj/Localizable.strings` 各新增 key（Base 为英文源，zh-Hans 为中文，其余按既有文件风格翻译）：

- `im_title_locked` / `im_title_unlocked`：锁定/解锁标题（Funlock：Mac 已锁定 / 已解锁）
- `im_body_time_today` / `im_body_time_yesterday`：`今天 %@` / `昨天 %@`（zh-Hans 用全角冒号或空格拼接，按规格示例 `今天 23:45 · iPhone 信号 -88 dBm` 实现：composer 内拼装，key 仅含「今天/昨天」与分隔符 ` · `）
- `im_body_signal`：信号段模板（`信号 %d dBm`；设备名非空时在其前拼接「设备名 」）
- `im_settings_title` / `im_settings_desc`：卡片标题/副标题
- `im_recipient_placeholder` / `im_recipient_invalid`：输入框占位（手机号或 Apple ID）/校验错误
- `im_authorized` / `im_unauthorized` / `im_go_authorize`：已授权 ✓ / 未授权 / 去授权 →
- `im_test_title` / `im_test_body` / `im_test_success`：测试通知标题/正文/成功提示

注意事项：
- `t()` 取 key 缺失时返回 key 本身，UI 不能显示裸 key——8 个文件必须全部补齐
- Base.lproj 用英文（保持与既有文件一致）；zh-Hans 中文；其他语言沿用文件既有语言
- key 命名与 `iMessageNotify`/`iMessageNotifyRecipient`（既有 defaults key）不冲突

验证：`grep -L "im_title_locked" FUnlock/*.lproj/Localizable.strings` 无输出；全量测试通过。提交（消息：`i18n: iMessage 产品化文案 8 语言本地化`）。

## 收尾（版本 2.8.35）

1. `PlistBuddy` 提升 CFBundleVersion/CFBundleShortVersionString 至 2.8.35
2. Release 构建 → 全量测试 → 替换 `/Applications/FUnlock.app` → codesign 校验 → 重启 App
3. 用户实测：锁屏/解锁各收一条 iMessage（检查通知文案格式）、设置页测试按钮、非法收件人校验
4. 更新 `docs/0807handoff.md` 与规格状态；commit + push github feat/diagnostics-tab


