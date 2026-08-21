# P2 诊断体验闭环设计（时间格式统一 + 一键导出 + DateFormatter 复用）

- **日期**：2026-08-21
- **分支**：`feat/2026-08-17`
- **前置**：`23ec9af refactor(log)` 已完成 P0+P1（串行队列、限流 key、密码脱敏、分级、节流、CSV 转义、readTail）
- **本轮范围**：P2-B（诊断体验闭环），剩余项留 handoff
- **涉及文件**：`DebugLog.swift` / `FUnlockUtils.swift`（timingLog）/ `TelemetryLogger.swift` / `ScriptRunner.swift` / `IMMessageComposer.swift` / `DiagnosticsView.swift` / `AppDelegate.swift`（可选）

## 1. 目标与成功标准

- **时间可对齐**：`debug.log` / `timing.log` / `shadow_telemetry.csv` / `events.log` 四文件时间格式统一为 `yyyy-MM-dd HH:mm:ss.SSS` + `en_US_POSIX` + 当前时区，跨文件可用 `grep` 按时间排序对齐。
- **一键导出**：诊断 Tab 提供「导出诊断包」按钮，打包 `debug.log` + `timing.log` + `decisions.jsonl` + `shadow_telemetry.csv` + `events.log` + `system_profiler` 快照（可选）为 zip，保存到用户自选路径。
- **性能收敛**：`ScriptRunner`（2 处）与 `IMMessageComposer`（1 处）的 `DateFormatter` 每次新建改为静态复用，与 `TelemetryLogger`/`DebugLog` 保持一致。
- **验证**：`BUILD SUCCEEDED` + `370/370` 测试通过 + 手动验证四文件时间格式一致 + 导出 zip 可解压且含全部文件。

## 2. 非目标

- 不做剩余 69 处 `Log.debug` 的全量分级细化（留 handoff）。
- 不做 `timingLog` 与 `DecisionLogger` 的语义收敛（业务 SKIP 仅由 DecisionLogger 承载，留 handoff）。
- 不引入第三方日志框架或新增落盘目录。

## 3. 方案

### 3.1 时间格式统一

**现状**：
- `debug.log`：`yyyy-MM-dd HH:mm:ss.SSS`（本次已改）
- `timing.log`：`now.formatted(date:.omitted, time:.standard)`（12 小时制本地化，不带日期）
- `shadow_telemetry.csv`：`yyyy-MM-dd HH:mm:ss.SSS`（静态复用）
- `events.log`：`yyyy-MM-dd HH:mm:ss`（无毫秒）与 `yyyy-MM-dd'T'HH:mm:ss`（T 分隔）

**改动**：
- 抽 `LogFormatting` 共享（可放在 `DebugLog.swift` 或新建 `LogFormatting.swift`，倾向复用 `DebugLog.dateFormatter` 的静态实例，避免新增文件）：
  - `static let fileDateFormatter: DateFormatter` — `en_US_POSIX` / `yyyy-MM-dd HH:mm:ss.SSS`
  - `static let csvFormatter` 已存在，统一指向同一实例或保持独立但格式一致
- `timingLog`：`now.formatted(...)` → `LogFormatting.fileDateFormatter.string(from: now)`，补全日期与毫秒
- `ScriptRunner.buildEventLine`：复用同一 formatter（或 `LogFormatting`）
- `ScriptRunner.runScript`：`yyyy-MM-dd'T'HH:mm:ss` 改为同一 formatter，前缀 `T` 仅在需要 ISO8601 时保留（脚本参数场景可保留 T，但统一用 `en_US_POSIX`）
- `TelemetryLogger`：已统一，无需改动
- `DecisionLogger`：JSON `secondsSince1970` 保持不变（结构化存储），导出时转换由诊断包处理（可选）

### 3.2 一键导出诊断包

**交互**：
- `DiagnosticsView` 工具栏新增「导出诊断包」按钮（与现有「清空」并列）
- 点击后 `NSSavePanel` 选择保存路径，默认 `FUnlock-diagnostics-YYYYMMDD-HHmmss.zip`
- 打包内容：`debug.log` / `timing.log` / `decisions.jsonl` / `shadow_telemetry.csv` / `events.log`（若存在），缺失文件跳过不报错
- 可选：`system_profiler SPHardwareDataType SPSoftwareDataType` 输出到 `system_info.txt` 一并打包（若权限/耗时允许，先做最小可用，不含 profiler 也可）

**实现**：
- 新增 `DiagnosticsExporter`（或 `DiagnosticsView` 内的 private helper）：
  - `func export(to url: URL) throws` — 用 `FileManager.zipItem` 或 `Process` 调用 `/usr/bin/zip`
  - 优先用 `FileManager.default.zipItem(at:to:shouldKeepParent:compressionMethod:progress:)`（macOS 10.11+），fallback 到 `Process` 调用 `zip`
  - 临时目录 `FileManager.default.temporaryDirectory + UUID` 拷贝文件后打包，打包后清理
- 按钮文案：`t("diagnostics_export")`，需在 `Localizable.strings` 新增中英 key（复用现有国际化模式）
- 错误处理：`NSAlert` 提示失败原因，不引入新依赖

### 3.3 DateFormatter 复用

