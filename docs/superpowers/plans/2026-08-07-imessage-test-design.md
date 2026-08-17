# iMessage 手动连通性测试 实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 为 FUnlock 设置页的 iMessage 通知增加两个手动测试按钮（测试锁定 / 测试解锁），用户点击后通过 AppleScript 发送 iMessage 并显示「已发送 / 发送失败 + 原因（含后续确认收到）」。

**架构：** 方案 A（已批准）。`iMessageNotifier` 抽统一同步核心 `runAppleScript → String?`（nil=成功）；新增 `sendTestNotification`（后台队列执行、主线程回调 `Result<Void,String>`、绕过 30s 防抖、不写 `lastSendTime`）。真实 `sendNotification` 链路不动。设置页 `UnlockSettingsView` 加 `@State` + 两个按钮 + SwiftUI `.alert`。`runAppleScript` 可注入（`scriptRunner` 闭包）便于单测。

**技术栈：** Swift + SwiftUI + Foundation（NSAppleScript）、XCTest。

---
**依赖关系：** 任务 1 → 任务 2（sendTestNotification 复用 friendlyError + runAppleScript）→ 任务 3（UI）。任务 1/2 均在任务 3 之前必须全绿。任务 4 收尾。

## 文件结构

- `FUnlock/iMessageNotifier.swift`（修改）：`runAppleScript` 返回错误、新增 `friendlyError`、新增 `sendTestNotification`、新增 `scriptRunner` 注入点
- `FUnlock/UnlockSettingsView.swift`（修改）：测试按钮 + 状态 + `.alert`（当前 iMessage 开关 UI 是未提交工作区改动，本任务在其上叠加）
- `FUnlockTests/iMessageNotifierTests.swift`（创建）：单测类 `iMessageNotifierTests`
- `FUnlock.xcodeproj/project.pbxproj`（修改）：注册新测试文件（仿现有测试文件 4 处条目 + 唯一ID）

**版本号：** 任务 5 统一处理（升 2.8.31）。

---

### 任务 1：统一 runAppleScript 返回值 + 错误映射

**文件：**
- 修改：`FUnlock/iMessageNotifier.swift`（全部）
- 测试：`FUnlockTests/iMessageNotifierTests.swift`（创建）

**注意：修改前先读 `FUnlock/iMessageNotifier.swift` 全文，按现有风格改。**

- [ ] **步骤 1：前置基线**

运行：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS'`
预期：346 tests 全绿（确认无回归起点）

- [ ] **步骤 2：写失败测试（错误映射纯函数）**

创建 `FUnlockTests/iMessageNotifierTests.swift`：

```swift
// FUnlockTests/iMessageNotifierTests.swift
import XCTest
@testable import FUnlock

final class iMessageNotifierTests: XCTestCase {

    override func tearDown() {
        // 清理测试写入的 defaults，避免污染真实配置
        UserDefaults.standard.removeObject(forKey: "iMessageNotify")
        UserDefaults.standard.removeObject(forKey: "iMessageNotifyRecipient")
        iMessageNotifier.shared.scriptRunner = nil
        super.tearDown()
    }

    // MARK: - 错误映射

    func testPermissionDeniedMapsToChinese() {
        let info: NSDictionary = [
            NSAppleScriptErrorNumber: -1743,
        ]
        let msg = iMessageNotifier.friendlyError(errorInfo: info)
        XCTAssertTrue(msg.contains("授权"), "未授权应提示授权，实际: \(msg)")
    }

    func testBuddyNotFoundMapsToRecipientInvalid() {
        let info: NSDictionary = [
            NSAppleScriptErrorNumber: -1708,
            NSAppleScriptErrorMessage: "chat... cannot find buddy \"abc\""
        ]
        let msg = iMessageNotifier.friendlyError(errorInfo: info)
        XCTAssertTrue(msg.contains("收件人"), "应提示收件人无效，实际: \(msg)")
    }

    func testGenericErrorReturnsMessage() {
        let info: NSDictionary = [
            NSAppleScriptErrorNumber: -1,
            NSAppleScriptErrorMessage: "boom"
        ]
        let msg = iMessageNotifier.friendlyError(errorInfo: info)
        XCTAssertTrue(msg.contains("boom"))
    }
}
```

