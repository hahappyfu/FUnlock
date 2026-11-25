# FUnlock 终局单进程架构重设计规格（方案 A）

- **日期**：2026-11-25
- **目标仓库**：`/Volumes/SSD/fuhaha_workspace/FUnlock`（Xcode 工程 `FUnlock.xcodeproj`，macOS 14.0+，Swift 5.9+，`SWIFT_STRICT_CONCURRENCY = complete`）
- **状态**：Ready for Approval（已通过独立 Builder Check 审查并补齐边界契约）
- **协同分工**：架构设计、核心状态机与安全关键路径、每阶段 Code Review 由 **Antigravity** 主导；机械模块抽离、Xcode 工程接线、样板代码重构、文案清理与命令行测试执行由 **Claude Desktop**（经 `agent-hud` 调度）配合完成。

---

## 1. 意图与背景（Intent & Why）

FUnlock 在保留「**免装手机端 App、免装 root 系统插件、拖入 `/Applications` 即用**」这一核心产品护城河的前提下，历经多轮功能迭代与 2026-11-24 的 22 项安全审计修复，核心滤波算法（`SignalPipeline`）、迟滞策略（`SignalHysteresisEngine`）与精密仪器 UI（`FUnlockTheme`）已相当成熟。但前后端底层架构积累了明显的结构性包袱：

1. **后端并发模型与计时器所有权分裂**：底层 `FUn` / `BLEScanner` / `BLEPeripheralHandler` 运行在 `bleQueue` + 非重入 `UnfairLock` 上，上层 `FUnManager` / `UnlockOrchestrator` / `FUnlockStateMachine` 挂在 `@MainActor` 上靠多个 `Generation` 计数器和延迟 `Task` 防重入；全仓散落 **9 处独立 `Timer`**，「必须在主 RunLoop 上 `invalidate`」仅靠人工注释维持，在场/锁屏/冷却状态分散在三处。
2. **解锁策略单一，缺少「防误锁保活」与「零注入让路」**：日常大量自动解锁源于用户在工位阅读/观看视频未碰键鼠导致系统空闲息屏锁死；唤醒后又一律走 `CGEvent` / `AppleScript` 敲密码，既未给 macOS 原生 Apple Watch Auto Unlock 让路（导致重启后首次冷启动 Keychain 必败），密码在内存中也以不可清零的 Swift `String` 驻留。
3. **前端高低频状态耦合与后台空转拷贝**：`FUnManager` 将高频跳动的 `rssi` 与低频会话状态混在同一 `@Observable` 根对象；`SignalDataStore` 在有 BLE 采样时即便主窗口关闭仍每秒全量 `toArray()` 拷贝 600 条样本；`OverviewView` 为防设备列表跳动在视图层自建 `1.5s` `Timer`。

本次重构旨在一步到位落地单进程终局架构：**后端收敛为零依赖纯函数内核 `FUnlockCore` + 单一最小堆 `DeadlineScheduler` + 三段式渐进解锁（`L0 → L1 → L2`）；前端收敛为保留 `NSStatusItem` 壳的 CQRS 按需三投影（关窗零拷贝、零多余重绘）**，并彻底清理 `NotchEvery` 归档残留。

---

## 2. 目标、非目标与反目标

