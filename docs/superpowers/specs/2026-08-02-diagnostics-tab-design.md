# FUnlock 设计规格：「诊断」Tab —— 解锁/锁屏决策时间线

> 状态：已批准（2026-08-02）。捕获机制采用「方案 1：决策记录器（DecisionLogger）」。

## 目标

把散落在 `os.Logger` debug 日志与 `events.log` 里的「为什么没解锁 / 为什么锁屏」原因，变成用户可读、可操作的**决策时间线**：

1. 用户能回溯「刚才为什么没解锁」——信号不足 / 冷却中 / 手动锁屏保护 / 权限被撤 / Keychain 冷启动等，并获得对应操作建议。
2. 用户能回溯「为什么锁了屏」——设备离开 / 信号丢失 / 输入活动等。
3. 所有原因结构化、可本地持久化、可测试，作为后续「自适应阈值」「成功率量化」等方向的数据地基。

## 背景与现状

- `FUnManager` 的决策路径里已有 17 处 `Log.sm.debug("SKIP: ...")` 分支（`no presence`、`unlock cooldown active`、`manualLock active`、`Keychain error`、`screen no longer secure` 等），**原因已经存在，但没有面向用户暴露**。
- 但 `SKIP:` 用的是 `os.Logger` debug 级，**Release 下会被过滤**，不能作为运行时数据源。诊断面板必须有自己的结构化决策事件记录器，而不是解析 os.Logger。
- `events.log`（`ScriptRunner`）已有 `unlock_confirmed / unlock_failed / locked:*` 等结果事件，但有 3 秒去重窗口，且服务于用户脚本/统计口径，**不能往里塞高频决策事件**（会污染统计与脚本事件流）。
- `MenuDashboardView` 现有 7 个侧边栏 Tab，本功能新增第 8 个「诊断」。

## 设计原则

1. 不侵入核心安全逻辑：只做「观察 + 记录」，不改变解锁/锁屏决策本身。
2. 不污染既有日志口径：`events.log`、`ScriptRunner`、`StatsView` 统计保持不变。
3. 决策原因结构化：原因用枚举表达，天然映射「操作按钮」与本地化文案。
4. 可降级：持久化失败静默回退内存态，不影响任何决策流程。
5. 隐私红线：决策日志绝不落盘密码明文。
6. 可测试：记录器支持注入时钟 + 注入目录，合并/轮转/持久化全部可单测。

## 方案总览

### 1. 数据模型

#### 1.1 决策事件 `DecisionEvent`

值类型、`Codable`、每事件一行 JSON（JSON Lines）：

| 字段 | 类型 | 说明 |
|---|---|---|
| `timestamp` | `Date` | 事件时间 |
| `category` | `Category` | `.unlock` / `.lock` / `.system` / `.user` |
| `outcome` | `Outcome` | `.success` / `.skipped` / `.failed` / `.blocked` / `.info` |
| `reason` | `UnlockReason?` / `LockReason?` | 结构化原因（`system`/`user` 类事件可为 nil） |
| `rssi` | `Int?` | 信号值（dBm） |
| `device` | `String?` | 设备显示名 |
| `screen` | `String?` | 当时屏幕状态快照 |
| `detail` | `String` | 人话补充（如 "信号 -72 dBm < 解锁阈值 -60"） |

#### 1.2 解锁侧原因枚举 `UnlockReason`

枚举 case 直接对齐 `FUnManager` 现有 SKIP 分支，每个 case 有一个 `ActionHint?`：

