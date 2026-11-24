# FUnlock 全量审计修复设计文档

- **日期**：2026-11-24
- **目标仓库**：`/Volumes/傅哈哈的尿袋/fuhaha_workspace/FUnlock`（基线提交 `410aac7`，Xcode 工程 `FUnlock.xcodeproj`，macOS 14.0+，Swift 5.0）
- **范围**：修复 2026-11-24 双端深度审计确认的全部 **22 项** P0/P1/P2 问题（不触碰 `NotchEvery` 或 `/Users/fupingguo/fuhaha_workspace/FUnlock` 副本）。

---

## 1. 意图与背景（Why）

用户在日常使用 `/Applications/FUnlock.app` 时反复遇到「人在电脑前或刚解锁不久仍会误锁」「靠近时解锁卡顿/停摆」问题。本次通过逐行源码审计并结合生产日志实证（`~/Library/Logs/FUnlock/debug.log` 中 126 条心跳日志 `inputActive` 100% 为 `false`，`timing.log` 暴涨至 19,977 行，`decisions.jsonl` 全部 `lockedAway` 错标 `displaySleeping`）定位到 22 项代码级根因，涵盖误锁、解锁活锁、屏幕状态机错乱、安全/凭据泄露、内存安全（SQLite UAF）、自动更新失效、主线程阻塞与测试污染。

用户明确要求**一次性全量修复**，确保锁屏不误锁、解锁不卡死、凭据不泄露、状态机与测试隔离干净可靠。

---

## 2. 目标、非目标与反目标

### 目标（Goals）
1. **根治误锁**：修复输入活动监测失效、切 Tab/关设置窗误停扫描、8s 慢轮询/10s 断连/`AllowDuplicates=false` 断流、单样本骤降快锁、解锁后冷静期缺口及滤波中断恢复缺陷。
2. **根治解锁卡顿与停摆**：修复高频采样反复取消 `unlockTask` 活锁、息屏未锁屏唤醒后 `state.screen` 永久卡死、取消验证被计为失败进入 degraded、屏保/锁屏通知乱序误标手动锁、锁屏期模态弹窗冻结主线程。
3. **加固安全与内存**：移除硬编码 Bark Key、设置导出脱敏与导入强校验 HTTPS、真 `SACLockScreenImmediate` 锁屏、收紧 `isSecureToInject` 与分布式通知 CGSession 复核、修复 SQLite `SQLITE_TRANSIENT` UAF 与只读打开、修复 `UpdateDownloader` 临时文件竞态与 `UpdateInstaller` 签名/脚本校验。
4. **修复工程与体验隐患**：释放 `wakeDisplay` 的 `IOPMAssertion`、异步化并限流 `timingLog`、优化 `attemptAutoUnlock` 门控顺序与派发、修复 `ConfigStore`/`ProfileManager`/`CalibrationWizardView` 边界 bug、隔离测试对生产日志与真锁屏的影响、清理重复 CI、修正文档与实现偏差。

### 非目标（Non-Goals）
- 不修改 `NotchEvery` 或 `/Users/fupingguo/fuhaha_workspace/FUnlock` 副本。
- 不更改 UI 整体视觉架构、不重构未涉及的视图样式（如 LiquidGlass / Sidebar / StatsView）。
- 不做 BLE 中继攻击防御（硬件平台限制，属 README 已声明的产品边界）。
- 不迁移现有密码存储到新的 Keychain 架构或强制破坏用户现有密码（见 §5.16 约束）。

### 反目标（Anti-Goals）
- **绝不能**在未锁屏或前台应用为已知非锁屏应用（非 `com.apple.loginwindow` / 屏保前奏期 `com.apple.ScreenSaver.Engine`）时注入明文密码。
- **绝不能**让测试套件再次真实锁住用户电脑或向 `~/Library/Logs/FUnlock/` 写入测试脏数据。
- **绝不能**以降低锁屏可靠性为代价消除误锁（真实离开电脑仍须可靠锁屏）。
- **绝不能**破坏现有 468 条单元测试所锁定的合法业务语义（除非该测试本身断言的是待修复的 bug 行为，此时须显式更新测试并说明原因）。

---

## 3. 约束（Constraints）

- **运行环境**：macOS 14.0+，无 App Sandbox，Hardened Runtime 开启，菜单栏 Agent（`LSUIElement = true`）。
- **并发契约**：`FUnManager` / `UnlockOrchestrator` / `FUnlockStateMachine` 保持 `@MainActor`；`FUn` / `BLEScanner` / `BLEPeripheralHandler` 共用不可重入的 `UnfairLock`，锁内严禁嵌套调用取锁 computed 属性或执行阻塞 I/O。
- **验证要求**：每批改动在 `/Volumes/傅哈哈的尿袋/fuhaha_workspace/FUnlock` 上通过 `xcodebuild test`（零编译告警、全量单测通过）；最终完成团队签名 Release 构建核验。