> 说明：`NSAppleScriptErrorNumber` / `NSAppleScriptErrorMessage` 在 Darwin 上以字符串常量存在（Swift 中为 `NSAppleScriptErrorNumber` 全局字符串）。若常量名不可用，改用字面量 `"NSAppleScriptErrorNumber"` / `"NSAppleScriptErrorMessage"`。

- [ ] **步骤 3：运行测试验证失败**

```bash
xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' \
  -only-testing:FUnlockTests/iMessageNotifierTests 2>&1 | tail -12
```
预期：编译失败（`friendlyError` 不存在）+ 无 tests 运行。

- [ ] **步骤 4：实现 + 修改 runAppleScript 返回错误**

修改 `FUnlock/iMessageNotifier.swift`：

- 把 `private func runAppleScript(recipient:text:)` 改为**保持 private** 且返回 `String?`：

```swift
    /// 执行 AppleScript 发送 iMessage。成功返回 nil，失败返回可读错误描述。
    @discardableResult
    private func runAppleScript(recipient: String, text: String) -> String? {
        let script = """
        tell application "Messages"
            set targetService to 1st service whose service type = iMessage
            set targetBuddy to buddy "\(recipient)" of targetService
            send "\(text)" to targetBuddy
        end tell
        """
        guard let appleScript = NSAppleScript(source: script) else {
            return "AppleScript 源码编译失败"
        }
        var errorInfo: NSDictionary?
        appleScript.executeAndReturnError(&errorInfo)
        guard let errorInfo = errorInfo else { return nil }
        return Self.friendlyError(errorInfo: errorInfo)
    }

    /// 把 NSAppleScript 错误字典转换为用户可读的中文提示
    static func friendlyError(errorInfo: NSDictionary) -> String {
        let numKey = "NSAppleScriptErrorNumber"
        let msgKey = "NSAppleScriptErrorMessage"
        let number = errorInfo[numKey] as? Int ?? -1
        let message = errorInfo[msgKey] as? String ?? "未知错误"
        if number == -1743 {
            return "Messages 未授权：请在 系统设置 → 隐私与安全性 → 自动化 中允许 FUnlock 控制 Messages"
        }
        if message.localizedCaseInsensitiveContains("buddy") || message.localizedCaseInsensitiveContains("not found") {
            return "收件人无效：请检查号码/账号是否为 iMessage 好友（需先在 Messages 中有会话）"
        }
        return "发送失败：\(message)（错误码 \(number)）"
    }
```

> 请直接编辑现有文件，与文件现有代码风格保持一致；旧 `runAppleScript`（无返回值）恰 2 处引用需同步为 `@discardableResult` 兼容。

- [ ] **步骤 5：运行测试**

```bash
xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' \
  -only-testing:FUnlockTests/iMessageNotifierTests 2>&1 | tail -12
```
预期：3 个测试 PASS。

- [ ] **步骤 6：Commit**

```bash
git add FUnlock/iMessageNotifier.swift FUnlockTests/iMessageNotifierTests.swift FUnlock.xcodeproj/project.pbxproj
git commit -m "feat: iMessageNotifier 支持手动测试（返回错误描述 + 错误中文映射）"
```

> 若步骤 2 创建的测试文件尚未注册到 pbxproj，可在本步骤一并添加（见任务 2 步骤 4 的 PBX 模板）。

---

### 任务 2：sendTestNotification（绕过防抖 + 注入）

**文件：**
- 修改：`FUnlock/iMessageNotifier.swift`
- 测试：`FUnlockTests/iMessageNotifierTests.swift`

