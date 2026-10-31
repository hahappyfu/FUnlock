# Bark 推送通知实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** FUnlock 锁屏/解锁事件新增 Bark 推送通道（与 iMessage 并存、独立开关），设置页提供 key/server 配置与测试按钮。

**Architecture:** 新建 `BarkNotifier`（结构对齐 `iMessageNotifier`：单例、串行队列、按事件类型 30s 防抖、测试注入点），在既有 2 个调用点各加一行；新建 `BarkSettingsCard` 挂到 UnlockSettingsView；8 语言本地化。iMessage 链路零改动。

**Tech Stack:** Swift 6（`SWIFT_STRICT_CONCURRENCY = complete`）、SwiftUI、XCTest、Xcode 工程（显式 pbxproj 文件引用，无 fileSystemSynchronized）。

**Spec:** `docs/superpowers/specs/2026-10-31-bark-notification-design.md`

## Global Constraints

- iMessage 通知链路（`iMessageNotifier.swift`、`IMSettingsCard.swift`、`IMMessageComposer.swift`）**零改动**。
- Bark API：`POST {server}/{key}`，JSON `{"title", "body", "group": "funlock", "level": "timeSensitive"}`，HTTP 200 即成功；`timeoutInterval: 10`。
- 默认值唯一来源：`BarkNotifier.Defaults`（key = `swMSCpBr9baWGYCiu6ijoK`，server = `https://api.day.app`）；UI placeholder 与 notifier fallback 都引用它，不重复硬编码。
- 配置键：`barkNotify`（开关）、`barkNotifyKey`、`barkNotifyServer`；`barkNotifyKey`/`barkNotifyServer` 登记 `ConfigStore.legacyKeys`（`barkNotify` 不登记——缺失回退 false 与业务默认一致，且 defaultBool 表勿动）。
- 并发约束（strict concurrency）：`IMEvent` 非 Sendable——**在调用线程先 `compose` 取 `(title, body)`，再闭包捕获进 `queue.async`**，禁止把 `IMEvent` 捕获进队列闭包（照 `iMessageNotifier.swift:81-83`）。
- 日志：失败静默记 `AppLog.error(.app, "barkSendFailed", [("status", …), ("code", …)])`，**禁止打完整 URL 或 NSError 描述**（两者含 key）。
- 防抖语义**有意对齐 iMessage**（`iMessageNotifier.swift:72-79`）：按事件类型（lock/unlock/test）各 30 秒、先占窗口后发送、失败也消耗窗口；测试通知绕过防抖且不写窗口（`iMessageNotifier.swift:94-118`）。不得改成"成功后计时"。
- 新文件必须登记 `FUnlock.xcodeproj/project.pbxproj`：每文件 4 处（PBXBuildFile、PBXFileReference、group、Sources build phase），格式照 `iMessageNotifier.swift` 先例（pbxproj:64/:176/:294/:524），新条目用不冲突的唯一 ID（如 `AA0000EE…` 前缀）。
- 新增 Swift 代码风格对齐 `iMessageNotifier.swift`：中文注释、`// MARK:` 分组、`private` 优先。
- commit 消息：conventional commits 中文（如 `feat(notify): …`），结尾加 `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`。

## Review Focus

spec 暗示但任务测试未直接覆盖、最可能咬到使用者的五类输入（各条已在归属任务的步骤中给出钉住它的测试或验证）：

1. **粘贴值带空白/尾斜杠**：key 或 server 粘贴进 `https://api.day.app/abc/`（尾斜杠）或带换行——期望规范化后仍能发送 → Task 1 测试钉住。
2. **server 填明文 http**：ATS 默认拦截，发送静默失败——期望 UI 端提前红字拦截（https 之外的 scheme 不给点测试按钮）→ Task 4 验证步骤人工目测钉住。
3. **防抖窗口内的失败**：失败也消耗 30s 窗口是有意语义，实现者不得"修"→ Task 2 测试 `testFailureConsumesDebounceWindow` 钉住。
4. **测试推送与真实解锁混淆**：测试通知复用"Mac 已解锁"标题会让用户误判 → Task 2/4 用独立 `bark_test_title` 钉住（断言 UI 传入的 title 来自 `bark_test_title`）。
5. **导出设置含明文 key**：`barkNotifyKey` 进 `exportableKeys` 后"导出全部设置"的 JSON/剪贴板含明文 key——与 iMessage 收件人同级、设计已接受；不做防护，reviewer 审 Task 2 时确认此权衡未被"好心"改成加密存储。