---

## 4. 方案与已拍板取舍（Approaches）

### 整体实施策略
考虑过两种节奏：
- **方案 A（已选定）— 4 批渐进式 TDD 修复**：按依赖与风险拆成 4 个独立批次（误锁/解锁核心 → 状态机/并发/系统底层 → 安全/内存/更新/配置 → 日志/测试/CI），每批先补失败单测再实现修复并跑全量回归，定位清晰、风险可控。
- **方案 B（否决）— 最小止血版**：仅修 P0 误锁和 Bark Key，推迟 P1/P2。用户明确要求「要修肯定全修」，不采用。

### 关键技术取舍（用户已确认）
1. **输入活动监测（Item #1）**
   - **选定方案**：使用 `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .anyInputEventType)`（带可注入时间源/idle 秒数 provider 以便单测）。
   - **否决方案**：保留 `IOHIDManager` 修 HID Usage + 新增「输入监控」TCC 权限引导（多一道权限弹窗、触控板 HID 报告跨机型不一致、存在 `passUnretained` 生命周期隐患）。
2. **锁屏底层实现（Item #9）**
   - **选定方案**：`lowlevel.c` 的 `SACLockScreenImmediate()` 改为动态加载 `/System/Library/PrivateFrameworks/login.framework/Versions/Current/login` 中的真 `SACLockScreenImmediate`（`dlopen` + `dlsym`，缓存函数指针，线程安全 `dispatch_once`），仅在加载失败时降级为 `IORequestIdle`。
   - **否决方案**：保留 `CGEventPost` 模拟 `Ctrl+Cmd+Q`（依赖 AX 权限、修饰键易卡滞、易被全屏/远程桌面拦截）。
3. **Bark 默认 Key（Item #11）**
   - **选定方案**：彻底移除 `BarkNotifier.Defaults.key` 硬编码默认密钥（设为空字符串 `""`），Key 改为必填（为空时 `send` 静默跳过、`sendTestNotification` 返回明确错误），设置导出默认排除 `barkNotifyKey`，导入与发送双侧强制要求 `https://`。

---

## 5. 全量 22 项修复行为设计（按 4 批划分）

### Batch 1：误锁与解锁核心链路（P0）

#### Item 1 — 输入活动监测重构（`AppDelegate.swift`）
- 移除 `IOHIDManager` 与 `inputCallback`（连同 `passUnretained` 悬空风险一并根除）。
- `InputActivityMonitor` 保留现有公开接口（`activityWindow: TimeInterval = 15`、`isActive: Bool`、`start()`、`stop()`），内部改为查询 `idleTimeProvider()`，默认实现为 `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .anyInputEventType)`（返回 `< activityWindow` 且 `>= 0` 即活跃；返回值无效/负数时保守判 `false`）。
- 去掉 `AppDelegate.setupPermissionsAndPrivileges()` 中「仅在解锁开启且 AX 已授权时才启动 `inputMonitor`」的限制——只要 `FUnlock` 运行即生效，用户只开自动锁屏也能享受防误锁保护。
- 为 `InputActivityMonitor` 补充单元测试（注入 `idleTimeProvider` 覆盖活跃/超时/边界/异常负值）。

#### Item 2 — 分离「设备列表扫描」与「监控设备扫描」（`BLEScanner.swift` / `OverviewView.swift` / `AppDelegate.swift`）
- `BLEScanner.stopScanning()` 语义修正：
  - 将 `scanMode = false`；
  - 若当前**有绑定监控设备（`monitoredUUID != nil`）**：
    - 在被动模式（`passiveMode == true`），或主动模式尚未进入轮询（`handler.activeModeTimer == nil`）时，**不得停止底层 `centralMgr.stopScan()`**，而是调用 `scanForPeripherals()` 保持按监控模式参数扫描；
    - 仅当未绑定设备（`monitoredUUID == nil`）或主动模式已连接轮询中（`activeModeTimer != nil`）时，才停止 `centralMgr.stopScan()`。
- `AppDelegate.toggleSettingsWindow` 与 `OverviewView.stopScan()` 调用 `stopScanning()` 后不再误杀后台监控。
- `unbindDevice()` 路径先清除 `monitoredUUID`（或提供显式 `stopAllScanning()`）确保解绑后彻底停止扫描。