- [ ] **步骤 1：写失败测试（追加到 iMessageNotifierTests）**

```swift
    // MARK: - sendTestNotification

    func testTestNotificationFailsFastWhenDisabled() {
        UserDefaults.standard.set(false, forKey: "iMessageNotify")
        UserDefaults.standard.set("13800138000", forKey: "iMessageNotifyRecipient")
        let exp = expectation(description: "disabled")
        iMessageNotifier.shared.sendTestNotification(title: "🔒 测试", message: "锁定") { result in
            switch result {
            case .failure(let msg): XCTAssertTrue(msg.contains("开关"))
            case .success: XCTFail("开关关闭时不应发送")
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func testTestNotificationFailsWhenNoRecipient() {
        UserDefaults.standard.set(true, forKey: "iMessageNotify")
        UserDefaults.standard.removeObject(forKey: "iMessageNotifyRecipient")
        let exp = expectation(description: "noRecipient")
        iMessageNotifier.shared.sendTestNotification(title: "t", message: "m") { result in
            switch result {
            case .failure(let msg): XCTAssertTrue(msg.contains("收件人"))
            case .success: XCTFail("收件人为空时不应发送")
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func testTestNotificationSuccess() {
        UserDefaults.standard.set(true, forKey: "iMessageNotify")
        UserDefaults.standard.set("13800138000", forKey: "iMessageNotifyRecipient")
        iMessageNotifier.shared.scriptRunner = { _, _ in nil } // 模拟发送成功
        let exp = expectation(description: "success")
        iMessageNotifier.shared.sendTestNotification(title: "t", message: "m") { result in
            if case .success = result {} else { XCTFail("应成功") }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func testSendTestNotificationFailurePropagates() {
        UserDefaults.standard.set(true, forKey: "iMessageNotify")
        UserDefaults.standard.set("13800138001", forKey: "iMessageNotifyRecipient")
        iMessageNotifier.shared.scriptRunner = { _, _ in "Messages 未授权" }
        let exp = expectation(description: "failure")
        iMessageNotifier.shared.sendTestNotification(title: "t", message: "m") { result in
            switch result {
            case .failure(let msg): XCTAssertTrue(msg.contains("未授权"))
            case .success: XCTFail("应失败")
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func testTestNotificationBypassDebounce() {
        UserDefaults.standard.set(true, forKey: "iMessageNotify")
        UserDefaults.standard.set("13800138001", forKey: "iMessageNotifyRecipient")
        var calls = 0
        iMessageNotifier.shared.scriptRunner = { _, _ in calls += 1; return nil }
        let exp = expectation(description: "twice")
        var pending = 2
        for _ in 0..<2 {
            iMessageNotifier.shared.sendTestNotification(title: "t", message: "m") { result in
                pending -= 1
                if pending == 0 { exp.fulfill() }
            }
        }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(calls, 2, "测试通知应绕过 30s 防抖，两次都执行")
    }
```

- [ ] **步骤 2：运行验证失败**

同上指令。预期：编译失败（`sendTestNotification` / `scriptRunner` 未定义）。

- [ ] **步骤 3：实现**

在 `iMessageNotifier` 增加如下成员：

```swift
    // 测试注入点：替换真实 AppleScript 执行，便于单测（默认 nil）
    var scriptRunner: ((String, String) -> String?)?

    // 开关 / 收件人 key（复用现有 Keys enum）
    private var enabled: Bool {
        UserDefaults.standard.bool(forKey: Keys.enabled)
    }
    private var recipient: String? {
        UserDefaults.standard.string(forKey: Keys.recipient)
    }

    /// 手动连通性测试：发送并返回结果（成功 .success, 失败 .failure+原因）。
    /// 绕过 30s 防抖、不写 lastSendTime —— 测试目的就是要反复验证。
    /// completion 在主线程回调。
    func sendTestNotification(title: String, message: String,
                              completion: @escaping (Result<Void, String>) -> Void) {
        guard enabled else {
            completion(.failure("iMessage 通知开关未开启，请先开启"))
            return
        }
        guard let recipient = recipient, !recipient.isEmpty else {
            completion(.failure("收件人为空，请先填写 iMessage 收件人"))
            return
        }
        let text = "\(title)\n\(message)"
        queue.async { [weak self] in
            guard let self = self else { return }
            let err = self.scriptRunner?(recipient, text) ?? self.runAppleScript(recipient: recipient, text: text)
            DispatchQueue.main.async {
                if let err = err {
                    completion(.failure(err))
                } else {
                    completion(.success(()))
                }
            }
        }
    }
```