---

### Task 1: BarkNotifier 基础——Defaults 常量、规范化纯函数、URL 组装

**Files:**
- Create: `FUnlock/BarkNotifier.swift`
- Create: `FUnlockTests/BarkNotifierTests.swift`
- Modify: `FUnlock.xcodeproj/project.pbxproj`（登记上述两个文件，app target + test target 各 4 处）

**Interfaces:**
- Consumes: 无（纯函数，无依赖）。
- Produces（Task 2/4 依赖的精确签名）:
  - `enum Defaults { static let key: String; static let server: String }`（嵌套于 `BarkNotifier`）
  - `static func normalizeServer(_ raw: String) -> String`（trim + 去尾部 `/`）
  - `static func normalizeKey(_ raw: String) -> String`（trim）
  - `static func buildURL(server: String, key: String) -> URL?`（server 去 `/` + `"/"` + key percentEncoding(.urlPathAllowed)，`URL(string:)` 为 nil 返回 nil）

- [ ] **Step 1: 在 `FUnlockTests/BarkNotifierTests.swift` 写失败测试**（文件壳 + suite 模式照 `FUnlockTests/iMessageNotifierTests.swift:1-23`，suite 名 `"com.fuhahah.FUnlock.test-bark"`）

```swift
// FUnlockTests/BarkNotifierTests.swift
import XCTest
@testable import FUnlock

final class BarkNotifierTests: XCTestCase {
    // setUp/tearDown 见 Task 2 Step 1（本任务先只写纯函数测试）
    func testNormalizeServerTrimsAndStripsTrailingSlash() {
        XCTAssertEqual(BarkNotifier.normalizeServer(" https://api.day.app/ "), "https://api.day.app")
        XCTAssertEqual(BarkNotifier.normalizeServer("https://api.day.app///"), "https://api.day.app")
    }
    func testNormalizeKeyTrims() {
        XCTAssertEqual(BarkNotifier.normalizeKey(" abc\n "), "abc")
    }
    func testBuildURLEncodesKeyAndJoins() {
        let url = BarkNotifier.buildURL(server: "https://api.day.app/", key: "abcXYZ")
        XCTAssertEqual(url?.absoluteString, "https://api.day.app/abcXYZ")
        XCTAssertNil(BarkNotifier.buildURL(server: "https://api.day.app", key: "a b"))  // 含空格 key 仍可编码则非 nil——此断言按实现调整：见下方说明
    }
}
```

说明：`buildURL` 对含空格 key 做 percentEncoding 后 URL 合法，故第二条应断言**非 nil 且**编码结果（`url?.absoluteString == "https://api.day.app/a%20b"`）；nil 断言留给 server 为非法字符串（如 `"\n"`）的用例。按此修正测试。

- [ ] **Step 2: 跑测试确认失败**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -only-testing:FUnlockTests/BarkNotifierTests 2>&1 | tail -20`
Expected: FAIL（`BarkNotifier` 符号未定义——若 pbxproj 未登记则同样报错，先完成 Step 3 的登记）

- [ ] **Step 3: 实现 `FUnlock/BarkNotifier.swift` 文件壳与三个纯函数，并登记 pbxproj**

文件壳：`// FUnlock/BarkNotifier.swift` 头注释（说明职责：Bark 推送通道，与 iMessage 并存独立开关）、`import Foundation`、`final class BarkNotifier: @unchecked Sendable` + `static let shared` + `private init()`。Defaults 三个成员与三个纯函数体各自一行可写完（`trimmingCharacters(in: .whitespacesAndNewlines)`、`while hasSuffix("/")` dropLast、`addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)`）。pbxproj 4 处登记照 Global Constraints。

- [ ] **Step 4: 跑测试确认通过**