#### Item 3 — 修复主动模式 8s 慢轮询断连、`AllowDuplicates` 与衰减窗口冲突 + 快锁防单样本误锁（`BLEPeripheralHandler.swift` / `BLEScanner.swift` / `FUnLockCoordinator.swift`）
- **回退超时与轮询间隔联动**：`BLEPeripheralHandler.restartActiveModeTimer` 中回退被动模式的阈值由硬编码 `lastRead + 10` 改为 `lastRead + max(12.0, pollInterval * 2.5)`（8s 档为 20s，2s 档为 12s，0.5s 档为 12s），消除 8s 档轻微抖动即强行断连。
- **断连重连期保持广播流**：`BLEScanner.scanForPeripherals()` 中，当 `monitoredUUID != nil` 且未在主动轮询中（`handler.activeModeTimer == nil`）时，允许 `AllowDuplicates = true`，避免主动断连重连卡在 `.connecting` 60s 期间完全无采样；一旦 `didConnect` 成功连上即停扫。
- **衰减免罚期兼容 8s 慢轮询**：`FUnLockCoordinator.decayedEffectiveRSSI` 增加可选 `pollInterval` 参数（免罚期为 `max(6.0, pollInterval + 2.0)`，向后兼容现有 `decayedEffectiveRSSI(effectiveRSSI:elapsedSinceLastReceive:)` 6s 签名供旧单测）。运行时 `getEffectiveRSSI()` 在无锁定时器时传入当前 `activePollInterval`（8s 档免罚期 `10.0s`），在锁定时器在途时传入启动前保存的 `pollIntervalBeforeLockTimer`，防止切到 0.5s 快轮询后免罚期在检测中途骤降。
- **防单样本骤降快锁（明确二次结算规则）**：
  - `startLockTimer()` 启动时记录 `lockTimerStartedAt = now`、`pollIntervalBeforeLockTimer = activePollInterval`、`lockTimerExtended = false`，若已连接立即补发一次 `peripheral.readRSSI()` 并将轮询切到 `0.5s` 快档；
  - 定义失联结算期限 `staleLossDeadline = max(10.0, pollIntervalBeforeLockTimer + 4.0)`（8s 档为 `12.0s`，2s/0.5s 档为 `10.0s`）；
  - `lockTimerFired` 触发时：若 `lastReceiveTime > lockTimerStartedAt`（已收到新样本）或 `elapsed >= staleLossDeadline`，直接按常规阈值/输入/冷静期判定结算；否则（尚无新样本且未达 `staleLossDeadline`）且 `!lockTimerExtended`，标记 `lockTimerExtended = true`、再次尝试 `readRSSI()`，并单次延长定时至 `remaining = max(1.0, staleLossDeadline - elapsed)` 秒——确保第二次触发时要么已收到新样本（恢复则取消，确认跌落则锁），要么已达 `staleLossDeadline` 按真实失联结算，不会在 5s 且无衰减时盲锁，也不会与心跳死循环。
- **断连按 UUID 匹配**：`BLEPeripheralHandler.didDisconnectPeripheral` 改为按 `peripheral.identifier == scanner.monitoredUUID`（或匹配 `monitoredPeripheral?.identifier`）判断，防止同设备新 `CBPeripheral` 实例漏触发重扫。

#### Item 4 — 修复高频广播下 `attemptAutoUnlock` 反复取消 `unlockTask` 活锁（`UnlockOrchestrator+AutoUnlock.swift` / `FUnSignalProcessor.swift`）
- `UnlockOrchestrator` 跟踪延迟解锁任务状态（`isUnlockTaskPending: Bool`，或复用现存未取消且未完成的 `unlockTask`）：
  - 在 `attemptAutoUnlock()` 的 `0.8s` 并行解锁分支与 `0.3s` 延迟解锁分支中，若已有在途的同类型 `unlockTask` 尚未执行完毕，**直接 return 复用现有任务**，不再 `unlockTask?.cancel()` 重建。
  - 任务体结束时在 `defer` 中将 `unlockTask = nil`（仅当 `self.unlockTask` 仍指向当前任务时，可用代次 token `unlockTaskGeneration: UInt64` 保证原子性）。
- 仅在 `cancelPendingTasks()`（用户干预/退出）或 `resetAfterUserUnlock()` 时取消 `unlockTask`。

#### Item 5 — 修复息屏未锁屏唤醒状态卡死 + 收紧 `isSecureToInject`（`FUnManager+Events.swift` / `SystemInteractionService.swift`）
- `SystemInteractionService` 明确区分两个语义：
  - `isSystemSessionLocked() -> Bool`（纯外部系统事实：`CGSSessionScreenIsLocked == 1` 或 `ScreenSaver.Engine` 运行；支持测试注入 `sessionLockProvider`）；
  - `isScreenLocked(screenState:)`: 若 `CGSessionCopyCurrentDictionary()` 成功返回字典且 `CGSSessionScreenIsLocked` 明确为未锁且无屏保，直接返回 **`false`**，**不再回退信任陈旧的 `screenState != .unlocked`**；仅在 `CGSessionCopyCurrentDictionary() == nil`（极罕见无会话字典场景）时才回退 `screenState`。