> 签名：**带标签** `sendTestNotification(title:message:completion:)`，测试与 UI 均使用带标签调用。

- [ ] **步骤 4：注册测试文件到 pbxproj（仿现有模板）**

在 `FUnlock.xcodeproj/project.pbxproj` 中添加（参照 `DT0000020000000100000001`：`iMessageNotifierTests.swift`）——找“iMessageNotifierTests”现有模板不存在则新增 4 个条目：
1. `PBXBuildFile`：`XX0T000T000T000T000T0001 /* iMessageNotifierTests.swift in Sources */`
2. `PBXFileReference`：`XX0T0000000T0000000000002 /* iMessageNotifierTests.swift */`
3. `PBXGroup children`（FUnlockTests 组）：`XX0T0000000T0000000000002`
4. `Sources build phase`（测试 target）：`XX0T000T000T000T000T0001`

> 复制现有测试文件条目结构；请勿手写 UUID 以碰撞。可直接复制 `DT000001` 的条目、改成新 UUID（例如 `IM00000000000000000000000` 前缀）以保持唯一。

- [ ] **步骤 5：运行测试**

```bash
xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' \
  -only-testing:FUnlockTests/iMessageNotifierTests 2>&1 | tail -14
```
预期：9 个（3+6）tests 全部通过。

- [ ] **步骤 6：Commit**

```bash
git add FUnlock/iMessageNotifier.swift FUnlockTests/iMessageNotifierTests.swift FUnlock.xcodeproj/project.pbxproj
git commit -m "feat: 新增 sendTestNotification 手动测试（绕过防抖、可注入、主线程回调）"
```

---

### 任务 3：设置页测试按钮 UI

**文件：**
- 修改：`FUnlock/UnlockSettingsView.swift`（现有 iMessage 开关 UI 是未提交工作区改动 → 在其上叠加）

- [ ] **步骤 1：读文件确认现状**

读 `FUnlock/UnlockSettingsView.swift` 全文，确认现有 iMessage Section（Toggle + 收件人 TextField）。在此基础上改造。

- [ ] **步骤 2：编码改造**

在 `UnlockSettingsView` 增加 `@State`，在收件人 TextField 之后渲染两个测试按钮，并挂 `.alert`：

```swift
    @State private var isTesting = false
    @State private var showResultAlert = false
    @State private var testSucceeded = false
    @State private var testMessage = ""
```

在 `Section` 的 `if iMessageNotify` 块内追加：

```swift
                    if !iMessageNotifyRecipient.isEmpty {
                        HStack {
                            Button("测试锁定") {
                                runTest(kind: "锁定")
                            }
                            .disabled(isTesting)
                            Button("测试解锁") {
                                runTest(kind: "解锁")
                            }
                            .disabled(isTesting)
                            if isTesting {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
```

视图上 `.alert`（挂在 ScrollView 上）：

```swift
            .alert("iMessage 测试", isPresented: $showResultAlert) {
                Button(testSucceeded ? "已收到" : "好") {
                    showResultAlert = false
                }
            } message: {
                Text(testSucceeded ? "已发送，请确认 Apple Watch 是否收到" : testMessage)
            }
```

以及私有方法：