Run: 同 Step 2
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add FUnlock/BarkNotifier.swift FUnlockTests/BarkNotifierTests.swift FUnlock.xcodeproj/project.pbxproj
git commit -m "feat(notify): BarkNotifier 基础——默认值/规范化/URL 组装纯函数"
```

---

### Task 2: BarkNotifier 发送——send 防抖、sendTestNotification、注入点

**Files:**
- Modify: `FUnlock/BarkNotifier.swift`
- Modify: `FUnlockTests/BarkNotifierTests.swift`
- Modify: `FUnlock/ConfigStore.swift:189`（`legacyKeys` 数组追加 2 个 key）

**Interfaces:**
- Consumes: Task 1 的 `Defaults`/`normalizeServer`/`normalizeKey`/`buildURL`；`IMMessageComposer.compose(_ event: IMEvent, now: Date = .now) -> (title: String, body: String)`（已有，勿改）。
- Produces（Task 3/4 依赖）:
  - `func send(_ event: IMEvent)`（enabled/key 守卫 + 防抖 + 异步发送，失败静默记日志）
  - `@MainActor func sendTestNotification(title: String, message: String, completion: @escaping @MainActor (Result<Void, BarkNotifier.SendError>) -> Void)`
  - `struct SendError: Error { let message: String }`（嵌套）
  - `func resetDebounceForTesting()`
  - 测试注入属性：`var configStore: ConfigStore`（默认 `.shared`）、`var nowProvider: () -> Date`（默认 `Date.init`）、`var requestSender: ((URLRequest) -> (Int, Data)?)?`（nil 时用真实 URLSession）

- [ ] **Step 1: 写失败测试**（`BarkNotifierTests` 补齐 setUp/tearDown，模式照 `iMessageNotifierTests.swift:8-24`：注入 `BarkNotifier.shared.configStore = testConfigStore`；tearDown 复位 configStore/nowProvider/requestSender + `resetDebounceForTesting()` + `removePersistentDomain`）。用例清单（每条 3-8 行断言）：

  1. `testDisabledGateSkipsSend`——configStore 无 `barkNotify` 时 `send` 不触发 `requestSender`。
  2. `testEmptyKeyFallsBackToDefault`——`barkNotifyKey` 缺失时请求 URL 等于 `Defaults.server + "/" + Defaults.key`。
  3. `testServerFallbackAndServerNormalization`——`barkNotifyServer` 缺失回退 `Defaults.server`；值带尾斜杠被规范化。
  4. `testDebouncePerEventType`——同类型 30s 内第二次 `send` 只发一次；不同类型（lock/unlock）互不占窗口（`nowProvider` 注入推进时间）。
  5. `testFailureConsumesDebounceWindow`——requestSender 返回 503，30s 内再发同类型被吞（Review Focus 3）。
  6. `testRequestPayload`——捕获 URLRequest 断言：method POST、URL 正确、body JSON 含 `title`/`body`/`group == "funlock"`/`level == "timeSensitive"` 四键、`timeoutInterval == 10`。
  7. `testSendTestNotificationBypassesDebounce`——连续两次 `sendTestNotification` 均触达 requestSender，且不写防抖窗口（之后 `send(.test)` 仍立即可发）。
  8. `testSendTestNotificationErrorBranches`——key 为空且 Defaults 不可用（将 Defaults.key 置空不可行则用 server 无效 `URL` nil 分支）返回 `.failure` 且 message 含中文提示；200 返回 `.success`。

- [ ] **Step 2: 跑测试确认失败**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -only-testing:FUnlockTests/BarkNotifierTests 2>&1 | tail -20`
Expected: FAIL（`send`/`sendTestNotification` 未定义）

- [ ] **Step 3: 实现发送路径**