- `FUnManager.onDisplayWake()`：当 `state.screen == .displaySleeping` 时，先查询外部真实锁定态（`isSystemSessionLocked()`）——真锁了才设为 `.locked(reason: .away)`，**未锁则直接恢复为 `.unlocked`**（避免永久卡死在 `.locked` 导致后续自动锁屏失效）。
- `SystemInteractionService.isSecureToInject(screenState:)`（兼顾 macOS 14+ LSUIElement 锁屏与屏保模式）：
  - 首先必须满足 `isSystemSessionLocked() == true`（由外部 `CGSession` 锁定或 `ScreenSaver.Engine` 运行证实，绝不信任陈旧 `screenState`）；
  - 其次检查 `NSWorkspace.shared.frontmostApplication`（支持测试注入 provider）：
    - 若 `frontmostApplication` 非空：仅允许 `com.apple.loginwindow`，或在屏保退出前奏阶段允许 `com.apple.ScreenSaver.Engine`；任何其他前台应用一律拒绝（返回 `false`）；
    - 若 `frontmostApplication == nil`（macOS 14+ `LSUIElement` 菜单栏进程在锁屏界面常见）：**仅当 `CGSessionCopyCurrentDictionary()` 明确证实 `CGSSessionScreenIsLocked == 1`** 时放行；若只是屏保运行且 `CGSession` 未锁，则实际按键密码注入前（`fakeKeyStrokes` 阶段，Shift 前奏之后）要求 `CGSSessionScreenIsLocked == 1` 或前台为 `com.apple.loginwindow`，否则中止注入。

---

### Batch 2：状态机、并发与系统底层（P1）

#### Item 6 — 取消验证不计为失败 + 注入前奏不吞取消（`UnlockOrchestrator.swift` / `SystemInteractionService.swift`）
- `UnlockOrchestrator.performInjectionAndVerify`：在 `let verification = await sys.verifyUnlock(...)` 返回后，第一时间检查 `guard !Task.isCancelled else { self.manager.stateMachine.transition(to: .active); return }`（`defer` 同步清 `isAutoUnlocking = false`），不递增 `consecutiveUnlockAttempts`，不调 `handleUnlockFailure()`，不触发 degraded 或改密弹窗。
- `SystemInteractionService.injectPasswordWithPrelude`：将等待循环中的 `try? await Task.sleep(...)` 改为 `do { try await Task.sleep(...) } catch { return false }`，循环前检查 `guard !Task.isCancelled else { return false }`；同理 `wakeDisplay()` 也尊重取消，取消即早退返回 `false`，防止 0ms 坍缩盲打。

#### Item 7 — 自锁标志改时间窗口/代次，修复屏保/锁屏乱序误标手动锁 + 锁屏校验统一（`FUnManager+Events.swift` / `FUnManager.swift`）
- 将文件级全局 `@MainActor var selfLockingStartedAt: Date?` 改为 `FUnManager` 内部属性（消除多实例/测试间全局状态串扰），引入自锁时间窗口 `selfLockWindowDeadline: Date?`（默认 `now + 10s`）与锁事件代次 `lockVerificationGeneration: UInt64`。
- `onDeviceLeft` 触发自动锁屏时设置 `selfLockWindowDeadline = now + 10s`（不再在单次通知消费后清零，允许 `onSystemScreenLocked` 与 `onScreensaverStart` 以任意顺序到达且在窗口内都识别为自锁，解决先锁屏后屏保或延迟锁屏误标手动锁）。
- 一旦 `onUnlock()` 或用户主动 `lockNow()` 触发，立即清空 `selfLockWindowDeadline = nil`（确保用户退出屏保后手动锁屏不会被残留窗口误判为自动锁）。
- `onDeviceLeft` 与 `lockNow` 共用 2 秒锁屏回读验证（以 `lockVerificationGeneration` 守卫而非易被清掉的 `isSelfLocking`）；失败时仅当仍为当前代次且系统未锁、无屏保时回滚 `state.screen = .unlocked`。