### 2.1 目标（Goals）
1. **零 UI/硬件依赖的纯函数核心（`FUnlockCore`）**：将信号滤波、迟滞判定、环形缓冲、完整领域状态树 `EngineState`、纯函数状态转移 `EngineReducer` 与截止时间模型抽入本地 Swift Package `Packages/FUnlockCore`（仅依赖 `Foundation`），支持毫秒级纯内存时序单测（`swift test` 无需启动 App 宿主或触碰硬件）。
2. **单一截止时间调度器消灭散装 Timer**：将 `signal`、`heartbeat`、`lockConfirm`、`activePoll`、`peripheralConnect`、`deviceExpiry[UUID]`、`selfLockWindow`、`lockVerify`、`unlockVerify`、`wakeRetry` 等全部时序逻辑统一建模为 `EngineState` 内的 `DeadlineTable`，运行时由唯一一个 `DeadlineScheduler` 驱动。
3. **三段式渐进解锁（`L0 → L1 → L2`）+ 非对称负向加速锁屏**：
   - **L0 有界在场保活**：已解锁且设备稳定在场时，周期性续期用户活动断言阻止系统空闲误锁；设严格无键鼠上限（15 分钟）防烧屏，信号离开即刻撤断言并锁屏。
   - **L1 自学习零注入让路**：运行时自动识别系统原生解锁（如 Apple Watch Auto Unlock）及 Keychain 冷启动场景，点亮屏幕后短暂让路轮询 `CGSession`，免去无谓的密码注入；纯 iPhone 常规场景零额外等待。
   - **L2 最小暴露 `CGEvent` 注入**：密码直接读取为可写 `[UniChar]` 缓冲并在 `defer` 中以 `memset_s` 清零，彻底移除第 3 级 `NSAppleScript` 注入。
   - **负向信号快采加速**：蓝牙音频输出设备断连或安全 Wi-Fi 断开时，立即触发一次主动 RSSI 探测并切入 `0.5s` 快轮询档加速离场确认（绝不将多模态信号作为正向解锁依据）。
4. **前端 CQRS 三投影 + 关窗后台零拷贝**：保留 `NSStatusItem` + `NSPopover` / `NSWindow` 与 `FUnlockTheme` 四分区视图，将状态拆分为常驻低频 `StatusProjection`、仅窗口可见时激活的 `LiveSignalProjection`、以及由 `TimelineView` 按需读取非响应式环形缓冲的 `SignalRingStore`。
5. **仓库清理**：删除 `README.md` 顶部 `NotchEvery` 归档公告与临时文件 `docs/antigravity-architecture-reply.md`，同步更新架构文档。

### 2.2 非目标（Non-Goals）
- 不引入 `/Library/Security/SecurityAgentPlugins`（`system.login.screensaver`）或需要管理员提权的系统级插件。
- 不开发 iOS / watchOS 伴侣端 App。
- 不拆分为独立的后台守护 Bundle / Helper 进程（实测当前单进程常驻 RSS 仅约 34 MB，拆独立进程收益有限且会引发 TCC 辅助功能/蓝牙双份授权与升级漂移）。
- 不重做 `2026-11-24` 已完成的精密仪器风视觉设计（`FUnlockTheme`、色板、四分区布局保持不变）。
- 不破坏现有偏好域 `com.fuhahah.Funlock.config`、Keychain 条目格式、`decisions.jsonl` 格式及外部用户脚本参数契约（`away` / `lost` / `unlocked` / `intruded`）。

### 2.3 反目标（Anti-Goals）
- **严禁削弱既有 22 项安全与正确性不变量**：包括但不限于 `isSecureToInject` 双阶段校验（前奏允许屏保、按键阶段禁屏保、`frontmost == nil` 时强制要求 `CGSSessionScreenIsLocked == 1`）、熄屏未点亮严禁盲打、10s 自锁窗口防乱序误判手动锁、2s 锁屏回读失败回滚、分布式通知延迟 CGSession 复核、单样本骤降二次结算守卫、测试进程禁真锁屏（`XCTestCase` 守卫）与 `.xctest` 配置域隔离。
- **严禁无上限阻止显示器休眠**：L0 保活必须受真实键鼠空闲时长封顶，杜绝手机忘在桌上导致整夜亮屏。
- **严禁给非 Watch 用户强加固定等待税**：未观测到原生自解锁且 Keychain 正常可读时，L1 不得插入空等延迟。
- **严禁替换为 SwiftUI `MenuBarExtra`**：保留成熟可控的 AppKit `NSStatusItem` + `NSPopover`/`NSWindow` 架构，避免多显示器与全屏空间下的焦点缺陷。

---

## 3. 约束（Constraints）

- **编译与并发**：macOS 14.0+ 部署目标，`SWIFT_STRICT_CONCURRENCY = complete` 零并发警告；Release 构建保持团队 `JJYCS98SHK` Automatic 签名以确保 TCC 辅助功能授权跨重启持久生效。
- **单文件复杂度约束**：新增核心源文件职责单一，控制在合理篇幅（目标 ≤ 300~350 行/文件），纯逻辑与 OS 副作用严格分层。
- **测试回归基线**：迁移全过程保持现有 `FUnlockTests` 业务断言兼容（通过 `@_exported import FUnlockCore` 与 `FUnManager` 门面适配平滑过渡），新增 `FUnlockCoreTests` 覆盖全部 Reducer 状态转移与 Deadline 边界。
- **工作区与协同约束**：当前机器有效工作目录为 `/Volumes/SSD/fuhaha_workspace/FUnlock`。向 Claude Desktop 派发子任务时统一通过 `agent-hud` `send_message(..., reply_hint: false)` 投递，并通过 `get_message` 回收执行结果与测试输出。

