# Handoff — 诊断 Tab（2026-08-02）

> 给下一个 session（macOS 执行验证）的工作交接。开发编码部分（Task 1-5）已全部完成并提交，只剩 Task 6 需要在真实 Mac 上验证。

## 1. 本次做了什么

为 FUnlock 新增「诊断」Tab：把「为什么没解锁 / 为什么锁屏」变成结构化决策事件时间线，帮助用户理解并自助解决（调阈值、开权限、重输密码、恢复自动解锁）。

- **决策记录器** `FUnlock/DecisionLogger.swift`：内存环形缓冲(500) + 同因合并(3s) + JSONL 持久化 + 1MB 轮转，纯观察式，不改变任何决策行为。日志落盘 `~/Library/Logs/FUnlock/decisions.jsonl`，字段白名单保证不落密码明文。
- **原因→文案/操作映射**（同文件末尾 `extension DecisionReason`）：编译期全覆盖 switch，派生 `ActionHint`（调低阈值 / 打开辅助功能 / 重输密码 / 跳转 Tab / 恢复自动解锁）。
- **埋点** `FUnlock/FUnManager.swift`：21 处解锁决策（17 个 SKIP 分支 + 4 个结果）+ 4 处系统事件（displaySleep/Wake、systemSleep/Wake）+ 2 处用户事件（userUnlocked/userLocked）+ 1 处锁屏（lockedAway/lockedLost）。
- **UI** `FUnlock/DiagnosticsView.swift`：侧边栏第 8 项「诊断」，决策时间线 + 分类过滤 chips + RSSI/设备名 + 上下文操作按钮 + 清空。
- **本地化** `Base.lproj`（英文）+ `zh-Hans.lproj` 各新增 48 key；其余语言回退 Base（本项目无 en.lproj）。

## 2. 当前 git 状态

分支 `main`，5 个提交（全部干净，pbxproj 仅含真实新增行）：

```
ba27227 i18n: 新增诊断 Tab 文案（Base + zh-Hans，其余语言回退英文） (Task 5)
49435ea feat: 新增「诊断」Tab 决策时间线 UI + 上下文操作按钮 (Task 4)
ad75645 feat: instrument unlock decisions in FUnManager (Task 3)
f8ba846 feat: 决策原因→文案/操作映射（编译期全覆盖 + 映射测试）
9066718 feat: DecisionLogger 决策记录器（环形缓冲 + 同因合并 + JSONL 持久化 + 轮转）
```

工作区无未提交源码改动。**未跟踪**（未入库，属正常）：`docs/superpowers/plans/2026-08-02-diagnostics-tab.md`、`docs/superpowers/specs/2026-08-02-diagnostics-tab-design.md`，以及同日一批无关的 `2026-08-02-audit-*.md` 文档。

## 3. ⚠️ 环境与操作要点（重要，务必先读）

- **Windows 侧的 Git 是 CRLF，仓库 blob 是 LF。** 编码/提交请在 WSL 完成，避免 pbxproj 全文件 diff 事故。WSL 已设 `core.autocrlf true`，但提交前仍建议：`git grep -l $'\r' -- 'FUnlock/*.swift' FUnlock.xcodeproj/project.pbxproj`（应输出为空）。
- **WSL 身份未配置**，每次提交必须带：
  `git -c user.name='傅哈布' -c user.email='jinfuaa@163.com' commit ...`
- **WSL 不能跑 xcodebuild / genstrings**（macOS 专属），编译与测试必须在 Mac 上执行。
- **Windows shell 是 PowerShell**：不要在命令里用 `&&`，用 `wsl -e bash -lc "..."` 包整条命令。

## 4. 下一步：Task 6（macOS 全量验证）— 由你在 Mac 上执行

**Step 1 — 全量单测：**
```bash
xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```
预期：既有测试全部 PASS + `DecisionLoggerTests`(8) + `ReasonActionMappingTests`(3) + `UnlockDecisionInstrumentationTests`(2) 全部 PASS。注意后两个集成测试用真实 `FUn()`（代价已知，与现有 `FUnlockTests` 一致）。

**Step 2 — 手动 QA（Debug 构建）：**
- 侧边栏出现第 8 项「诊断」（图标 `waveform.path.ecg`）。
- 空状态显示「暂无决策记录」。
- 设备远离再靠近：时间线「锁定 — 设备离开」→「解锁成功」，含 RSSI 与设备名。
- 信号不足：出现「信号未达解锁阈值」+「调低解锁阈值」按钮，点击后 `unlockRSSI` 降 5。
- 手动锁屏（⌘+Ctrl+Q）后设备靠近：出现「手动锁屏保护中」+「打开设置」（跳「锁定」Tab）。
- 撤辅助功能权限后触发注入：出现「辅助功能权限被撤销」+「打开辅助功能设置」。
- 重启 FUnlock：历史决策仍在（跨启动持久化）。
- 持续同类事件：3s 内只更新一条（同因合并），不刷屏。
- 「清空记录」后时间线为空，重启后仍为空。
- 中文系统显示中文、日文系统回退英文，无 key 字面量。
- 确认 `~/Library/Logs/FUnlock/decisions.jsonl` 存在、可读、无密码明文。
- 确认 `~/Library/Application Support/FUnlock/events.log` 未被污染。

**Step 3 — 收尾：** QA 有小修复则 `git add -A` + commit（`chore: 诊断 Tab 手动 QA 修复`）；无改动则跳过。

## 5. 已知风险 / 说明

- `DiagnosticsView.timeString` 用了 `date.formatted(.dateTime...)`，若部署目标报 deprecation 警告，属预期，不影响构建。
- pbxproj 新增固定 ID：`DL`（DecisionLogger）、`DT`（DecisionLoggerTests）、`RM`（ReasonActionMappingTests）、`DV`（DiagnosticsView），均 24 字符无冲突。Task 4 注册了 `DV000001/DV000002`（FileReference + Sources）。
- 埋点第 19 处 `unlockSuccess` 与第 20 处 `unlockFailed` 在 `tryUnlock()` 乐观解锁与 dual-verify 路径；第 21 处 `passwordMismatch` 在连续失败达上限时。
- `FUnManager.init` 新增 `decisionLogger:` 参数（默认 `.shared`），`attemptAutoUnlock()` 改为 internal 供测试驱动——如后续有其它 `FUnManager()` 调用点需核对默认参数可满足。

## 6. 相关文件

| 文件 | 说明 |
|---|---|
| `docs/superpowers/plans/2026-08-02-diagnostics-tab.md` | 实施计划（Task 1-6，含全部代码） |
| `docs/superpowers/specs/2026-08-02-diagnostics-tab-design.md` | 已批准规格 |
| `FUnlock/DecisionLogger.swift` | 记录器 + 映射扩展（Task 1/2） |
| `FUnlock/FUnManager.swift` | 埋点（Task 3） |
| `FUnlock/DiagnosticsView.swift` | 诊断 Tab UI（Task 4） |
| `FUnlock/MenuDashboardView.swift` / `SystemInteractionService.swift` | 第 8 Tab / openAccessibilitySettings（Task 4） |
| `FUnlockTests/DecisionLoggerTests.swift`（8+2 用例）、`ReasonActionMappingTests.swift`（3 用例） | 测试 |
| `FUnlock/Base.lproj/Localizable.strings`、`zh-Hans.lproj/Localizable.strings` | 本地化（Task 5） |