#### Item 8 — `onSystemWake` 可取消 + 解锁确认补 `refreshProximityGrace()` + `presence` 拦截回退 + `lockOnIdle` 一致性
- **可取消 `systemWakeTask`**：`FUnManager` 持有 `@ObservationIgnored var systemWakeTask: Task<Void, Never>?`；`onSystemSleep()` 取消它，`onSystemWake()` 先取消旧的再建新的，并在 `deinit`/`cleanup()` 中取消，到期后复查 `state.system == .sleeping` 仍处于休眠（且未被再次睡眠覆盖）才切 `.awake`。
- **解锁验证成功补冷静期**：`UnlockOrchestrator.performInjectionAndVerify` 的两条确认成功路径（`verification.unlock` 与 `dualVerifyTimeoutCGSessionUnlocked`）统一更新 `state.screen = .unlocked`、`state.unlockedAt = now`、`lastUnlockTime = now` 并调用 `fun.refreshProximityGrace()`。
- **心跳 `lockOnIdle` 一致性**：`FUnLockCoordinator.swift:256` 改为 `let lockOnIdle = ConfigStore.shared.bool(forKey: "lockOnIdle", default: true); if lockOnIdle && inputActive { ... }`。
- **`presence` 与 `onDeviceLeft` 拦截职责分离**：
  - `FUn.presence` 严格表示「BLE 物理在场」，`SignalDataStore.shared.record(..., event: .locked)` 移至 `FUnManager.onDeviceLeft` 真正执行锁屏后记录（被安全 Wi-Fi / 校准 / 禁用拦截时不产生虚假 `.locked` 采样点）。
  - 针对不同拦截器的明确契约：
    - **安全 Wi-Fi（`trustedWiFi`）**：`FUnManager` 记录 `deferredLockReason = .trustedWiFi` 并启动低频（10s）复查任务（仅当 `state.screen == .unlocked && !fun.signalSnapshot().presence` 存活）；一旦离开指定 Wi-Fi 且设备仍不在场（`effectiveRSSI < lockThreshold`），立即补发锁屏流程；若期间设备回到在场或屏幕已锁则自动取消复查任务。
    - **解锁冷静期（`withinUnlockGracePeriod`）**：`FUnManager` 调度一次性延迟复查（等待冷静期剩余时间 ≤ 5s），到期后若仍不在场且 `effectiveRSSI < lockThreshold` 再触发锁定。
    - **校准模式（`isCalibrating`）与总开关关闭（`enabled == false`）**：不进入自动补锁队列；退出校准（Step 4 → Step 5 或关闭向导）时刷新一次 `fun.refreshProximityGrace()` 给用户走回电脑的缓冲，且 `CalibrationWizardView` 在采样期直接读 `snap.effectiveRSSI`（不再因 `snap.presence == false` 退回慢收敛 `manager.rssi`）。

#### Item 9 — 统一 `lockRSSI == -100`（`LOCK_DISABLED`）哨兵语义（`SignalHysteresisEngine.swift` / `FUnLockCoordinator.swift` / `FUn.swift`）
- 明确单一语义：**`lockRSSI == LOCK_DISABLED (-100)` 表示「禁用自动锁屏」**（与 `onDeviceLeft`、`ensureHeartbeat` 和 UI 语义完全一致）。
- `SignalHysteresisEngine.checkProximity` 在 `lockRSSI == lockDisabled` 时 `isAway` 恒为 `false`（不再回退用 `unlockRSSI` 触发离场计时器和误记 `deviceAway`）；`scannerPollingContext` 同步遵循该语义；若 `unlockRSSI == UNLOCK_DISABLED` 且 `lockRSSI != LOCK_DISABLED`，仍可按 `lockRSSI` 维持 `isClose`/`isAway` 以支持「只锁不解」模式。
- 同步核对并更新依赖旧「回退 `unlockRSSI`」语义的单元测试，使语义文档、代码、测试三方一致。

#### Item 10 — 锁屏期禁止主线程 `NSAlert.runModal()` 阻塞（`SecurityService.swift` / `SystemInteractionService.swift` / `UnlockOrchestrator.swift` / `FUnManager+Events.swift`）
- 引入统一的「延迟告警队列 / 标记」（复用 `SecurityService.hasPendingPasswordChange` 的成熟模式）：
  - 锁屏态（`isSystemSessionLocked()` 为 `true`）下，**严禁调用任何 `NSAlert.runModal()`**（包括 `fetchPassword(warn: true)` 无密码、`showPasswordMismatchAlert`、`showAXRevokedAlertIfNeeded`、`showAbnormalUnlockAlert`）；
  - 锁屏时仅记录待展示告警并投递非阻塞的 `UNUserNotificationCenter` 本地通知，待 `onUnlock()` 确认屏幕解锁后再按需弹出确认窗（同类型去重，避免解锁后连续轰炸多个弹窗）。

#### Item 11 — 真 `SACLockScreenImmediate` 锁屏 + 释放 `wakeDisplay` 断言（`lowlevel.c` / `SystemInteractionService.swift`）
- `lowlevel.c`：`SACLockScreenImmediate()` 改用 `dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY)` + `dlsym(..., "SACLockScreenImmediate")`（`dispatch_once` 缓存符号），成功调用直接返回 `0`；仅当框架/符号不可用时降级为 `IORequestIdle`。移除有缺陷的 `Ctrl+Cmd+Q` `CGEventPost` 实现。
- `lowlevel.c`：`funlock_wakeDisplay` / `funlock_releaseWakeAssertion` 用 `os_unfair_lock`（或主队列断言）保护两个静态 `IOPMAssertionID`。
- `SystemInteractionService.injectPasswordWithPrelude`：若本次前奏调用了 `await wakeDisplay()`，在方法退出时（`defer`）调用 `funlock_releaseWakeAssertion()`（若 `startWakeRetry` 不在途），彻底消除唤醒断言泄漏导致 Mac 无法自动熄屏的问题。