---

## 4. 考虑过的架构方案与取舍（Approaches）

| 方案 | 核心形态 | 权衡与结论 |
|---|---|---|
| **方案 A（已选定）** | 单进程 + 本地 SPM `FUnlockCore` 纯函数 Reducer + 单一 `DeadlineScheduler` + `L0/L1/L2` 三段式解锁 + 前端按需三投影 | **综合最优**：编译器级隔离核心纯逻辑与系统副作用，彻底根除 9 处散装 Timer 与双状态机竞态，零 TCC 权限分裂风险，复用全部新 UI 组件。 |
| **方案 B（否决）** | 保留 `FUn` + `FUnManager` 现有并发骨架，仅局部打补丁加 L0/L1 与关窗停更 | 改动小，但保留了 `UnfairLock` + 多处主线程 Timer + `@MainActor` `Generation` 防重入的技术债，后续每次改时序仍易引入回归。 |
| **方案 C（否决/暂缓）** | 同二进制 `FUnlock --agent` 常驻守护 + 按需拉起 GUI 进程的跨进程 XPC 架构 | 虽有 UI 崩溃隔离，但 34 MB 内存拆进程收益极低，且 macOS Sequoia 下双进程 TCC 权限复用、模态弹窗回传与热更新 `exec` 重启复杂度远高于收益。 |
| **系统认证插件 / 手机伴侣 App（否决）** | `SecurityAgentPlugin` 改 `authorizationdb`，或开发 iOS BLE 伴侣端 | 前者在 Sonoma/Sequoia 下破坏原生锁屏 UI 且有锁死系统进不去桌面的致命风险；后者直接破坏「免装手机 App」的核心产品定位。 |

---

## 5. 详细架构设计（Detailed Design）

### 5.1 模块与目录分层

```text
FUnlock/
├── Packages/
│   └── FUnlockCore/                      # 本地 Swift Package（仅 import Foundation，零 OS/UI 依赖）
│       ├── Package.swift
│       ├── Sources/FUnlockCore/
│       │   ├── Domain/                   # ScreenState, SystemPowerState, LockIntent, EngineConfig, DecisionModel
│       │   ├── Signal/                   # SignalPipeline, SignalHysteresisEngine, RingBuffer, SignalSample
│       │   ├── Engine/                   # EngineState, EngineEvent, EngineEffect, EngineReducer
│       │   └── Scheduler/                # DeadlineID, DeadlineTable（纯值最小时间计算）
│       └── Tests/FUnlockCoreTests/       # 纯函数确定性时序单测（虚拟时钟推进，0 sleep）
├── FUnlock/                              # 主应用 Target（@_exported import FUnlockCore）
│   ├── Runtime/                          # EngineHost (@MainActor), LiveDeadlineScheduler, 5 路 Adapter
│   │   ├── EngineHost.swift              # 唯一持有 EngineState，串行喂入 Event 并分发 Effect
│   │   ├── LiveDeadlineScheduler.swift   # 唯一底层计时器（单 DispatchSourceTimer 对齐最近 deadline）
│   │   ├── BLEAdapter.swift              # CoreBluetooth 串行队列采集 + 自适应轮询指令执行（无业务 Timer）
│   │   ├── SystemSessionAdapter.swift    # CGSession / NSWorkspace / DistributedNotification / HID 空闲度
│   │   ├── PowerKeepAliveAdapter.swift   # lowlevel.c 唤醒断言 + L0 有界在场保活断言独立句柄
│   │   ├── UnlockExecutor.swift          # L1 零注入轮询 + L2 [UniChar]/memset_s CGEvent 注入事务
│   │   └── NegativeSignalAdapter.swift   # CoreAudio 输出路由断连 / Wi-Fi 脱离事件监听
│   ├── Projections/                      # 前端 CQRS 三投影 + 统一命令入口
│   │   ├── StatusProjection.swift        # @Observable 低频状态（菜单栏、Sidebar、设置开关同步）
│   │   ├── LiveSignalProjection.swift    # @Observable 高频读数与防抖候选设备（仅窗口可见时更新）
│   │   └── SignalRingStore.swift         # 非 @Observable 线程安全环形缓冲（供 TimelineView 按需快照）
│   └── Views / Services / AppDelegate    # 保留现有 NSStatusItem 壳与 FUnlockTheme 视图体系
└── FUnlockTests/                         # 现有集成与视图/服务单测套件
```