| reason | 含义 | ActionHint（操作按钮） |
|---|---|---|
| `.noPresence` | 设备不在场 | 无（信息） |
| `.signalBelowThreshold` | 信号未达解锁阈值 | 调低解锁阈值（一键 apply，`setUnlockRSSI - 5 dBm`） |
| `.unlockCooldownActive` | 刚解锁过，冷却中 | 无 |
| `.lockBufferActive` | 刚锁屏，缓冲期 | 无 |
| `.manualLockActive` | 手动锁屏保护中 | 跳「锁定」Tab |
| `.wifiPaused` | 命中暂停 Wi-Fi | 跳「网络」Tab |
| `.disabled` | 总开关关闭 | 跳「设置」Tab 启用 |
| `.stateMachineBlocked` | 降级 / 失败冷却 | 恢复自动解锁（重置） |
| `.axRevoked` | 辅助功能权限被撤 | 打开系统「辅助功能」设置 |
| `.passwordMismatch` | 密码错误 | 重新输入密码（复用现有录入弹窗） |
| `.noPassword` | 未设置密码 | 引导设置密码 |
| `.keychainColdBoot` | Keychain 冷启动未解锁 | 提示手动解锁一次 |
| `.notSecureForInjection` | 前台不是登录窗 | 无 |
| `.displaySleeping` | 显示器休眠中 | 无 |
| `.systemNotReady` | 系统休眠/未就绪 | 无 |

#### 1.3 锁屏侧原因枚举 `LockReason`

| reason | 含义 | ActionHint |
|---|---|---|
| `.inputActive` | 输入活动中暂缓锁屏 | 无 |
| `.gracePeriod` | 刚解锁冷静期 | 无 |
| `.signalBelowLockThreshold` | 信号未达锁屏阈值 | 调低锁屏阈值 |

#### 1.4 结果事件（非 SKIP，category 直接表达）

- `unlock_success`（category `.unlock`, outcome `.success`）
- `unlock_failed` / `unlock_timeout`（`.failed`）
- `locked_away` / `locked_lost`（category `.lock`, outcome `.success`）
- 系统：`display_sleep` / `display_wake` / `system_sleep` / `system_wake`（category `.system`, outcome `.info`）
- 用户：`user_unlocked` / `user_locked`（category `.user`）

#### 1.5 操作提示 `ActionHint`

编译期 switch 保证每个枚举 case 都有映射（或显式 `nil`）。`ActionHint` 含：`titleKey`（按钮文案）、`action`（跳 Tab / 打开系统设置 / 调阈值 / 弹密码窗 / 重置）。

### 2. 架构与数据流

```
FUnManager 决策点（17 处 SKIP 分支 + tryUnlock 结果 + lock 触发）
        │ DecisionLogger.shared.record(event)
        ▼
┌─ DecisionLogger ─────────────────────────────────────────┐
│  主线程：追加到内存环形缓冲 RingBuffer(500)                │
│  同因合并：连续相同 (category, reason, outcome) 且          │
│    间隔 < 3s → 更新上一条 timestamp，不新增（防心跳洪水）  │
│  更新 @Published snapshot（UI 直接观察）                   │
│  异步 utility 队列：JSON Line 追加持久化                  │
└──────────────────────────────────────────────────────────┘
        │
        ▼
  ~/Library/Logs/FUnlock/decisions.jsonl
  读取：DiagnosticsView onAppear 读文件尾部 ~500 条灌入 ring，之后实时追加
  轮转：文件 > 1MB → 截断，仅保留缓冲中最新的条目
```

**组件：**

- `DecisionLogger`：单例（仿 `TelemetryLogger`），主线程 `record`，异步持久化。支持 `testLogDirectory`（测试注入）与 `nowProvider: () -> Date`（时间注入，沿用 `FUnlockStateMachine.init(nowProvider:)` 模式）。
- `DecisionStore`：`ObservableObject`，持有 `RingBuffer<DecisionEvent>` + `@Published var events`。`record` 后触发快照更新（`FUnManager` 本就在 `@MainActor`，无需额外定时器）。
- `DiagnosticsView`：第 8 个侧边栏 Tab。

**关键规则：**