`BarkNotifier` 补齐（结构逐块照 `iMessageNotifier.swift:12-118`）：`Keys` enum、`queue`（`DispatchQueue(label: "com.funlock.bark", qos: .utility)`）、`debounceInterval = 30.0`、`lastSendTime: [String: Date]` + `NSLock`；`send(_:)` 在调用线程 `IMMessageComposer.compose(event)`（Global Constraints 并发约束）→ 防抖（typeKey 照 `iMessageNotifier.swift:64-69`）→ `queue.async` 组 `URLRequest`（`buildURL` + JSON body `JSONSerialization` 或 `JSONEncoder`，实现者任选，以测试可断言为准）→ `requestSender` 或 `URLSession.shared.data(for:)` 同步执行 → 非 200 记 `AppLog.error`；`sendTestNotification` 照 `iMessageNotifier.swift:94-118` 的 @MainActor/continuation 模式，错误文案中文（key 空→"请先填写 Bark Key"、URL 无效→"服务器地址无效"、非 200→"发送失败：HTTP \(status)"）。`ConfigStore.legacyKeys` 数组追加 `"barkNotifyKey", "barkNotifyServer"`。

- [ ] **Step 4: 跑测试确认通过**

Run: 同 Step 2
Expected: PASS

- [ ] **Step 5: 全量回归（iMessage 不受影响）**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' 2>&1 | tail -30`
Expected: 全部 PASS（含 `iMessageNotifierTests`）

- [ ] **Step 6: Commit**

```bash
git add FUnlock/BarkNotifier.swift FUnlockTests/BarkNotifierTests.swift FUnlock/ConfigStore.swift
git commit -m "feat(notify): BarkNotifier 发送路径——防抖/测试通知/注入点"
```

---

### Task 3: 调用点接入（2 处各加一行）

**Files:**
- Modify: `FUnlock/UnlockOrchestrator.swift:217`（`iMessageNotifier.shared.send(.unlocked(...))` 之后）
- Modify: `FUnlock/FUnManager+Events.swift:270`（`iMessageNotifier.shared.send(.locked(...))` 之后）

**Interfaces:**
- Consumes: Task 2 的 `BarkNotifier.shared.send(_ event: IMEvent)`。
- Produces: 无（叶子接线）。

- [ ] **Step 1: 解锁调用点**——`UnlockOrchestrator.swift:217` 之后加一行，复用同一事件参数（不重复求值）：

```swift
BarkNotifier.shared.send(.unlocked(rssi: snap.effectiveRSSI, deviceName: self.manager.monitoredDeviceName))
```

- [ ] **Step 2: 锁屏调用点**——`FUnManager+Events.swift:270` 之后加一行：

```swift
BarkNotifier.shared.send(.locked(reason: reason, rssi: snap.effectiveRSSI, deviceName: monitoredDeviceName))
```

- [ ] **Step 3: 验证**

Run: `xcodebuild build -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' 2>&1 | tail -5 && xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' 2>&1 | tail -10`
Expected: build SUCCEEDED + 全部测试 PASS（接线行为由验收阶段真机确认；单元级由 Task 2 测试覆盖 notifier 本体）

- [ ] **Step 4: Commit**

```bash
git add FUnlock/UnlockOrchestrator.swift FUnlock/FUnManager+Events.swift
git commit -m "feat(notify): 锁屏/解锁事件接入 Bark 通道（与 iMessage 并存）"
```

---

### Task 4: BarkSettingsCard 设置卡 + 挂载

**Files:**
- Create: `FUnlock/BarkSettingsCard.swift`
- Modify: `FUnlock/UnlockSettingsView.swift:49-50`（`IMSettingsCard().liquidGlassCard(...)` 之后）
- Modify: `FUnlock.xcodeproj/project.pbxproj`（登记 `BarkSettingsCard.swift`，app target 4 处）

**Interfaces:**
- Consumes: Task 2 的 `BarkNotifier.shared.sendTestNotification` / `SendError` / `Defaults`；`IMMessageComposer.compose(.test).body`；本地化 `t(_:)` 函数（Task 5 之前 key 尚不存在——UI 先写 key 引用，构建不报错，Task 5 补文案）。
- Produces: `struct BarkSettingsCard: View`（无参 init）。

- [ ] **Step 1: 实现 `FUnlock/BarkSettingsCard.swift`**