### 5.2 后端核心：`FUnlockCore` 纯函数状态机与 `DeadlineTable`

#### 5.2.1 单一真相状态树 `EngineState`（开发者决策）
消除原先 `FUn.presence`、`FUnManager.state`、`FUnlockStateMachine`、`UnlockOrchestrator` 四处重复状态，收敛为单一纯值结构体：

- **蓝牙与信号态**：
  - `monitoredUUID: UUID?`、`monitoredDeviceName: String?`
  - `peripheralConnected: Bool`、`activePollInterval: TimeInterval`（`0.5` / `2.0` / `8.0`）、`stablePollCount: Int`
  - `presence: Bool`、`pipeline: SignalPipeline`、`effectiveRSSI: Double`、`displayRSSI: Double`、`preWakeEMA: Double`
  - `lastSampleAt: Date?`、`signalTimeoutCount: Int`（连续 3 次达 `signalTimeout` 判 `lost`）
  - `lockConfirmContext: LockConfirmContext?`（含 `startedAt`、`pollIntervalBefore`、`extendedOnce`，完整保留单样本骤降二次结算语义）
- **会话与电源态**：
  - `screen: ScreenState`（`.unlocked` / `.locked(reason)` / `.screensaver` / `.displaySleeping`）
  - `systemPower: SystemPowerState`（`.awake` / `.sleeping`）
  - `intent: LockIntent`（`.autoLock` / `.manualLock(deadline: Date)`）
  - `idleSleepLatched: Bool`（因 15 分钟空闲上限自然息屏或手动锁屏且设备未离场时置 `true`，抑制 `wakeOnProximity` 原地反复亮屏；设备经历 `presence: true → false` 离场或检测到真实键鼠输入 `idleSeconds < 2.0` 时清零）
  - `selfWakeStartedAt: Date?`（记录 FUnlock 程序主动发起 `funlock_wakeDisplay` 的时间戳，作为 L1 自学习的唯一时间锚点）
  - `selfLockWindowDeadline: Date?`（自动锁屏后 `10s` 内忽略乱序到达的系统锁/屏保通知误判手动锁）
  - `lastLockAt: Date`、`lastUnlockAt: Date`、`lastProximityAt: Date`
- **解锁与保活事务态**：
  - `unlockPhase: UnlockPhase`：
    - `.idle`
    - `.wakingDisplay(attempt: Int, parallelUnlockScheduled: Bool)`
    - `.waitingDelay`（亮屏 `0.3s` / 并行唤醒 `0.8s` 防抖）
    - `.waitingNativeUnlock(startedAt: Date)`（**L1 零注入观察期**）
    - `.injecting`（**L2 `CGEvent` 注入与双保险验证在途**）
    - `.cooldown(until: Date)`
    - `.degraded`（连续 3 次注入验证失败进入降级）
  - `consecutiveFailures: Int`、`recentAttemptTimestamps: [Date]`（5 分钟 10 次异常频率告警窗口）
  - `watchAutoUnlockObserved: Bool`、`consecutiveL1Timeouts: Int`
  - `keepAliveActive: Bool`（**L0 在场断言是否持有中**）
