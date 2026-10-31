# Bark 推送通知设计（与 iMessage 并存）

日期：2026-10-31 ｜ 状态：待批准（已按 fable 评审修订）｜ 规模：small change（新增 4 文件 + 修改 12 处）

## 意图与背景

FUnlock 在锁屏/解锁 Mac 时通过 iMessage 发通知（显示在 Apple Watch）。用户新增需求：同时支持 Bark 推送到 iPhone（App 已装）。**用户决策：并存可切换**——iMessage 链路保留不动，Bark 作为独立通道、独立开关。

历史经验（NotchEvery 项目，2026-10-28 实测）：Bark 手机端已装，key `swMSCpBr9baWGYCiu6ijoK`，`POST https://api.day.app/$KEY` + JSON `{title, body, group, level}` 返回 HTTP 200 通路验证通过。

## 目标 / 非目标 / 反目标

- **目标**：锁屏/解锁/test 事件可经 Bark 推送到 iPhone；设置页新增 Bark 卡片（开关 + key 输入 + 服务器地址 + 测试按钮）；文案沿用 `IMMessageComposer` 现有 title/body。
- **非目标**：不删除、不重构 iMessage 通知链路；不做通知历史、重试队列、加密。
- **反目标**：两通道开关互相耦合（改一个影响另一个）。

## 方案对比（已定）

1. **每通道独立 notifier，调用点各加一行（选定）**：新建 `BarkNotifier`（结构对齐 `iMessageNotifier`），在 2 个调用点各加一行 `BarkNotifier.shared.send(event)`——穷举核实 `iMessageNotifier.shared.send` 调用点仅 [UnlockOrchestrator.swift:217](FUnlock/UnlockOrchestrator.swift:217)（解锁）与 [FUnManager+Events.swift:270](FUnlock/FUnManager+Events.swift:270)（`onDeviceLeft(reason:)` 内锁屏）。手动锁屏 `lockNow()`、系统锁屏、屏保路径本就不发通知，保持不发。理由：只有 2 处，dispatcher 是推测性扩展（YAGNI）；各通道 enabled guard 自行决定是否发送，无需协议抽象。
2. NotificationDispatcher + 协议收口（否决）：最初为"7 处调用点"设计，前提不成立；2 处调用不值得多一层抽象。
3. 合并进 iMessageNotifier 内部分发（否决）：耦合两通道，违背独立开关的意图。

## 设计要点

### 默认值与规范化（BarkNotifier 内收敛）

- `enum Defaults { static let key = "swMSCpBr9baWGYCiu6ijoK"; static let server = "https://api.day.app" }`——key 与 server 的唯一事实来源，UI placeholder 与 notifier fallback 都引用它。
- `barkNotifyServer` 无值时 fallback 到 `Defaults.server`，`barkNotifyKey` 无值时 fallback 到 `Defaults.key`（`@AppStorage` 初值不写入 UserDefaults，[IMSettingsCard.swift:7-8](FUnlock/IMSettingsCard.swift:7-8) 同款行为，故 notifier 侧必须自带 fallback，否则开关打开也静默不发）。
- 纯函数规范化（模式对齐 `normalizeRecipient`，[IMMessageComposer.swift:60](FUnlock/IMMessageComposer.swift:60)）：`normalizeServer` = trim + 去尾部 `/`；`normalizeKey` = trim。URL 组装：key 经 `addingPercentEncoding(.urlPathAllowed)` 后拼 `server + "/" + key`，`URL(string:)` 为 nil 则静默失败记日志。

### BarkNotifier（新文件 `FUnlock/BarkNotifier.swift`）

- `final class BarkNotifier: @unchecked Sendable`，单例 `shared`，结构对齐 [iMessageNotifier.swift:12](FUnlock/iMessageNotifier.swift:12)。
- 配置键：`barkNotify`（开关，默认 false）、`barkNotifyKey`、`barkNotifyServer`（仅允许 https；ATS 无例外域，明文 http 会被系统拦截）。
- 发送：utility 串行队列 + `URLSession` `POST {server}/{key}`，JSON `{"title", "body", "group": "funlock", "level": "timeSensitive"}`；`timeoutInterval: 10`（防挂起占住串行队列）；HTTP 200 视为成功；失败静默记 `AppLog.error(.app, "barkSendFailed", [("status", …), ("code", …)])`——**只记 status code 与错误域/code，不打 URL、不打 NSError 描述**（两者都含完整 key，会泄漏进 debug.log）。
- 并发：**在调用线程先 `compose` 取 `(title, body)` 再进队列**（照 [iMessageNotifier.swift:81-83](FUnlock/iMessageNotifier.swift:81-83)），不把 `IMEvent` 捕获进 `queue.async`（工程 `SWIFT_STRICT_CONCURRENCY = complete`，`IMEvent` 未标 Sendable）。
- 防抖：**有意对齐 iMessage 语义**——按事件类型（lock/unlock/test）各 30 秒、先占窗口后发送、失败也消耗窗口（[iMessageNotifier.swift:72-79](FUnlock/iMessageNotifier.swift:72-79)），实现者不得"修"成成功后计时；`resetDebounceForTesting()`。测试通知**绕过防抖且不写窗口**（同 iMessage [iMessageNotifier.swift:94-118](FUnlock/iMessageNotifier.swift:94-118)）。
- 测试注入点（对齐 `scriptRunner` 模式）：`configStore`、`nowProvider`、`requestSender: ((URLRequest) -> (Int, Data)?)?`。
- `sendTestNotification(title:message:completion:)`：`@MainActor`，绕过防抖，`Result<Void, SendError>`，错误文案中文化（key 为空、非 200、URL 无效）。测试标题用独立文案 `bark_test_title`（"Bark 测试通知"），不复用 `im_title_unlocked`（否则测试推送与真实解锁无法区分）。

