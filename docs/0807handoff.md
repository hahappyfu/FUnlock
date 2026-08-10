# FUnlock Handoff — 2026-08-07

## 今日工作摘要

### 1. Auto-Lock Bug 修复（已完成）

**问题：** 信号低于锁屏阈值但不触发锁屏

**根因：** `InputActivityMonitor` 的 `activityWindow=30s` 太长 + HID 回调过滤太宽（触控板移动、媒体键都算用户活动）→ `isUserInputActive` 持续为 true → 衰减基准被重置 → 信号"虚假回升" → 永远不锁

**修复：**
- `activityWindow` 30→15 秒
- `inputCallback` 只在 `value != 0` 且匹配键盘/鼠标/触控板点击时触发
- 提交：`edf5afb`

**验证：** 用户走远后锁屏成功触发，`inputActive=true` 从频繁出现降为 0 次

### 2. 衰减曲线优化（已完成）

**修改：** `decayedEffectiveRSSI()` 分段衰减：
- 6s 内不衰减（缓冲 BLE 采样间隙）
- 6-10s 温和线性（0.75 dB/s，最多 3 dB）
- 10s 后 1 dB/s，封顶 20 dB

### 3. DecisionLogger coalescing 修复（已完成）

**问题：** 合并事件不写磁盘，导致日志丢失

**修复：** coalescing 时也触发 `write()` 写入磁盘

### 4. 锁屏调试日志（已完成）

**问题：** GUI 应用的 `print()` 被系统丢弃

**修复：** 新增 `lockLog()` 函数，写入 `/tmp/funlock_lock.log`，替换所有 `print("[LOCK]")`

### 5. 项目全面审计（已完成）

**5 个子智能体并行审计：** 代码质量、架构、测试覆盖、安全、性能

**报告：** `docs/2026-08-07-audit-report.md`

**关键发现：**
- Critical：5 个线程安全问题、2 个安全漏洞（BLE 身份验证缺失、更新签名缺失）
- Important：8 个代码质量问题、3 个架构问题、5 个安全问题、5 个性能问题
- 测试覆盖：WiFiMonitor/RingBuffer/SignalDataStore 完全无测试

**用户决策：** 暂不处理，等以后再说

### 6. iMessage 通知功能（已完成，待测试）

**功能：** 解锁/锁屏时通过 AppleScript 给自己发 iMessage，自动推送到 Apple Watch

**实现：**
- `FUnlock/iMessageNotifier.swift` — 单例，NSAppleScript 调用 Messages，防抖 30s
- `FUnlock/FUnManager.swift` — 在 `onDeviceLeft` 和 `tryUnlock` 成功时调用
- `FUnlock/UnlockSettingsView.swift` — 设置开关 + 收件人输入框
- `project.pbxproj` — 已添加新文件引用

**提交：** `b272a43`（iMessageNotifier）、`99a1f48`（Hook 事件）、设置开关已提交

**状态：** 已编译安装到本地（v2.8.30），用户正在测试

### 6. iMessage 手动测试功能（已完成，v2.8.31）

**交付：** 设置页新增 iMessage 开关 + 收件人 + 「测试锁定/测试解锁」按钮 + 结果 Alert
- 规格/计划/实现/三轮审查全过，354 测试通过
- 提交：`919230b`（spec）→ `5a78dac`（plan）→ `1f6a461`~ `c2b4210`（实现+2.8.31）

### 7. iMessage 授权修复：外部 osascript（已完成，2026-08-08 v2.8.32）

**问题：** 「测试锁定」报 `Messages 未授权`，自动化面板永不出现 FUnlock 条目，从未弹授权框

**根因（经过系统复现验证）：** LSUIElement 菜单栏 App **进程内 NSAppleScript** 触发 TCC AppleEvents 检查时，系统**不弹授权框并静默拒绝（-1743）**；
而 NSTask 调用外部 `/usr/bin/osascript` 时**正常弹出授权框**。
- 复现步骤：带 automation entitlement 的探针 App 分别用进程内 NSAppleScript（立即 -1743）vs 外部 osascript（弹窗可授权）验证

**修复：** `iMessageNotifier.swift` 的 `runAppleScript` 改用 NSTask + `/usr/bin/osascript`，新增 `parseScriptError` 解析 stderr（错误码 -1743/buddy 映射），`friendlyError` 拆分为 number/message 版。新增 4 个解析测试。
- 提交：`043e14f`，版本 2.8.32，358 测试通过，用户实测「成功，收到消息」

### 8. iMessage 通知产品化（已完成，2026-08-10 v2.8.35）

**规格：** `docs/superpowers/specs/2026-08-08-imessage-productization-design.md`（已批准）

**交付内容：**
- **通知文案产品化**：极简状态通知「Funlock：Mac 已锁定/已解锁」+ 正文「今天 23:45 · iPhone 信号 -88 dBm」，去掉 `reason=lost` 等内部调试信息
- **架构重构（方案 A）**：`FUnManager` → `iMessageNotifier.send(.locked/.unlocked)` 事件 API → `IMMessageComposer` 纯函数组装（可单测）
  - 防抖改为按事件类型（lock/unlock/test）各 30s；`sendNotification(title:message:)` 已删除
  - `IMSettingsCard`：卡片式设置（开关/收件人即时校验/授权状态行/单个「发送测试通知」+ 行内结果，未授权时引导打开自动化设置页）
- **本地化**：iMessage 文案 8 语言齐备（Base/da/de/ja/nb/sv/tr/zh-Hans）
- **测试**：新增 `IMMessageComposerTests` 15 个 + `iMessageNotifierTests` 新增 4 个，全量 377 通过

**提交链：** `c53428d`（规格）→ `1b08f06`（计划）→ `35bdc36`（Composer）→ `64a102d`（事件 API）→ `b64cbb9`（FUnManager 迁移）→ `8a1c973`（IMSettingsCard）→ `9376af2`（i18n）→ `2e60f25`（2.8.35）
- 版本 2.8.35 已部署 `/Applications/FUnlock.app`（PID 58412 运行中），已推送 github

## 当前分支状态

```
分支：feat/diagnostics-tab
最新提交：2e60f25 (chore: 版本 2.8.35)
版本：2.8.35 (已部署 /Applications/FUnlock.app)
```

## 待办

- [x] 用户测试 iMessage 通知功能（2.8.32 已验证，成功收到消息）
- [ ] 用户实测 2.8.35：锁屏/解锁各收一条 iMessage（检查文案格式）、设置页测试按钮、非法收件人校验
- [ ] 测试通过后合并到 main
- [ ] 用户按需测试自动解锁/锁屏的 iMessage 通知（非手动测试路径）

## 相关文件

- `docs/2026-08-07-audit-report.md` — 全面审计报告
- `docs/0803handoff.md` — 之前的 handoff（auto-lock 排查）
- `FUnlock/iMessageNotifier.swift` — iMessage 通知工具类
- `FUnlock/UnlockSettingsView.swift` — 设置页面（含 iMessage 开关）
- `/tmp/funlock_lock.log` — 锁屏调试日志

## 建议技能

- `subagent-driven-development` — 如果需要继续开发新功能
- `systematic-debugging` — 如果测试中发现新 bug
- `using-superpowers` — 任何新功能开发前先调用
