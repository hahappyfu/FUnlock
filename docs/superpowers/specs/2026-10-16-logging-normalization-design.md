# FUnlock 日志规范化改造设计

日期：2026-10-16
状态：已获用户批准

## 背景与问题

FUnlock 当前有 5 套并存的日志通道，排查问题体验差：

| 通道 | 落点 | 规模 | 问题 |
|------|------|------|------|
| `Log.sm/ble/dev`（os.Logger） | Console/系统日志 | ~96 处 | debug 级被系统过滤，实际排查时看不到 |
| `logDebug(component:_:)` | `~/Library/Logs/FUnlock/debug.log` | 45 处 | component 标签随意，消息混着手写前缀 `[SM]`/`[DIAG]`/`[LOCK]` |
| `lockLog` | 同 debug.log（仅包一层） | 18 处 | 假独立通道 |
| `timingLog` | `timing.log` | 36 处 | 与 DebugLog 重复实现滚动/句柄逻辑 |
| `DecisionLogger` / `TelemetryLogger` | `decisions.jsonl` / `shadow_telemetry.csv` | 结构化 | 本身规范，不动 |

典型病灶：`onDisplaySleep` 一个事件写 3 行日志，两个通道措辞不同；13 处裸 `Logger(`、1 处 `print(`。

## 目标

一次日志调用同时写 os.log 与 debug.log，措辞一致、格式可 grep 可机器解析，为排查问题服务。

## 设计

### 统一门面 AppLog

新建 `FUnlock/AppLog.swift`：

```swift
enum AppCategory { case sm, ble, unlock, lock, app }
enum AppLogLevel { case debug, info, error, fault }

enum AppLog {
    static func debug(_ category: AppCategory, _ event: String, _ fields: [(String, String?)] = [])
    static func info(...)   // 同签名
    static func error(...)
    static func fault(...)
}
```

调用形态：

```swift
AppLog.info(.sm, "displayWake", [("screen", "locked(away)"), ("isSelfWake", "true")])
```

**双通道一次写**：内部同时调 os.Logger（category 映射到现有 `Log.sm/ble/dev` 实例，保留 Console 可见性）和 `DebugLog`（debug.log 落盘，复用现有串行队列与滚动逻辑）。

debug.log 行格式：

```
[2026-10-16 14:32:01.123] [SM] event=displayWake screen=locked(away) isSelfWake=true
```

- category 标签收敛为 5 个枚举值（SM/BLE/UNLOCK/LOCK/APP）
- 手写中括号前缀全部删除，信息进 event/fields
- value 含空格的用引号包住：`detail="屏幕已解锁"`
- nil 字段直接省略

### category 词汇表

| category | 含义 | 原 component / Logger |
|----------|------|----------------------|
| sm | 状态机流转与系统事件（睡眠/唤醒/解锁/锁屏事件入口） | StateMachine、BLE(事件层)、SM |
| ble | 蓝牙扫描、信号处理、RSSI 原始数据 | BLE、FUn、Device |
| unlock | 解锁编排（门控、注入、验证、重试） | FUnManager、UnlockOrchestrator |
| lock | 锁屏判定与执行 | Lock |
| app | 生命周期、权限、配置、SQLite 等 | AppDelegate、DIAG |

### level 判定标准

- **debug**：高频原始数据（RSSI 采样、didDiscover、updateMonitored）
- **info**：状态机流转与业务分支结果（SKIP 原因、displaySleep/Wake、门控通过/拒绝）
- **error**：异常与失败（CGEvent 失败、连接超时、DB prepare 失败）
- **fault**：需人工介入的严重异常（当前暂未使用）

### event 命名约定

- 动词短语，camelCase：`displayWake`、`unlockSkip`、`gateReject`、`bleScanRestart`
- 同一事件的正向与拒绝拆开：`unlockStart` / `unlockSkip(reason=...)`

## 迁移范围（约 190 处调用点）

1. `Log.sm/ble/dev.*`（96 处）→ AppLog；调用点清零后 `Log` 枚举收编进 AppLog 内部（保留 os.Logger 实例）
2. `logDebug(component:_:)`（45 处）、`lockLog`（18 处）→ AppLog；两个顶层函数删除
3. 裸 `Logger(`（13 处）→ AppLog；`print(`（1 处）→ AppLog
4. `timingLog`（36 处）：保留独立文件与 1 秒同文案限流语义，仅消息格式对齐为 `event=xxx key=value`；滚动/句柄逻辑不动
5. `throttledBleLog`：签名保留，内部改走 `AppLog.debug(.ble)`
6. `DecisionLogger` / `TelemetryLogger`：完全不动
7. `SystemInteractionService.logBoth`：删除，AppLog 天然双写

## 测试

- AppLog 单元测试：格式拼接（key=value、nil 省略、含空格加引号）、category 映射、双通道都收到
- 现有 `LogRotationTests` / `TelemetryLoggerTests` 不动，应全绿
- 全量 `swift test`（447 个测试）回归通过

## 文档

`docs/logging.md` 一页：category 词汇表、level 判定标准、event 命名约定、排查示例：

```bash
grep 'event=displayWake' ~/Library/Logs/FUnlock/debug.log
grep 'category=UNLOCK.*reason=' ~/Library/Logs/FUnlock/debug.log
```

## 明确不做

- 不引入日志框架依赖（swift-log 等）
- 不做采样/过滤运行时配置
- 不改日志文件位置与滚动策略
- 不动 DecisionLogger / TelemetryLogger
