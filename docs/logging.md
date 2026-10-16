# FUnlock 日志规范与排查指南

FUnlock 采用统一日志门面 `AppLog`，实现一次调用同时写入系统日志（os.log）与本地文件（debug.log）。本文档定义日志的落盘位置、行格式、分类词汇、级别标准、命名规范与常用排查命令。

---

## 1. 落盘位置

| 文件 / 通道 | 完整路径 / 标识 | 滚动策略与限流 | 说明 |
|---|---|---|---|
| 统一调试日志 | `~/Library/Logs/FUnlock/debug.log` | 单文件上限 5 MB（`LogRotator.defaultMaxBytes = 5 * 1024 * 1024` 字节），超过后归档为 `debug.log.old`（保留 1 份备份）并新建文件 | 记录所有 category 的全量调试信息，经由串行队列线程安全异步写入 |
| 时序埋点日志 | `~/Library/Logs/FUnlock/timing.log` | 单文件上限 5 MB，归档为 `timing.log.old`；同文案 1 秒内限流最多写 1 条 | 记录关键业务节点时序（睡眠、唤醒、锁屏、解锁执行），复用文件句柄避免阻塞主线程 |
| 决策审计记录 | `~/Library/Logs/FUnlock/decisions.jsonl` | 独立维护（追加写入） | 业务决策流水线记录（非本次门面改造范围） |
| 影子遥测数据 | `~/Library/Logs/FUnlock/shadow_telemetry.csv` | 独立维护（`TelemetryLogger` 滚动） | 信号算法遥测数据（非本次门面改造范围） |
| 系统日志 | `os.log`（subsystem: `com.funlock.app`） | 系统统一管理 | 采用 public privacy 级别输出，Console 与命令行可查 |

---

## 2. 行格式

`debug.log` 每行遵循固定的结构化格式：

```
[2026-10-16 14:32:01.123] [UNLOCK] event=unlockStart screen=locked(away) locked=true
```

- **时间戳**：`yyyy-MM-dd HH:mm:ss.SSS`（使用 `en_US_POSIX` 本地化生成）。
- **Category 标签**：`[SM]`、`[BLE]`、`[UNLOCK]`、`[LOCK]`、`[APP]`，对应 5 种业务领域分类。
- **结构化字段**：`event=<name> key1=value1 key2=value2 ...`
  - 第一个字段必须为 `event=<eventName>`。
  - `nil` 字段会自动省略，不输出空键。
  - 当字段值包含空白字符（如空格）或非 ASCII 字符（如中文）时，门面自动用双引号包裹，例如：`detail="屏幕已解锁"`。
- **无手写前缀**：禁止在日志消息中自行书写 `[SM]`、`[DIAG]` 等中括号前缀，分类完全由 category 参数保证。

---

## 3. Category 词汇表

系统严格收敛为 5 个 category，并映射到底层 os.Logger 实例：

| Category | 标签 | 用途与职责 | 对应 os.Logger | 涵盖模块与源码文件 |
|---|---|---|---|---|
| `sm` | `[SM]` | 状态机流转与系统事件（睡眠、唤醒、锁屏/解锁系统通知入口、信号响应） | `Log.sm` (`StateMachine`) | `FUnManager+Events.swift`<br/>`FUnManager.swift`<br/>`FUnSignalProcessor.swift`<br/>`SystemInteractionService.swift` |
| `ble` | `[BLE]` | 蓝牙扫描、外设连接状态、信号强度处理、RSSI 原始采样 | `Log.ble` (`BLE`) | `BLEScanner.swift`<br/>`BLEPeripheralHandler.swift`<br/>`FUn.swift`<br/>`FUnSignalProcessor.swift` |
| `unlock` | `[UNLOCK]` | 解锁编排管线（门控校验、密码提取、CGEvent 注入、验证、重试） | `Log.sm` (`StateMachine`) | `UnlockOrchestrator.swift`<br/>`UnlockOrchestrator+AutoUnlock.swift`<br/>`SystemInteractionService.swift` |
| `lock` | `[LOCK]` | 锁屏判定与执行（离开超时、自动锁屏触发、手动快捷锁定） | `Log.sm` (`StateMachine`) | `FUnLockCoordinator.swift`<br/>`FUnManager+Events.swift` |
| `app` | `[APP]` | 应用生命周期、权限检查、配置读写、SQLite 数据持久化、外部通知与杂项 | `Log.dev` (`Device`) | `AppDelegate.swift`<br/>`ConfigStore.swift`<br/>`SecurityService.swift`<br/>`LEDeviceInfo.swift`<br/>`WiFiMonitor.swift`<br/>`iMessageNotifier.swift`<br/>`BasicSettingsView.swift`<br/>`DecisionLogger.swift`<br/>`SystemInteractionService.swift` |