1. **同因合并（coalescing）**：`(category, reason, outcome)` 相同且间隔 < 3s → 只更新上一条的 `timestamp`（时间线显示持续）。原因变化 / 间隔超窗 → 新增。防心跳（每 2s）刷屏成 `noPresence` 流水。
2. **持久化失败静默降级**：文件写失败不影响决策流程，仅回退内存态，`Log.sm` 记一条。
3. **隐私**：持久化前断言序列化 JSON 不含密码明文关键字；字段仅设备名 / RSSI / 原因 / 屏幕状态。
4. **测试注入**：`testLogDirectory: URL?` + `nowProvider`，合并 / 轮转 / 持久化往返全部可单测。

### 3. UI ——「诊断」Tab

**入口**：侧边栏新增第 8 项「诊断」，SF Symbol `waveform.path.ecg`，置于 StatsView 之后。

**布局**（自上而下）：

- 标题「诊断」+ 副标题「FUnlock 决策时间线」。
- 过滤器 chips：`全部 / 解锁 / 锁屏 / 系统 / 用户`（按 `category` 过滤）。
- 时间线列表（`LazyVStack`，只渲染可见行）：
  - 图标：category × outcome 决定（🔓 成功 / 🔒 跳过 / 🔐 锁定 / ⚠️ 失败）。
  - 相对时间（复用 `RelativeDateTimeFormatter` 习惯；> 24h 显示绝对时间）。
  - 标题 + 设备名 + RSSI。
  - 原因行：本地化文案；有 `ActionHint` 时行尾渲染操作按钮。
- 空状态：`暂无决策记录` + 一句说明。
- 底部：「清空记录」（仅清本地决策日志，不影响 `events.log`）。

**操作按钮动作目标（复用现有服务）：**

- 「调低解锁阈值」→ `FUnManager.setUnlockRSSI` 减 5 dBm。
- 「打开辅助功能设置」→ `SystemInteractionService` 打开系统辅助功能设置（若已存在则复用，否则新增 `openSystemPreferences(.accessibility)`）。
- 「重新输入密码」→ 复用现有密码录入弹窗。
- 「启用 FUnlock / 关闭手动锁屏保护 / 打开网络设置」→ 跳对应侧边栏 Tab。

### 4. 本地化

v1 新增约 **20 条字符串 × zh-Hans / en 两种语言**；其余语言（ja/de/sv/nb/da/tr）**回退英文**（缺失 key 用英文兜底，与现有 `t()` 回退机制一致）。后续版本补齐。

## 任务拆分

### 任务 1：决策模型 + 记录器

**文件**：新增 `FUnlock/DecisionLogger.swift`（含 `DecisionEvent`、`UnlockReason`、`LockReason`、`ActionHint`、`DecisionStore`、`DecisionLogger`、`NSLock.withLock` 复用）。

**验收**：
- `record` 后进入 ring 并触发 `@Published` 快照。
- 同因合并：3s 内同 `(category, reason, outcome)` 不新增；超窗/原因变化新增。
- 持久化 JSONL 追加 + >1MB 轮转。
- 测试注入目录生效，不碰真实 `~/Library/Logs`。

### 任务 2：FUnManager 埋点

**文件**：修改 `FUnlock/FUnManager.swift`。

**范围**：把 17 处 `Log.sm.debug("SKIP: ...")` 分支与 `tryUnlock` 结果、lock 触发点，在打日志的同时调用 `DecisionLogger.shared.record(...)`（保留原日志）。结果确认用 `unlock_confirmed / unlock_failed` 语义对齐 `ScriptRunner`。

**验收**：
- 每个 SKIP 分支对应一个 `UnlockReason` case（可用测试断言「冷却中」分支产生 `.unlockCooldownActive`）。
- 不改变任何决策行为，不改变 `events.log` 输出。

### 任务 3：诊断 Tab UI

**文件**：新增 `FUnlock/DiagnosticsView.swift`；修改 `FUnlock/MenuDashboardView.swift`。

**范围**：侧边栏第 8 项 + 时间线视图 + 过滤器 + 操作按钮 + 空状态 + 清空记录。