#### Item 12 — 信号中断恢复重置 + IQR 零方差修复（`SignalPipeline.swift`）
- `S-1` 中断恢复（`elapsed > 30s`）：除重置 `kalmanP = 1.0`、`kalmanSampleCount = 0` 外，**同时将 `kalmanEstimate = Double(rssi)` 与 `smoothedSlope = 0.0`**，并清理过期时间戳窗口，避免 30s 前的旧离场斜率和陈旧估计污染恢复首包。
- `applyIQR`：使用排除当前点后的历史窗口（或当 `iqr == 0` 时给最小物理底噪门槛，例如 `effectiveIQR = max(iqr, 2.0)`，避免连续相同读数时 ±1 dBm 正常量化跳变被误标为异常）；同时在 `computeKalman` 中对异常点**只降权（不额外叠加 `gammaAnomaly` 放大 Q）**，消除增益缩小与过程噪声放大的自相矛盾。

#### Item 13 — 分布式通知 CGSession 复核 + 手动锁安全策略保持与漏通知自愈（`LockScreenState.swift` / `FUnManager+Events.swift` / `FUnManager.swift`）
- **保留「手动锁永不过期直到手动解锁」原有安全策略**：维持 `LockIntent.isManualLockActive` 对已锁会话无条件生效（符合既定安全审计结论、`README.md` 与 4 条既有安全测试，不会在周末手动锁屏超过 24h 后自动解锁）；同时将 `FUnManager.markManualLock()` 的时间戳改用 `now`（`nowProvider()`）统一测试时钟。
- **漏收 `screenIsUnlocked` 通知的自愈机制**：在 `onDisplayWake()` / `onSystemWake()` / `onDeviceApproached()` 中，若 `state.screen != .unlocked`（或 `state.intent.isManualLockActive`）但 `SystemInteractionService.shared.isSystemSessionLocked()` 明确返回 **`false`**（CGSession 证实会话实际已解锁且无屏保），自动补齐状态对齐为 `.unlocked` 并清除陈旧 `.manualLock` intent——在不削弱手动锁安全性的前提下彻底根治漏通知导致的永久停摆。
- **分布式通知复核（防本地伪造 + 兼容锁屏瞬态延迟）**：
  - `onUnlock()`：若 `isSystemSessionLocked()` 仍为 `true`，直接忽略疑似伪造的解锁通知，不清除 `manualLock` intent；
  - `onSystemScreenLocked()`：若 `isSystemSessionLocked()` 已为 `true`，立即同步执行锁定状态更新；若当下为 `false`（可能是伪造/迟到通知，也可能是真实 `Ctrl+Cmd+Q` 锁屏后 CGSession 尚未刷新的 ~100ms 瞬态），不立即写 `manualLock`，而是启动单个可取消的复核任务 `screenLockVerifyTask`（默认延迟 `0.3s`，可测试注入，`onUnlock()` 到来时取消）——到期复查 `isSystemSessionLocked()` 仍为 `false` 则按伪造/迟到通知丢弃，变为 `true` 则执行锁定逻辑（若已在 `selfLockWindowDeadline` 内标记为自锁，否则标记为手动锁）。

---

### Batch 3：安全、内存、自动更新与配置（P0-P2）

#### Item 14 — 移除硬编码 Bark 默认 Key + 导出脱敏 + 强制 HTTPS（`BarkNotifier.swift` / `BarkSettingsCard.swift` / `ConfigStore.swift`）
- `BarkNotifier.Defaults.key` 改为 `""`（空字符串）。
- `BarkNotifier.send` 与 `sendTestNotification`：若规范化后的 `barkKey` 为空，拒绝发送（`send` 静默早退，`sendTestNotification` 返回明确错误提示）；`buildURL` 校验 `server` 必须以 `https://` 开头（拒收 `http://` 与其他 scheme）。
- `ConfigStore.exportableKeys` 与导出逻辑：全量导出默认**排除敏感密钥 `barkNotifyKey`**（且导入时保留本机已有 `barkNotifyKey`，不被清空）；导入 `barkNotifyServer` 时校验非空则必须为 `https://`，否则拒绝写入该 key 并记错误日志。
- `BarkSettingsCard.swift`：默认值改为 `""`，未填 Key 时显示 placeholder 提示。

