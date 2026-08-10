# iMessage 通知产品化设计

- 日期：2026-08-08
- 状态：已批准
- 关联：`docs/superpowers/specs/2026-08-07-imessage-test-design.md`（功能初版）

## 背景与问题

iMessage 通知（解锁/锁屏时发到 Apple Watch）已能正常工作（v2.8.32 修复授权），但体验像 demo：

1. 通知文案硬编码、含调试信息：`"🔒 Funlock: Mac已锁屏"` + `reason=lost`
2. 设置页是「开关 → 输入框 → 两个测试按钮」的简易形态，无校验、无授权状态、无结果反馈
3. 文案未接入 8 语言本地化体系，测试与真实通知各写各的

## 目标

- 通知文案产品化：极简状态通知，无内部调试信息
- 设置流程产品化：卡片式增强（校验、授权状态、单个测试按钮、行内结果）
- 文案逻辑集中、可单测；全量本地化（8 语言）

## 非目标（YAGNI）

- 发送队列、失败重试、状态持久化
- 实时 TCC 授权探活（仅按上次发送结果标记）
- 距离/位置等额外字段

## 架构

```
FUnManager.swift
  send(.locked(reason: "lost", rssi: -88, deviceName: "iPhone"))
  send(.unlocked(rssi: -42, deviceName: "iPhone"))
        │  语义化事件
        ▼
iMessageNotifier (单例，保留现有职责)
  - 开关/收件人读取（UserDefaults）
  - 30s 防抖（按事件类型：lock/unlock/test）
  - runAppleScript：外部 /usr/bin/osascript 执行（保留）
  - sendTestNotification(...) → 改为测试事件路径
        │  事件 + 原始数据
        ▼
IMMessageComposer (纯函数，无依赖，可单测)
  - compose(event) -> (title, body)
  - 组装本地化文案、时间格式（今天/昨天 HH:mm）
  - normalizeRecipient()：+86 138-1234 5678 → 8613812345678
```

### 组件职责

| 组件 | 职责 | 依赖 |
|------|------|------|
| FUnManager | 触发事件（锁屏/解锁时调用 send） | iMessageNotifier |
| iMessageNotifier | 开关检查、防抖、osascript 执行、错误映射 | IMMessageComposer |
| IMMessageComposer | 纯文案组装：标题/正文/时间/收件人格式化 | 无（纯函数） |
| IMSettingsCard（新 SwiftUI 视图） | 设置页卡片：开关/收件人/授权状态/测试按钮/行内结果 | Localizable |

## 通知文案

标题：`Funlock：Mac 已锁定` / `Funlock：Mac 已解锁`

正文（锁定）：

```
今天 23:45 · iPhone 信号 -88 dBm
```

正文（解锁）：

```
今天 08:12 · iPhone 信号 -42 dBm
```

规则：
- 时间：今天/昨天 + HH:mm（跨天用昨天）
- 设备名空时省略设备名段，信号无值时省略信号段（降级文案）
- 信号强度为绑定设备状态量化值

## 设置页卡片（IMSettingsCard）

```
iMessage 通知
解锁/锁屏时发送到 Apple Watch     [Toggle]

（开启后显示）
收件人  [输入框]
        失败时红字提示（手机号格式 / 邮箱格式）
──────────
授权状态：[已授权 ✓] 或 [去授权 →]（跳转自动化设置页）
──────────
[发送测试通知]  ── 点击后 loading
结果行内展示：成功绿字「已发送，请查看 Apple Watch」/
            失败红字（未授权 → 带「去授权」行动按钮；收件人无效；发送失败+错误码）
```

- 收件人校验即时：手机号（10-15 位数字）或邮箱格式；成功不打扰
- 授权状态：上次发送失败为 -1743 → "未授权" + 去授权按钮；成功 → "已授权"
- 单个「发送测试通知」按钮（替代锁定/解锁两按钮 + 弹窗），发送 `.test` 事件

## 数据流（锁定场景）

```
FUnManager.tryLock()
  → iMessageNotifier.send(.locked(reason, rssi, deviceName))
  → guard 开关开 + 收件人非空 → 30s 防抖（按事件类型）
  → queue.async → IMMessageComposer.compose(...) → (title, body)
  → runAppleScript(recipient, "\(title)\n\(body)")
  → 失败 → friendlyError → 真实路径静默丢弃
```

## 错误处理

| 路径 | 行为 |
|------|------|
| 真实发送失败 | 静默丢弃（锁时不打扰用户） |
| 测试发送失败 | 卡片行内展示原因：未授权/收件人无效/发送失败+错误码 |
| 未授权（-1743） | 设置页状态行显示「未授权 → 去授权」；打开自动化设置页 |

## 测试计划

- `IMMessageComposerTests`（新增）：
  - 标题/正文格式（锁定/解锁）
  - 时间格式（今天/昨天 HH:mm）
  - 设备名为空 / 信号无值时的降级文案
  - `normalizeRecipient`：`+86 138-1234 5678 → 8613812345678`、邮箱不变
- `iMessageNotifierTests`（更新）：
  - `send(.locked)` 防抖按事件类型生效
  - 真实路径失败静默（scriptRunner 返回错误但无异常抛出）
  - `sendTestNotification` 测试事件路径
- 全量回归 358+ 通过

## 本地化

- 新增 key（8 语言）：通知标题/正文模板、设置卡片文案、校验提示、授权状态、测试结果
- `IMMessageComposer` 通过 `t()` 取文案（与现有 Localizable 体系一致）