```swift
    private func runTest(kind: String) {
        guard !isTesting else { return }
        isTesting = true
        let emoji = kind == "锁定" ? "🔒" : "🔓"
        let title = "\(emoji) FUnlock 手动测试：\(kind)"
        let message = "请确认 Apple Watch 是否收到"
        iMessageNotifier.shared.sendTestNotification(title: title, message: message) { result in
            isTesting = false
            switch result {
            case .success:
                testSucceeded = true
                testMessage = "已发送，请确认 Apple Watch 是否收到"
            case .failure(let msg):
                testSucceeded = false
                testMessage = msg
            }
            showResultAlert = true
        }
    }
```

> **注意：**
> - `sendTestNotification` 使用**带标签**的签名 `sendTestNotification(title:message:completion:)`（任务 2 的实现与测试也统一用带标签形式）。
> - 锁定/解锁文案：锁定 "🔒 FUnlock 手动测试：锁定"；解锁 "🔓 FUnlock 手动测试：解锁"。
> - 主线程回调：`sendTestNotification` 内已在 `DispatchQueue.main.async` 回调，SwiftUI 直接改 @State 即可，无需再包。

- [ ] **步骤 3：编译验证**

```bash
xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' build 2>&1 | tail -6
```
预期：BUILD SUCCEEDED。

- [ ] **步骤 4：Commit**

```bash
git add FUnlock/UnlockSettingsView.swift
git commit -m "feat: UnlockSettingsView 增加 iMessage 手动测试按钮（锁定/解锁）+ 结果 Alert"
```

---

### 任务 4：全量回归 + 版本升级 + 部署

- [ ] **步骤 1：全量测试**

```bash
xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' 2>&1 | tail -8
```
预期：全部通过（基线 346 + 新增 9）。

- [ ] **步骤 2：升版本号**

```bash
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 2.8.31" FUnlock/Info.plist
```

- [ ] **步骤 3：Release 构建 + 覆盖安装 + 签名验证 + 启动**

```bash
xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -configuration Release -destination 'platform=macOS' build 2>&1 | tail -4
# 确认 Release 产物路径后（DerivedData/.../Release/FUnlock.app）：
osascript -e 'quit app "FUnlock"' 2>/dev/null; sleep 2; pkill -f "FUnlock.app/Contents/MacOS/FUnlock" 2>/dev/null; sleep 1
rm -rf /Applications/FUnlock.app
ditto "<Release 产物路径>/FUnlock.app" /Applications/FUnlock.app
codesign --verify --deep --strict /Applications/FUnlock.app
xattr -dr com.apple.quarantine /Applications/FUnlock.app 2>/dev/null
open /Applications/FUnlock.app
sleep 3; pgrep -x FUnlock && /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" /Applications/FUnlock.app/Contents/Info.plist
```
预期：版本 2.8.31、FUnlock 运行中。

- [ ] **步骤 4：提交 + 推送**

```bash
git add FUnlock/Info.plist
git commit -m "chore: 版本 2.8.31（iMessage 手动测试功能）"
git push
```

> 若仓库有 push 配置（github remote），推送到当前分支 `feat/diagnostics-tab`。

---

## 手动验证（交付标准）

1. 打开 FUnlock → 设置（解锁设置）→ 开启「iMessage 通知」→ 填写你的 iMessage 账号
2. 点击「测试锁定」→ 应弹 Alert「已发送，请确认 Apple Watch 是否收到」
3. 点「测试解锁」→ 同上
4. 关闭开关 → 点测试 → Alert 显示「开关未开启…」
5. 清空收件人 → 按钮应隐藏（或点击提示「收件人为空」）
6. 若失败：Alert 显示具体中文错误（未授权提示去系统设置 / 收件人无效提示）

## 兜底（多次快速点击）

- `isTesting` 在回调前保持 true → 按钮 disabled 防重入
- `sendTestNotification` 绕过 30s 防抖，允许反复测试