#### Item 15 — 修复 SQLite `sqlite3_bind_text` UAF 与只读句柄管理（`LEDeviceInfo.swift`）
- `sqlite3_bind_text` 第 5 个参数由 `nil`（`SQLITE_STATIC`）改为 `unsafeBitCast(-1, to: sqlite3_destructor_type.self)`（`SQLITE_TRANSIENT`），根除 `withCString` 退出后的悬空指针读取。
- `sqlite3_open` 改为 `sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)`；失败时若 `db != nil` 立即调用 `sqlite3_close(db)` 再置 `nil`，避免句柄泄漏。

#### Item 16 — 修复 `UpdateDownloader` 临时文件竞态与 `UpdateInstaller` 安全校验（`UpdateDownloader.swift` / `UpdateInstaller.swift`）
- `UpdateDownloader.urlSession(_:downloadTask:didFinishDownloadingTo:)`：**在代理方法返回前同步执行 `FileManager.default.moveItem(at: location, to: zipPath)`**，移动成功后再派发到后台队列执行 `unzip` 和 Bundle ID 校验。
- `UpdateInstaller.parseTeamId`：过滤 `"not set"`（不区分大小写）返回 `nil`，杜绝 ad-hoc 签名 `"not set" == "not set"` 绕过 Team ID 校验。
- `UpdateInstaller.makeInstallScript`：
  - 使用单引号安全转义（POSIX shell escaping）嵌入路径，防注入与特殊字符截断；
  - `cp -R "$UPDATE" "$STAGING"` 后检查退出码（`if cp -R "$UPDATE" "$STAGING"; then ...`），仅当复制完全成功才执行 `rm -rf "$APP" && mv "$STAGING" "$APP"`，失败则清理 `$STAGING` 保留旧版。

#### Item 17 — 修复配置导出类型、Profile 哨兵、校准向导与 0 值恢复边界（`ConfigStore.swift` / `ProfileManager.swift` / `CalibrationWizardView.swift` / `FUnManager.swift` / `AppDelegate.swift`）
- **`ConfigStore` 导出/导入类型精确还原**：按 key 已知类型表或显式类型前缀（如 `_bool:` / `_int:` / `_b64:`，同时向后兼容旧版无前缀 JSON）编码，确保纯数字字符串（Wi-Fi SSID、手机号 `iMessageNotifyRecipient`、`deviceName`）不会被误转成 `Int`，`Bool` 不会变成 `"1"/"0"`。
- **`ProfileManager.importFrom` 保护哨兵**：导入前若 `unlockRSSI == SignalHysteresisEngine.unlockDisabled` 原样保留不钳制；若 `lockRSSI == SignalHysteresisEngine.lockDisabled` 原样保留不钳制；仅对有效阈值执行 `clampRSSI` 与 `lock < unlock` 校验。
- **`CalibrationWizardView`**：
  - 进入校准（Step 1~4）期间在 `FUnManager` 置 `isCalibrating = true`（`onDeviceLeft` 检查并跳过锁屏，校准结束/取消/关闭 `onDisappear` 时复位），避免走远校准锁定距离时把电脑锁掉；
  - `applyValues()` 对 `finalUnlock = SignalHysteresisEngine.clampRSSI(max(unlock, lock + lockUnlockDelayGap))` 做上限钳制，并保证 `lock = min(lock, finalUnlock - 1)`，同时 `suggestedUnlock`/`suggestedLock` 预览值与实际应用值一致。
- **配置边界**：`FUnManager.setUnlockRSSI` 仅在原 `lockRSSI` 违反 `lock < unlock`（或从未设置）时才联动调整，不强行覆盖用户自定义合法锁定阈值（同时保持 OverviewView 滑块联动逻辑）；`AppDelegate.restoreSettingsToFUn` 改用 `prefs.object(forKey:) as? Int` 校验正数范围（如 `timeout > 0`、`lockDelay > 0`）而不是模糊的 `!= 0`。

---

### Batch 4：日志性能、可观测性、测试隔离、CI 与文档（P2）

#### Item 18 — `timingLog` 异步写盘 + 按事件名限流 + 有界字典（`FUnlockUtils.swift`）
- 提取事件名 key（解析首段 `event=<name>`，否则取首空格前前缀），按事件名而非含动态 RSSI 的整行文案限流（1 秒 1 条）；限流字典超过上限（如 256）时清理过期条目，杜绝无界增长。
- 磁盘写入与滚动迁至专用串行队列 `com.funlock.timingLog`（`qos: .utility`）异步执行，不再阻塞 `@MainActor`；保留 `flushTimingLogForTesting()` 供单测同步断言。