**验收**：onAppear 读持久化尾部灌入 ring；实时追加；过滤器生效；按钮触发正确动作。

### 任务 4：本地化

**文件**：`FUnlock/zh-Hans.lproj/Localizable.strings`、`FUnlock/en.lproj/Localizable.strings`（新增 `diagnostics_*`、`reason_*`、`action_*` key）；`FUnlock/LocalizedStringKey` 映射（若走 `t()`）。

**验收**：中文系统显示中文；日文等系统回退英文；无缺失 key 警告。

### 任务 5：测试 + 回归

**文件**：新增 `FUnlockTests/DecisionLoggerTests.swift`、`FUnlockTests/ReasonActionMappingTests.swift`；修改 `FUnlockTests/FUnlockTests.swift`（集成断言，依赖审计 P5 注入落地）。

**验收**：
- 单测：记录 / 合并 / 持久化往返 / 轮转 / 失败降级 / 隐私断言（序列化不含密码）。
- 映射测试：每个枚举 case 有 `ActionHint`（或显式 nil）。
- 集成：注入 mock `DecisionLogger`，断言「冷却中」「手动锁屏保护」分支产生对应事件。
- 手动 QA：解锁成功 / 信号不足（点按钮降阈值）/ 离开锁屏 / 撤权限（axRevoked + 跳转）/ 冷启动（keychainColdBoot）/ 总开关关闭（disabled）。

## 验收分级

### Critical

- 不改变任何解锁/锁屏决策行为（纯观察，行为回归 = 失败）。
- 不污染 `events.log` 与统计口径。
- 决策日志绝不落盘密码明文。

### Important

- 同因合并不丢「原因变化」；3s 窗口可调。
- 操作按钮动作正确（跳 Tab / 系统设置 / 阈值 apply）。
- 持久化往返与轮转正确，重启后可回溯。

### Minor

- 相对时间格式、空状态文案打磨。
- 其余语言翻译补齐（后续版本）。

## 风险与降级策略

### 风险 1：埋点漏掉部分决策分支

降级：集成测试用「注入 mock 断言关键分支产生事件」作为回归约束；映射测试编译期兜底新 case。

### 风险 2：同因合并吞掉真实原因变化

降级：窗口仅合并「连续同因」，任何原因变化立即新增；窗口值收敛为常量 `coalescingWindow`，可调。

### 风险 3：持久化文件膨胀 / 写入失败

降级：>1MB 轮转截断；写失败静默回退内存态；文件仅本地，无网络路径。

### 风险 4：操作按钮误触改变用户设置

降级：按钮动作均需明确确认（如阈值调整弹确认）；纯解释的行不渲染按钮。

## 成功标准

发布后应满足：

1. 用户能在「诊断」Tab 看到最近解锁/锁屏的完整决策时间线与原因。
2. 「信号不足 / 权限被撤 / 冷启动 / 手动锁屏保护」等常见"为什么没解锁"场景都有一目了然的原因和操作入口。
3. 心跳不刷屏（同因合并生效）。
4. 重启后仍能回溯之前会话的决策记录。
5. 中文 / 英文正确显示，其余语言不出现缺失 key 的 `key` 字面量。

## 不在本次范围内

- 自适应阈值自动调优（依赖本功能沉淀的决策数据，后续方向）。
- 解锁成功率统计面板（可基于 `DecisionEvent` 数据后续做）。
- 遥测上传 / 云同步（隐私方向另行决策）。
- 改变任何核心解锁/锁屏逻辑。
- 签名与公证分发改造（独立计划）。

## 附：与现有/进行中工作的关系

- **依赖**：审计 P1（`IsolatedTestCase`、`ScriptRunner.testLogFileOverride`）提供测试隔离模式；P5（FUnManager 依赖注入）提供集成测试挂钩。
- **不依赖也不阻塞**：P2/P3/P4/P6。
- **新增数据资产**：`decisions.jsonl` 是「自适应阈值」「成功率量化」的产品地基，本功能为其补齐采集层。