---

## 4. Level 判定标准

| Level | 适用场景 | 典型事件 |
|---|---|---|
| **debug** | 高频原始数据、详细排查细节 | RSSI 采样、`didDiscover`、`updateMonitored` |
| **info** | 状态机流转、业务决策分支结果、正常流程起止 | `displaySleep`、`displayWake`、`unlockStart`、`unlockSkip(reason=...)`、`gatePass`、`gateReject` |
| **error** | 操作失败、异常分支、权限拒绝 | CGEvent 事件注入失败、BLE 连接超时、Keychain 读取失败、SQLite prepare 失败 |
| **fault** | 需人工介入的致命系统异常 | 严重内存损坏、不可恢复的底层状态冲突（当前预留，代码暂未使用） |

---

## 5. Event 命名约定

1. **camelCase 动词短语**：
   使用动词开头的驼峰命名，例如 `displayWake`、`unlockStart`、`gateReject`、`bleScanRestart`。
2. **正向与分支拆开**：
   正向成功与跳过/失败不要混用同一事件名称。
   - 正向：`unlockStart`、`unlockSuccess`
   - 跳过：`unlockSkip`，并通过 `reason` 字段标明具体原因（如 `reason=screenNotLocked`、`reason=gateRejected`）。
3. **跨通道命名倾向性对齐**：
   当 `AppLog` 与 `timingLog` 记录的是**同一个业务事件或决策分支**时，约定使用相同的 event 名字（如 `unlockSkip`、`injectPasswordStart`），便于后续联合排查时跨日志关联检索（如 `grep -h 'event=unlockSkip' debug.log timing.log`）。

   > **注意通道粒度差异**：两通道并非 1:1 硬性镜像。`timingLog` 是纯时序性能埋点通道，侧重于记录函数入口与细粒度时序节点；`AppLog` 是业务日志通道，侧重于记录业务阶段起止与决策结果。因此跨通道命名为**倾向性约定**而非硬性一致。
   >
   > - **同名对齐事件（共 8 个）**：`unlockSkip`、`injectPasswordStart`、`delayedUnlockTaskStart`、`delayedUnlockTaskCancelled`、`parallelWakeUnlockStart`、`deviceApproached`、`keystrokeLevelSuccess`、`keystrokeLevelFailed`。
   > - **timingLog 独有时序事件（共 10 个）**：`tryUnlockEnter`（函数入口时刻，对应 AppLog 业务起始 `unlockStart`）、`guardFetchPassword`（密码前置检查时刻）、`verifyUnlockDone`（双重验证执行完毕时刻，对应 AppLog 的 `dualVerifyConfirmed` 等）、`attemptAutoUnlock`、`parallelUnlockTaskFired`、`delayedUnlockTaskFired`、`startWakeRetryBegin`、`wakeAttemptDone`、`wakeSucceeded`、`wakeFailed`。排查时在 `AppLog` 未搜到此类细粒度时序事件属于正常设计预期，非日志遗漏。

   **关键阶段对照参考**：

   | 业务阶段 / 时序节点 | AppLog Event | timingLog Event | 关联说明 |
   |---|---|---|---|
   | 解锁流程发起 | `unlockStart` | `tryUnlockEnter`<br/>`guardFetchPassword` | 粒度差异：`timingLog` 记录函数入口与密码前置检查微观时刻；`AppLog` 记录业务解锁开始 |
   | 解锁前置跳过分支 | `unlockSkip` | `unlockSkip` | **同名对齐**：均携带 `reason=...`，用于跨文件联合分析与过滤 |
   | 密码注入开始 | `injectPasswordStart` | `injectPasswordStart` | **同名对齐**：时序埋点与业务起点一致 |
   | 按键事件逐级注入 | `keystrokeLevelSuccess`<br/>`keystrokeLevelFailed` | `keystrokeLevelSuccess`<br/>`keystrokeLevelFailed` | **同名对齐**：1~3 级注入成败双写对齐 |
   | 并发与延时任务生命周期 | `parallelWakeUnlockStart`<br/>`delayedUnlockTaskStart`<br/>`delayedUnlockTaskCancelled` | `parallelWakeUnlockStart`<br/>`delayedUnlockTaskStart`<br/>`delayedUnlockTaskCancelled` | **同名对齐**：异步并发与延时任务生命周期对齐 |
   | 设备接近信号触发 | `deviceApproached` | `deviceApproached` | **同名对齐**：门控前置触发时刻对齐 |
   | 验证与时序完成 | `dualVerifyConfirmed`<br/>`dualVerifyPassed` | `verifyUnlockDone`<br/>`delayedUnlockTaskFired`<br/>`parallelUnlockTaskFired` | 粒度差异：`timingLog` 记录耗时打点（含唤醒重试 `wakeAttemptDone`、`wakeSucceeded` 等）；`AppLog` 记录验证结果 |