- **统一截止时间表 `deadlines: DeadlineTable`**：
  - 以强类型 `enum DeadlineID: Hashable, Sendable` 为键存储 `[DeadlineID: Date]`，彻底取代散装 Timer：
    1. `.activePoll`（主动模式 `readRSSI()` 周期）
    2. `.peripheralConnectTimeout`（连接外设 `60s` 超时回退）
    3. `.heartbeat`（`2s / 3s / 8s` 自适应离场巡检）
    4. `.signalTimeout`（`signalTimeout` 周期失联计数）
    5. `.lockConfirm`（斜率自适应 `2.5s~5.0s` 锁屏倒计时及单样本延期结算）
    6. `.deferredLockRecheck`（安全 Wi-Fi / 冷静期拦截后的 `10s` 补锁复查）
    7. `.lockVerify`（锁屏动作发出 `2.0s` 后 CGSession 回读校验）
    8. `.screenLockConfirm` / `.screenUnlockConfirm`（分布式通知 `0.3s` / `0.4s` 延迟 CGSession 复核）
    9. `.systemWakeReady`（系统唤醒 `1.0s` 蓝牙栈恢复延迟）
    10. `.wakeRetry`（显示器唤醒 `0.5s` 步进重试，最多 10 次）
    11. `.unlockDelay`（`0.3s` / `0.8s` 解锁启动延迟）
    12. `.l1NativeCheck`（L1 零注入 `150ms` 轮询与 `1.2s` 截止）
    13. `.intrudeCheck`（手动解锁 `2.0s` 后入侵脚本判定）
    14. `.keepAliveRenew`（L0 在场保活 `30s` 续期节拍）
    15. `.deviceExpiry(UUID)`（扫描候选设备 `60s` 过期移除）
    16. `.uiDiscoveryFlush`（仅在扫描列表展开且窗口可见时，`1.5s` 刷新一次防抖排序候选列表）

#### 5.2.2 单一调度器 `LiveDeadlineScheduler`
- 每次 `EngineReducer.reduce` 执行完毕后，`EngineHost` 读取 `state.deadlines.earliest()`（返回最早到期的 `(DeadlineID, Date)?`）。
- `LiveDeadlineScheduler` 内部仅维护**唯一一个**高精度计时任务（`DispatchSourceTimer` 或可取消 `Task`），仅当最早到期时间变化时重设触发点；到期时向 `EngineHost` 回送 `.deadlineFired(id, scheduledAt)` 事件。
- 若到期时刻 `state.deadlines[id] != scheduledAt`（已被更新或取消），Reducer 直接无副作用忽略——从根源上消灭旧 Timer 晚到误触发与跨线程 `invalidate` 崩溃（历史 Bug #1）。

### 5.3 三段式渐进解锁与安全设计（`L0 → L1 → L2`）

#### 5.3.1 L0：有界在场保活与防原地反复唤醒闩锁（Bounded Presence Keep-Alive，开发者决策）
- **配置开关**：`ConfigStore` 新增布尔键 `keepAliveWhilePresent`（默认 `true`，归入「行为」设置页开关并纳入导出/导入清单）。
- **激活条件**（全部满足才持有/续期保活断言）：
  1. `enabled == true` 且 `keepAliveWhilePresent == true`；
  2. `screen == .unlocked` 且 `systemPower == .awake` 且 `!intent.isManualLockActive`；
  3. `presence == true` 且 `effectiveRSSI >= Double(resolvedUnlockThreshold)`（信号扎实处于解锁圈内，而非迟滞边缘区）；
  4. **真实输入空闲上限守卫**：`InputActivityMonitor.idleSeconds < 900`（**15 分钟硬上限**）。
- **底层实现（`lowlevel.c` 独立断言句柄）**：
  - 在 `lowlevel.c` 中新增独立的 `keepAliveAssertionID`（与唤醒前奏用的短时 `wakeAssertionID / preventSleepAssertionID` 分离，互不误释放）：续期时调用 `IOPMAssertionDeclareUserActivity("FUnlock Presence KeepAlive", kIOPMUserActiveLocal, &keepAliveAssertionID)`（每 `30s` 一次）。不长期挂死 `PreventUserIdleDisplaySleep`，而是以局部用户活动续期，确保一旦停止续期系统能按用户原有电源设置自然熄屏。