结构逐块照 `IMSettingsCard.swift:6-157`：`@AppStorage("barkNotify", store: ConfigStore.shared.defaults)` 开关、`@AppStorage("barkNotifyKey", store:)` 默认 `BarkNotifier.Defaults.key`、`@AppStorage("barkNotifyServer", store:)` 默认 `BarkNotifier.Defaults.server`；`TestState` enum 同款。body：`VStack(spacing: 10)` 内 `Toggle`（`LiquidIconBadge(icon: "bell.badge.fill", color: .orange)` + `bark_settings_title`/`bark_settings_desc`），`if barkNotify` 内 `keyRow`（`bark_key_label`/`bark_key_placeholder`，非空校验→`bark_key_invalid` 红字）、`serverRow`（`bark_server_label`/`bark_server_placeholder`；非空且非 `https://` 前缀→`bark_server_https_only` 红字且禁用测试按钮）、`LiquidDivider()`、`testRow`（`bark_send_test`）、状态文案。`runTest()` 照 `IMSettingsCard.swift:134-150`：规范化（`BarkNotifier.normalizeKey`/`normalizeServer`）写回 defaults → `IMMessageComposer.compose(.test).body` 作 message、title 用 `t("bark_test_title")`（Review Focus 4）→ `sendTestNotification`。

- [ ] **Step 2: 挂载 + 登记工程**

`UnlockSettingsView.swift:49-50` 的 iMessage 卡片之后加：

```swift
// Bark 推送通知卡：独立晶体卡片
BarkSettingsCard()
    .liquidGlassCard(cornerRadius: 16, padding: 14)
```

pbxproj 登记 4 处。

- [ ] **Step 3: 验证**

Run: `xcodebuild build -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' 2>&1 | tail -5`
Expected: SUCCEEDED。人工目测（运行 app 设置页）：开关关闭时输入行隐藏；server 填 `http://` 前缀出现红字且测试按钮禁用（Review Focus 2）。

- [ ] **Step 4: Commit**

```bash
git add FUnlock/BarkSettingsCard.swift FUnlock/UnlockSettingsView.swift FUnlock.xcodeproj/project.pbxproj
git commit -m "feat(notify): Bark 设置卡——key/服务器配置与测试按钮"
```

---

### Task 5: 本地化（8 语言全量）

**Files:**
- Modify: `FUnlock/Base.lproj/Localizable.strings`、`FUnlock/en.lproj/Localizable.strings`、`FUnlock/ja.lproj/Localizable.strings`、`FUnlock/zh-Hans.lproj/Localizable.strings`、`FUnlock/de.lproj/Localizable.strings`、`FUnlock/da.lproj/Localizable.strings`、`FUnlock/nb.lproj/Localizable.strings`、`FUnlock/sv.lproj/Localizable.strings`、`FUnlock/tr.lproj/Localizable.strings`（各在 `im_` 键块之后追加，行号参考 zh-Hans:353-367 的 `im_test_success` 之后）

**Interfaces:**
- Consumes: Task 4 的 key 引用。
- Produces: 11 个 key 的 9 语言文案（Base 与 en 同英文值）。