- `ScriptRunner.swift:40` 与 `:88` — 提升为 `private static let`，`locale = en_US_POSIX`，复用 `LogFormatting` 或各自静态
- `IMMessageComposer.swift:68` — `timePart` 的 `DateFormatter` 提升为 `private static let timeFormatter`，`locale = en_US_POSIX`，`dateFormat = "HH:mm"`（仅时间部分无需毫秒）
- 验证：`grep -n "DateFormatter()" FUnlock --include="*.swift"` 仅剩静态定义处，其余为复用引用

## 4. 数据流与边界

- **落盘目录统一**：`~/Library/Logs/FUnlock/`（debug/timing/decisions/telemetry）与 `~/Library/Application Support/FUnlock/events.log` 保持现状，导出时跨目录收集
- **线程安全**：`LogFormatting` 的 `DateFormatter` 仅在各自队列/主线程内使用，或加 `NSLock`（`DateFormatter` 非线程安全，当前 `DebugLog` 在串行队列内使用安全，`timingLog` 在 `NSLock` 内使用安全，复用时保持同一约束）
- **文件不存在**：导出时缺失文件跳过，打包后 zip 内可能少于 5 个文件，属正常

## 5. 测试与验证

- `xcodebuild test` 370/370 通过（无新增测试，已有覆盖决策与遥测）
- 手动：连续触发解锁/锁屏，`cat ~/Library/Logs/FUnlock/debug.log | head` 与 `cat timing.log | head` 时间格式均为 `YYYY-MM-DD HH:mm:ss.SSS`
- 手动：诊断 Tab 点击导出，选择路径后解压 zip，校验含 4-5 个日志文件且时间可对齐
- 静态：`grep -rn "DateFormatter()" FUnlock --include="*.swift"` 仅静态定义，`grep -rn "formatted(date:" FUnlock` 为 0

## 6. 风险与回滚

- **风险**：`DateFormatter` 复用若跨线程使用会数据竞争。缓解：保持现有队列/锁约束，不跨队列共享可变实例；或每个文件独立静态实例
- **回滚**：本轮改动仅涉及格式化与导出工具，不碰业务逻辑与蓝牙流程，可单独 revert

---

## Handoff — 下次继续（P2 剩余）

> **给下一位接手同学**：本轮仅完成诊断体验闭环（P2-B），以下项已明确、有上下文，可直接按此清单开干，无需重新审计。

### 待办清单

| # | 事项 | 现状与上下文 | 建议做法 | 预估 |
|---|------|-------------|---------|------|
| H1 | 剩余 `Log.debug` 分级细化（约 69 处） | `Log.swift` 已立分级规范（debug/info/error/fault），P1 已升级 14 处代表性点，剩余 69 处仍全为 `debug`。`FUnManager` 的 `SKIP` 分支、`FUn` 的状态流转需逐条过 | 按 `Log.swift` 注释约定批量替换：状态机流转→`info`，异常→`error`。用 `grep -rn "Log\.\(sm\|ble\|dev\)\.debug" FUnlock --include="*.swift"` 逐文件过 | 约 1 小时 |
| H2 | `timingLog` 与 `DecisionLogger` 语义收敛 | 同一 `SKIP` 同时写 `timing.log`（自由文本）与 `decisions.jsonl`（结构化含 rssi/device/screen），诊断 Tab 仅消费后者，前者仅人肉看。`FUnManager.swift:551-553` 等处三重日志 | `timingLog` 仅保留性能埋点（`verifyUnlock`、`keystrokeLevel`），业务 SKIP 完全由 `DecisionLogger` 承载；或将 `timingLog` 降为 `DecisionLogger.detail` | 约 1 小时 |
| H3 | `iMessageNotifier` 静默丢弃进诊断 | `iMessageNotifier.swift:80` 发送失败仅 `Log.ble.error`，不进 `DecisionLogger`，诊断 Tab 不可见 | 失败分支追加 `DecisionLogger.shared.record(category:.system, reason:.abnormalAlert, detail: error)` | 约 15 分钟 |
| H4 | 全量格式统一收尾 | 本轮已统一 4 文件的 `yyyy-MM-dd HH:mm:ss.SSS`，但 `DecisionLogger` 的 `secondsSince1970` 与 `IMMessageComposer` 的 `HH:mm` 属合理例外，无需强行统一。H4 视为已完成，无需再动 | — | — |

### 接手步骤

1. 从 `git log --oneline` 确认 `23ec9af`（P0+P1）与本轮 P2-B 提交已在 `feat/2026-08-17`
2. `grep -rn "Log\.\(sm\|ble\|dev\)\.debug" FUnlock --include="*.swift" | wc -l` 确认剩余数量
3. 按 H1→H2→H3 顺序执行，每项独立提交，保持 `refactor(log):` 前缀与 `ponytail` 风格
4. 验证：`BUILD SUCCEEDED` + `370/370` + Console 按 level 过滤可见分级

### 参考

- 本设计文档：`docs/superpowers/specs/2026-08-21-p2-diagnostics-handoff-design.md`
- 前轮计划：`.claude/plans/curried-foraging-starfish.md`
- 审计清单：本轮对话中 14 项优化清单（P0 4 + P1 4 + P2 6）