- **瞬时撤除**：一旦上述任一条件不满足（例如用户手动锁屏、空闲满 15 分钟、或有效信号跌破阈值进入离场计时），**立即释放** `keepAliveAssertionID`；离场超时成立时照常调 `SACLockScreenImmediate()` 立即锁屏。
- **空闲封顶熄屏后的 `wakeOnProximity` 闩锁与安全锁意图（Builder Check 补强，开发者决策）**：
  1. **防整夜亮屏死循环（`idleSleepLatched`）**：当屏幕因满 15 分钟无键鼠（`idleSeconds >= 900`）在 `presence == true` 状态下进入 `.displaySleeping`，或处于 `intent.isManualLockActive` 时，置 `idleSleepLatched = true` 并拦截 `wakeOnProximity` 预唤醒——防止手机忘在桌上导致「15 分钟熄屏 → 下一包 BLE 广播秒点亮」整夜死循环（注：常规离场或 `idleSeconds < 900` 的息屏不置此闩锁，保持现有 `PreWakeStaircaseTests` 语义完全兼容）。仅当设备真正离场（`presence` 翻转为 `false`）或用户产生物理键鼠输入（`idleSeconds < 2.0`）时解除闩锁。
  2. **空闲超时锁屏保持 `.manualLock` 安全语义**：L0 满 15 分钟释放断言后，系统随后触发的空闲屏保或系统锁屏（在 `selfLockWindow` 外到达）继续按 `.manualLock` 处理——确保手机遗落在工位桌上时，路人触碰键盘不会触发自动输密码解锁，必须本人手动/Touch ID 解锁一次才恢复自动模式。

#### 5.3.2 L1：自学习零注入快速通道（Self-Learning Zero-Injection，开发者决策）
- **触发条件**：当解锁门控全部通过、准备解锁已锁定会话时，满足以下任一条件即先进入 `.waitingNativeUnlock`（最长 `1.2s`，每 `150ms` 检查一次 `SystemInteractionService.isExplicitlyUnlockedSession()`）：
  1. `watchAutoUnlockObserved == true`（曾观测到系统原生自动解锁成功）；
  2. `SecurityService.hasUnlockablePassword()` 返回 `.coldBoot`（系统重启后尚未手动解锁一次，Keychain 被锁无法取密码——此时 L2 必败，点亮屏幕等待 Watch / Touch ID 是唯一可行路径）。
- **防 Touch ID 假阳性的自学习闭环（Builder Check 补强，开发者决策）**：
  - **严格锚定程序自唤醒（排除 Touch ID 干扰）**：Touch ID 解锁走 `biometrickitd` 不产生 `CGEvent`，若按普通 `displayWake` 计时会把用户开盖/按指纹误学成 Watch 解锁。因此正向学习**仅在 FUnlock 自身发起靠近预唤醒（`selfWakeStartedAt != nil` 且 `intent == .autoLock`）后的 `2.5s` 窗口内**生效：若在此窗口内 `isExplicitlyUnlockedSession() == true`、期间未执行 L2 密码注入、设备近场 `presence == true`、无键鼠活动（`idleSeconds > 2.0`），且绑定设备非明确已知的 iPhone 机型标识（即仅 Apple Watch 或未知型号 BLE 设备可学习），才置 `watchAutoUnlockObserved = true`（持久化到 `ConfigStore`）。此外在「行为」设置页提供可选开关覆盖（默认开启自适应让路）。
  - **退化摘除**：若 `watchAutoUnlockObserved == true`，但连续 **3 次**进入 L1 均满 `1.2s` 超时退回 L2 才解开（例如用户摘表或关闭了系统 Watch 解锁），自动将 `watchAutoUnlockObserved` 复位为 `false`，后续恢复 `0ms` 直通 L2。
  - **统计与副作用归属**：
    - 因 `watchAutoUnlockObserved` 靠近自唤醒触发的 L1 成功：归入 FUnlock 协同自动解锁——记录 `DecisionReason.unlockSuccess`（detail 标注「原生解锁协同·零密码注入」）、执行 `"unlocked"` 脚本与通知，并置 4s 完成窗口抑制重复 `.userUnlocked` 与误报 `"intruded"`；
    - 因 `.coldBoot` 进入的 L1 期间会话解锁（多为用户重启后手输密码或按指纹）：不冒领 `.unlockSuccess`，交由 `onUnlock` 正常记录 `.userUnlocked`。