#### Item 19 — 廉价门控前置 + 蓝牙异常状态告警 + 可观测性修复（`UnlockOrchestrator+AutoUnlock.swift` / `FUnSignalProcessor.swift` / `BLEScanner.swift` / `FUn.swift` / `FUnManager+Events.swift` / `AppDelegate.swift`）
- `UnlockOrchestrator.attemptAutoUnlock`：将廉价纯内存门控（`presence`、`unlockRSSI != UNLOCK_DISABLED`、`effectiveRSSI >= unlockRSSI`、`canAttemptUnlock`、`lockBuffer`、`unlockCooldown`、`manualLock`）全部放到 `SystemInteractionService.shared.isScreenLocked(...)`（跨进程 CGSession + `NSRunningApplication` 查询）之前，并跳过已解锁时的无意义高频派发（`FUnManager.onDeviceApproached` 在 `state.screen == .unlocked` 且系统未锁时早退）。
- `BLEScanner.centralManagerDidUpdateState`：处理 `.unauthorized` / `.unsupported` 并通知宿主记录告警日志与状态；`FUn.scannerDidPowerOn` 重置 `powerWarn = true`（恢复供电后下次再断电可重新告警，并配限频防骚扰）。
- `FUnManager+Events.onDeviceLeft`：先以当前真实屏幕态记录 `recordLock(lockReason)`（或显式记录锁前态/目标锁态 `.locked(reason: away/lost)` 而非误记成 `.displaySleeping`），且仅当 `sleepDisplay == true` 时将 `state.screen` 设为 `.displaySleeping`，否则设为 `.locked(reason: reason == "lost" ? .lost : .away)`。
- `AppDelegate` 的 `connected` 状态以 BLE 信号/连接活跃度驱动（监控设备存在活跃连接或最近 15s 内收到过广播/RSSI 即 `connected = true`，断连且超过 15s 无采样或 `markSignalLost` 置 `false`），与 `onDeviceLeft` 业务拦截解耦，消除设备离开后菜单栏滞后 180s 仍显示「已连接」的问题。

#### Item 20 — 日志脱敏与 `os_log` 隐私级别（`AppLog.swift` / `FUnManager+Events.swift`）
- `AppLog` 对敏感字段键（`ssid`、`recipient`、`key`、`password`）自动脱敏（如掩码保留首尾或 hash），同时在 `os_log` 输出中区分非敏感结构化字段与 `.private` 字段，降低诊断包外发泄露隐私风险。

#### Item 21 — 测试彻底隔离生产日志与真实锁屏（`DebugLog.swift` / `FUnlockUtils.swift` / `FUnlockTests/TestSupport.swift`）
- 参照 `DecisionLogger.swift:136` 的模式，在 `DebugLog.logDirectory` 与 `timingLogDirectory`（以及 `TelemetryLogger`、`ScriptRunner`）中增加 `NSClassFromString("XCTestCase") != nil` 自动回退到 `FileManager.default.temporaryDirectory`，未显式指定 `testLogDirectory` 时也绝不污染用户 `~/Library/Logs/FUnlock/`。
- 在测试宿主或 `TestSupport` 中提供统一的自动初始化钩子（如 `XCTestObservationCenter` / 全局注册），默认将 `SystemInteractionService.lockActionOverride = {}` 安装到所有测试类，避免新增测试误锁用户电脑。
- 为本次修复的所有关键路径补齐确定性单元测试：输入活动监测、切 Tab 不停扫、8s 慢轮询不误断连、快锁需新样本确认、`unlockTask` 高频不自取消、息屏未锁唤醒不卡死、取消验证不计失败、屏保/锁屏双向乱序、Bark 空 Key 与 HTTPS 校验、SQLite 绑定与只读、更新下载同步移动与 `"not set"` 拒绝、配置导入导出纯数字与哨兵保护、`timingLog` 异步与按事件限流。

#### Item 22 — 清理重复 CI & 修正 README 偏差（`.github/workflows/test.yml` / `README.md`）
- 删除重复且缺 `CODE_SIGNING_ALLOWED=NO` 的 `.github/workflows/test.yml`（保留已正确配置禁用签名且覆盖完整测试与构建的 `.github/workflows/ci.yml`）。
- 修正 `README.md` 中两处与实现不符的说明：Keychain 访问级别说明更新为 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`（并解释为何锁屏自动解锁需要首次解锁后可读），用户脚本路径说明明确为对应 Bundle ID 目录（`~/Library/Application Scripts/com.fuhahah.FUnlock/event`）。

---

## 6. 留给实现者决定的细节（Left to Builder）

- 辅助函数、内部代次 token、测试辅助类型与新单测文件的具体命名和组织方式。
- `ConfigStore` 导出格式在保持向后兼容旧 JSON 前提下的具体类型标签编码细节。
- `AppLog` 敏感字段掩码格式（如保留前 2 位 + `***` 或短哈希）。
- 现有测试中若存在直接断言旧 bug 行为（如旧 `lockRSSI == -100` 回退 `unlockRSSI` 或旧 `BarkNotifier.Defaults.key` 非空）的用例，需在对应 Batch 中明确列出并同步更新测试断言。