- [ ] **Step 1: 追加文案**（keys：`bark_settings_title` / `bark_settings_desc` / `bark_key_label` / `bark_key_placeholder` / `bark_key_invalid` / `bark_server_label` / `bark_server_placeholder` / `bark_server_https_only` / `bark_test_title` / `bark_send_test` / `bark_test_success`）。zh-Hans 值：`Bark 推送通知` / `解锁/锁屏时通过 Bark 推送到 iPhone` / `Key` / `Bark 推送 Key` / `请输入 Bark Key` / `服务器` / `https://api.day.app` / `仅支持 https` / `Bark 测试通知` / `发送测试通知` / `已发送，请查看 iPhone`。Base/en 值：`Bark Push Notifications` / `Push lock/unlock events to iPhone via Bark` / `Key` / `Bark device key` / `Please enter your Bark key` / `Server` / `https://api.day.app` / `Only https:// is supported` / `Bark Test Notification` / `Send Test Notification` / `Sent — check your iPhone`。ja：`Bark プッシュ通知` / `ロック/解除時に Bark で iPhone へ通知` / `キー` / `Bark のキー` / `Bark のキーを入力してください` / `サーバー` / `https://api.day.app` / `https:// のみ対応` / `Bark テスト通知` / `テスト通知を送信` / `送信しました。iPhone を確認してください`。de：`Bark-Push-Benachrichtigungen` / `Sperr-/Entsperr-Ereignisse per Bark an das iPhone senden` / `Schlüssel` / `Bark-Geräteschlüssel` / `Bitte Bark-Schlüssel eingeben` / `Server` / `https://api.day.app` / `Nur https:// wird unterstützt` / `Bark-Testbenachrichtigung` / `Testbenachrichtigung senden` / `Gesendet – siehe iPhone`。da：`Bark-pushnotifikationer` / `Send låse-/oplåsningshændelser til iPhone via Bark` / `Nøgle` / `Bark-enhedsnøgle` / `Indtast din Bark-nøgle` / `Server` / `https://api.day.app` / `Kun https:// understøttes` / `Bark-testnotifikation` / `Send testnotifikation` / `Sendt – tjek din iPhone`。nb：`Bark-pushvarsler` / `Send låse-/opplåsingshendelser til iPhone via Bark` / `Nøkkel` / `Bark-enhetsnøkkel` / `Angi Bark-nøkkelen din` / `Server` / `https://api.day.app` / `Bare https:// støttes` / `Bark-testvarsel` / `Send testvarsel` / `Sendt – sjekk iPhone`。sv：`Bark-pushnotiser` / `Skicka lås-/upplåsningshändelser till iPhone via Bark` / `Nyckel` / `Bark-enhetsnyckel` / `Ange din Bark-nyckel` / `Server` / `https://api.day.app` / `Endast https:// stöds` / `Bark-testnotis` / `Skicka testnotis` / `Skickat – kolla din iPhone`。tr：`Bark Anlık Bildirimleri` / `Kilit/kilidi açma olaylarını Bark ile iPhone'a gönder` / `Anahtar` / `Bark cihaz anahtarı` / `Bark anahtarınızı girin` / `Sunucu` / `https://api.day.app` / `Yalnızca https:// desteklenir` / `Bark Test Bildirimi` / `Test Bildirimi Gönder` / `Gönderildi – iPhone'una bak`。

- [ ] **Step 2: 验证**

Run: `for f in Base en ja zh-Hans de da nb sv tr; do printf "%s: " "$f"; grep -c '"bark_' "FUnlock/$f.lproj/Localizable.strings"; done && xcodebuild build -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' 2>&1 | tail -3`
Expected: 每个语言文件 ≥ 11；build SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add "FUnlock/Base.lproj/Localizable.strings" FUnlock/en.lproj/Localizable.strings FUnlock/ja.lproj/Localizable.strings FUnlock/zh-Hans.lproj/Localizable.strings FUnlock/de.lproj/Localizable.strings FUnlock/da.lproj/Localizable.strings FUnlock/nb.lproj/Localizable.strings FUnlock/sv.lproj/Localizable.strings FUnlock/tr.lproj/Localizable.strings
git commit -m "feat(notify): Bark 设置与测试文案 8+1 语言全量本地化"
```

---

### Task 6: 全量验证收尾

**Files:** 无新改动（若验证失败，回到对应任务修复后重跑本任务）。

- [ ] **Step 1: 全量测试 + 构建**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' 2>&1 | tail -30`
Expected: 全部 PASS（`BarkNotifierTests`、`iMessageNotifierTests`、其余既有测试）

- [ ] **Step 2: spec 验收清单核对**（对应 spec 验收标准 1/2/3/5/6；4 需真机，报告里标注"待用户手测"）：
  - 新增测试全绿 + iMessage 测试回归不变
  - 设置页 Bark 卡片：开关默认关、key/server 默认预填、开关关闭隐藏输入行、非 https 红字
  - iMessage 零改动（`git diff main --stat -- FUnlock/iMessageNotifier.swift FUnlock/IMSettingsCard.swift FUnlock/IMMessageComposer.swift` 为空）
  - 8+1 语言 grep 各 ≥ 11

- [ ] **Step 3: Commit（如 Task 内修复产生改动）**

```bash
git add -A && git commit -m "test(notify): Bark 通道全量验证"
```
（无改动则跳过）