#### 5.3.3 L2：零残留密码缓冲与双级 `CGEvent` 注入
- **移除第 3 级 `NSAppleScript`**：删除 `SystemInteractionService.injectWithAppleScript`（现代 macOS 锁屏会话下 `System Events` 既不可靠又会触发额外 Automation TCC 弹窗）。保留第 1 级 `cgSessionEventTap` 与第 2 级 `cghidEventTap`，并完整保留双阶段 `isSecureToInject`（前奏允许屏保、按键阶段禁屏保且要求 `loginwindow` 或 `CGSSessionScreenIsLocked == 1`）与熄屏禁盲打门控。
- **用户抢占即刻熔断**：按键分批投递前除了检查 `isSecureToInject`，新增检查 `CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown) < 0.15`（排除自身事件源），若检测到物理键盘正在敲击则立即中止剩余批次，避免与用户手输密码混叠。
- **密码内存即焚（`SecretUTF16Buffer`）**：
  - 新增 `final class SecretUTF16Buffer`（内部持有 `UnsafeMutableBufferPointer<UniChar>`，禁止拷贝）：`SecurityService.fetchPasswordBuffer()` 从 `SecItemCopyMatching` 拿到的 `CFData` 直接通过 `CFStringCreateFromExternalRepresentation` + `CFStringGetCharacters` 转写进预分配 `UniChar` 缓冲区，随即用 `memset_s` 擦除临时字节缓冲；
  - `SecretUTF16Buffer.deinit` 及注入结束 `defer` 块无条件调用 `memset_s(baseAddress, byteCount, 0, byteCount)` 后再 `deallocate()`，解锁全链路不再构造不可变 Swift `String`。

#### 5.3.4 非对称负向信号加速（`NegativeSignalAdapter`，开发者决策）
- **原则**：外部辅助信号**永远不触发解锁、不放宽解锁阈值**，仅作为「疑似离场」的快速采样唤醒器。
- **触发源**：
  1. `CoreAudio` 默认输出设备变更（`kAudioHardwarePropertyDefaultOutputDevice`——如用户摘下 AirPods 放回充电盒断连）；
  2. `NWPathMonitor` / Wi-Fi 接口状态变化（Wi-Fi 断开或 SSID 切换）。
- **动作**：向 `EngineHost` 发送 `.negativeHintReceived(source)`。若当前 `presence == true` 且 `activePollInterval > 0.5`，引擎立即下发 `.probeRSSIImmediately` 并将轮询档位临时切至 `0.5s`（持续几个采样周期），把原本 `8s` 慢轮询下的离场感知延迟压缩到亚秒级。

### 5.4 前端架构：CQRS 按需三投影与视图解耦

保留 `AppDelegate` 的 `NSStatusItem` 离散态位图缓存、`NSPopover` / `NSWindow` 容器及 `FUnlockTheme` 全套视图，重构状态供给层：

1. **`StatusProjection`（`@MainActor @Observable`，常驻极轻）**：
   - 字段：`screen: ScreenState`、`connected: Bool`、`monitoredDeviceName: String?`、`hasBoundDevice: Bool`、`lockRSSI: Int`、`unlockRSSI: Int`、`thresholdVersion: Int`、`isDegraded: Bool`、`keepAliveActive: Bool`、`updateState: UpdateDownloader.State`。
   - 消费者：`AppDelegate`（菜单栏图标）、`MenuBarPopoverView`、`SidebarView`、`RangeRailView`。平时无状态跳变时 **0 Hz 更新**。
2. **`LiveSignalProjection`（`@MainActor @Observable`，窗口可见性门控）**：
   - 字段：`displayRSSI: Int?`、`effectiveRSSI: Double`、`isWindowVisible: Bool`、`isDiscoveryExpanded: Bool`、`candidateDevices: [DeviceSnapshot]`。
   - **门控规则**：`AppDelegate` 在主窗口/Popover 打开与关闭时同步切换 `engineHost.setWindowVisible(Bool)`。当 `isWindowVisible == false` 时，`EngineHost` **不向 `LiveSignalProjection` 派发任何 RSSI 变动或扫描列表更新**。
   - **内置防抖候选列表**：当 `isWindowVisible && isDiscoveryExpanded` 时，由引擎 `.uiDiscoveryFlush`（`1.5s` 周期）统一输出按 RSSI 排序且排除已绑定设备的 `candidateDevices`，彻底删除 `OverviewView` 私有的 `@State scanTimer` 与 `frozenDevices`。
