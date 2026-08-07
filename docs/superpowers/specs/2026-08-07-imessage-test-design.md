# FUnlock iMessage 手动连通性测试 — 设计规格

> 2026-08-07 · 已批准设计

## 背景

`iMessageNotifier` 是最近加入的功能（commits `b272a43`/`99a1f48`）：解锁/锁屏时通过 AppleScript 发 iMessage 到 Apple Watch。但当前实现是「异步 + 失败静默」——用户无法知道通知有没有真的发出去。

本文档为设置页增加**手动连通性测试**：用户开启开关、填写收件人后，点「测试锁定 / 测试解锁」按钮即可验证链路。

## 功能描述

流程：

```
开关开 → 填收件人 → 出现「测试锁定」「测试解锁」两个按钮
   ↓ 点击
按钮转圈（加载态）→ 后台队列执行 AppleScript
   ├─ 成功 → Alert「已发送」+ 按钮「已收到」（点击关闭）
   └─ 失败 → Alert 显示具体错误原因
```

成功后的「已收到」确认仅关闭提示，不做任何记录（用户已确认，YAGNI）。

## 接口：iMessageNotifier 扩展

选方案 A：真实链路不动，测试路径单独入口。

### 抽统一执行核心

现状 `runAppleScript(recipient:text:)` 是 `private` 且无返回值。改造为：

```swift
/// 执行 AppleScript 发送 iMessage。成功返回 nil，失败返回错误描述（中文可读）。
@discardableResult
func runAppleScript(recipient: String, text: String) -> String?
```

- 收集 `executeAndReturnError` 的 `NSAppleScriptErrorMessage` / `NSAppleScriptErrorNumber` 转成可读中文提示
- 真实 `sendNotification` 内部改为调用此方法（后台队列），对外行为不变

### 新增测试入口（绕过防抖）

```swift
/// 手动连线测试：后台执行并主线程回调结果。绕过 30s 防抖，不写 lastSendTime。
func sendTestNotification(title: String, message: String,
                          completion: @escaping (Result<Void, String>) -> Void)
```

- 检查开关与收件人：未开/为空 → 立即 `completion(.failure("请先开启开关并填写收件人"))`
- 在 `queue` 上执行 `runAppleScript`；错误 → `completion(.failure(描述))`，成功 → `completion(.success(()))`
- 回调切到主线程交付 UI
- **不写 `lastSendTime`**，不污染真实通知防抖

## 设置页 UI（UnlockSettingsView）

- 新增 `@State`：
  - `isTesting: Bool`（加载态，按钮转圈 / disabled）
  - `showResultAlert: Bool`
  - `testSucceeded: Bool`（决定成功/失败 Alert 文案）
  - `testErrorMessage: String`
- 收件人 `TextField` 非空时显示两个按钮（水平排列）：
  - 「测试锁定」→ title「🔒 FUnlock 测试」、消息「锁定测试」
  - 「测试解锁」→ title「🔓 FUnlock 测试」、消息「解锁测试」
- 用 SwiftUI `.alert` 展示结果：
  - 成功：title「已发送」、message「请确认 Apple Watch 是否收到」、按钮「已收到」→ 关闭
  - 失败：title「发送失败」+ message 显示 `appError`
- 按钮点击时若收件人为空（防御）→ 直接 alert 提示

## 错误中文映射

| AppleScript 情况 | 返回提示 |
| --- | --- |
| TCC 未授权 Messages 自动化 | 「Messages 未授权：请在 系统设置→隐私与安全性→自动化 中开启」 |
| 收件人不是 iMessage 好友 | 「收件人无效：该号码/账号未启用 iMessage 或不在通讯录」 |
| 其他 AppleEvent 错误 | 原 `NSAppleScriptErrorMessage` |

## 测试策略

- 单测覆盖（`iMessageNotifierTests`）：
  - 防抖绕过：连续两个 `sendTestNotification` 请求都应执行（不再被 30s 窗口拦截）
  - 开关关闭 → completion 快速 return
  - 空收件人 → completion 快速 return
  - 成功路径：注入 mock 执行核心返回 nil → `.success`
  - 失败路径：注入 mock 返回「未授权」→ `.failure("Messages 未授权…")`
- mock 方式：让 `sendTestNotification` 接受可注入的 `runAppleScript` 闭包（默认 `self.runAppleScript`），单测替换为闭包；不真调 Messages
- 手动验证：用户设置页点拨通，收到 iMessage → 功能目标达成

## 边界情况

1. 开关关闭 / 收件人为空 → 进入测试按钮且 `sendTestNotification` 快速失败并提示
2. 用户连续快速点击测试按钮 → 加载态 disabled 防重入；测试绕过防抖，可反复测
3. 真实锁屏/解锁通知逻辑不受影响：`sendNotification` 复用 `runAppleScript`，签名与对外行为不变
4. 版本号：仅当发版时升；本功能若下个发布批一起走

## 新单位

- `iMessageNotifier` 只新增/改造两个方法（`runAppleScript` 返回错误 + `sendTestNotification`）
- `UnlockSettingsView` 只新增测试 UI（@State + 按钮 + alert）
- 无新增文件（i已有 `iMessageNotifier.swift`）