---

## 6. 排查示例

以下为常见故障定位与日志检索的终端命令：

```bash
# 1. 查看某次屏幕唤醒的完整流转
grep 'event=displayWake' ~/Library/Logs/FUnlock/debug.log

# 2. 查看所有被拒绝或跳过的解锁尝试及原因
grep 'event=unlockSkip' ~/Library/Logs/FUnlock/debug.log

# 3. 只查看解锁编排层相关事件
grep '\[UNLOCK\]' ~/Library/Logs/FUnlock/debug.log

# 4. 只查看状态机流转事件
grep '\[SM\]' ~/Library/Logs/FUnlock/debug.log

# 5. 跨通道关联同一个事件（debug.log 与 timing.log 按时序合并检索）
grep -h 'event=unlockSkip' ~/Library/Logs/FUnlock/debug.log ~/Library/Logs/FUnlock/timing.log | sort

# 6. 查看系统日志（os.log）中最近 10 分钟的 FUnlock 日志
log show --predicate 'subsystem == "com.funlock.app"' --last 10m

# 7. 实时监听 FUnlock 的系统日志输出
log stream --predicate 'subsystem == "com.funlock.app"' --level debug
```

---

## 7. 新增日志规范

业务代码**严禁**直接调用 `Log.sm` / `Log.ble` / `Log.dev` 枚举或 `DebugLog.log`，必须统一走 `AppLog` 门面：

```swift
// 1. 无附加字段的简单事件
AppLog.info(.unlock, "unlockStart")

// 2. 带结构化键值对的事件（nil 字段自动过滤，含中文或空格的值自动加引号）
AppLog.info(.unlock, "unlockSkip", [
    ("reason", "screenNotLocked"),
    ("detail", "屏幕当前已处于解锁状态")
])

// 3. 错误与异常日志
AppLog.error(.app, "keychainReadFailed", [
    ("status", String(status)),
    ("account", account)
])

// 4. 高频调试数据
AppLog.debug(.ble, "rssiSample", [
    ("device", deviceId),
    ("rssi", String(rssi))
])
```