### UI（新文件 `FUnlock/BarkSettingsCard.swift` + 挂载）

- 结构对齐 `IMSettingsCard`：Toggle（`barkNotify`）+ TextField（key）+ TextField（server，placeholder 显示 `Defaults.server`）+ 测试按钮 + 测试结果反馈（成功/失败）。
- 开关关闭时隐藏输入行与测试按钮（条件展示，对齐 [IMSettingsCard.swift:49-59](FUnlock/IMSettingsCard.swift:49-59) 模式）。
- server 输入校验：非空且非 `https://` 前缀时红字提示"仅支持 https"；key 校验非空。
- `@AppStorage` 默认值引用 `BarkNotifier.Defaults`（`store: ConfigStore.shared.defaults`，模式同 IMSettingsCard:7-8）。
- 挂载：[UnlockSettingsView.swift:49](FUnlock/UnlockSettingsView.swift:49) 的 `IMSettingsCard()` 下方加 `BarkSettingsCard()`。

### 调用点（2 处，各加一行）

- [UnlockOrchestrator.swift:217](FUnlock/UnlockOrchestrator.swift:217)：解锁事件后加 `BarkNotifier.shared.send(.unlocked(rssi:deviceName:))`（参数复用同一事件构造，不重复求值）。
- [FUnManager+Events.swift:270](FUnlock/FUnManager+Events.swift:270)：`onDeviceLeft(reason:)` 锁屏事件后同上 `.locked(...)`。
- 不需要协议：仅 2 处调用，直接引用 `BarkNotifier.shared`。

### 工程登记（必做，否则不编译）

`FUnlock.xcodeproj/project.pbxproj` 为显式文件引用（无 `fileSystemSynchronized` group；先例 `iMessageNotifier.swift` 共 4 处登记：PBXBuildFile / PBXFileReference / group / Sources phase）。`BarkNotifier.swift`、`BarkSettingsCard.swift`、`BarkNotifierTests.swift` 三个新文件必须手工完成同样 4 处登记（app target + test target）。

### 本地化（**8 语言全量**）

knownRegions = en / Base / ja / zh-Hans / de / da / nb / sv / tr，每个 lproj 的 `Localizable.strings` 都要新增（前例：iMessage 产品化设计明确 8 语言全量；漏语言会回退英文，属可见回归）。新增 keys：

- `bark_settings_title`（Bark 推送通知）
- `bark_settings_desc`（解锁/锁屏时通过 Bark 推送到 iPhone）
- `bark_key_label` / `bark_key_placeholder`
- `bark_server_label` / `bark_server_placeholder`
- `bark_key_invalid`（请输入 Bark key）
- `bark_server_https_only`（仅支持 https）
- `bark_test_title`（Bark 测试通知）
- `bark_send_test`（发送测试通知）
- `bark_test_success`（已发送，请查看 iPhone）

### ConfigStore 登记说明

- `defaultBool` 表**不需要**动（`barkNotify` 缺失回退 false 与业务默认一致）。
- `barkNotifyKey` / `barkNotifyServer` 登记进 `legacyKeys`（[ConfigStore.swift:187](FUnlock/ConfigStore.swift:187)）。注意其真实副作用：经 `exportableKeys` 进入"导出全部设置"，Bark key 会**明文**出现在导出 JSON / 剪贴板（与 iMessage 收件人同级别，可接受）。

### 测试（新文件 `FUnlockTests/BarkNotifierTests.swift`）

对齐 `iMessageNotifierTests` 模式：独立 suite 名（如 `com.fuhahah.FUnlock.test-bark`）+ tearDown 复位 `requestSender` / `nowProvider` / `resetDebounceForTesting`。覆盖：

1. enabled / key 守卫（开关关、key 空不发）
2. 按事件类型 30s 防抖（含失败消耗窗口）
3. `requestSender` 注入：200 成功 / 非 200 失败 / 抛错
4. server 尾斜杠与空白规范化、key percentEncoding
5. key/server 无值时 fallback 到 `Defaults`
6. 请求 URL 与 JSON body 断言（title/body/group/level 四键）
7. `sendTestNotification` 全分支（成功、非 200、URL 无效、key 空）
8. 测试通知不消耗防抖窗口

## 留给实现者的

- `requestSender` 具体形状（closure 或 protocol）以测试好写为准。
- `IMEvent` 参数在 2 个调用点的具体构造方式以现有上下文变量为准（不重复求值）。

## 验收标准

1. `xcodebuild test` 全绿：新增 `BarkNotifierTests` + 原有 `iMessageNotifierTests` 回归不变。
2. `xcodebuild build` 通过（工程登记正确的直接证据）。
3. 设置页出现 Bark 卡片：开关默认关、key/server placeholder 预填默认值；开关关闭时输入行隐藏；非 https server 显示红字提示。
4. 真机手动验证：开关打开后点"发送测试通知"，iPhone 收到 Bark 推送（用户手测）。若推送未到但按钮报成功：检查 iPhone 端 Bark 是否允许"时效性通知"（`level: timeSensitive` 被拒时 Bark 仍返回 HTTP 200，系统降级为普通通知）。
5. iMessage 通道行为不变（回归测试）。
6. 8 语言文件都含新 keys（grep 验证）。