3. **`SignalRingStore` + `TimelineView`（零后台数组拷贝）**：
   - `SignalRingStore` 内部用 `UnfairLock` 保护 `RingBuffer<SignalSample>(capacity: 600)`，**不标注 `@Observable`、不起任何后台 `Timer`**。
   - `DiagnosticsView` 的图表区域包裹在 `TimelineView(.periodic(from: .now, by: 1.0))` 中，渲染闭包内按需调用 `ringStore.snapshot()`：只有切到「诊断」Tab 且窗口在屏幕上可见时才每秒取一次快照；切走 Tab 或关闭窗口后开销严格为 **0**。
4. **结构化权限刷新**：
   - 移除 `MainWindowView` 的 `AnyCancellable` 5s Timer，改为 `.task(id: !axGranted || !btGranted)` 内的 `while !Task.isCancelled` 异步挂起循环，视图消失时由 SwiftUI 自动取消。

### 5.5 兼容门面与四阶段平滑迁移路径

为保证现有单测与功能零中断回归，按以下 4 个可独立验证阶段推进：

1. **阶段 1：建立 `Packages/FUnlockCore` + 清理仓库杂项**
   - 创建本地 Swift Package，迁入 `SignalPipeline`、`SignalHysteresisEngine`、`RingBuffer`、领域枚举，并实现全新的 `EngineState`、`EngineEvent`、`EngineEffect`、`EngineReducer`、`DeadlineTable` 及完整的 `FUnlockCoreTests` 纯函数测试集。
   - 主工程接入 `FUnlockCore`（`@_exported import FUnlockCore`），删除 `README.md` 的 `NotchEvery` 归档横幅与临时文件 `docs/antigravity-architecture-reply.md`。
2. **阶段 2：落地运行时单调度器与 Adapter 层，收编 9 处 Timer**
   - 实现 `LiveDeadlineScheduler`、`EngineHost`、`BLEAdapter`、`SystemSessionAdapter`。
   - 将 `FUnManager` 改造为转发/兼容门面（保留外部测试依赖的核心方法签名与可注入 override 钩子），下线旧 `FUnLockCoordinator` / `BLEPeripheralHandler` / `FUnlockStateMachine` 中的散装 `Timer` 与重复状态。
3. **阶段 3：落地前端 CQRS 三投影与 `TimelineView` 图表**
   - 实现 `StatusProjection`、`LiveSignalProjection`、`SignalRingStore`，接入窗口可见性门控，替换 `SignalDataStore` 后台 Timer、`OverviewView.scanTimer` 与 `MainWindowView` 权限 Timer。
4. **阶段 4：落地 `L0 → L1 → L2` 三段式解锁、`SecretUTF16Buffer` 与负向快采**
   - 扩展 `lowlevel.c` 独立 `keepAliveAssertionID`，实现 `PowerKeepAliveAdapter`（L0 15 分钟有界保活 + 设置项开关）、L1 自学习零注入观察窗、`SecretUTF16Buffer`（`memset_s` 清零 + 移除 `NSAppleScript`）及 `NegativeSignalAdapter`（音频路由/Wi-Fi 负向快采），更新 `README.md` 架构说明并完成全量回归与团队签名 Release 构建验证。

---

## 6. 留给实施者决定的细节（What's Left to the Builder）

1. `EngineReducer` 内部子函数的文件拆分粒度（如按 `EngineReducer+BLE.swift`、`EngineReducer+Unlock.swift`、`EngineReducer+Lock.swift` 拆分以保持单文件 < 300 行）。
2. `LiveDeadlineScheduler` 具体采用串行队列上的 `DispatchSourceTimer` 还是基于 `ContinuousClock` 的可取消 `Task`（只要满足单一定时源、精确重设最早 deadline、测试可注入虚拟时钟即可）。
3. `FUnManager` 在过渡期保留哪些薄包装方法以最小化对现有 468 条 `FUnlockTests` 的机械改动，以及哪些针对已删除旧内部实现细节（如 `NSAppleScript` L3 注入）的单测直接同步更新或移除。
4. 「行为」设置页中 `keepAliveWhilePresent`（在场防熄屏保活）开关在多语言 `Localizable.strings` 中的翻译措辞（与现有 7 种语言风格对齐）。
