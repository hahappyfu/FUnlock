# 第二轮 Ponytail 精简 — 审计报告 + 执行计划

## 0. 硬性护栏（执行者必读，违反即打回）

1. **只能精简代码，不能精简功能**。每个删除动作前自问：「这行是功能还是实现细节？」把整段核心算法（锁屏/解锁/心跳/冷静期/阶梯阈值）当功能对待，**一行都不许删改逻辑**。
2. **P0 高危区（禁止重构）**：`FUn.startLockTimer`、`resetSignalTimer`、心跳 `makeHeartbeatTimer`、`checkProximity`、`applyLockTimer`、`updateMonitoredPeripheral`、`didReadRSSI` 内锁内的代码、`FUnManager.performInjectionAndVerify`、`SystemInteractionService.fakeKeyStrokes` 注入链路。这些是有 P0 崩溃/误锁历史的高敏区，本轮**只允许删其中「成对重复日志」与「print」级别的冗余，不允许动控制流**。
3. **锁内代码戒条**：`lock.withLock { ... }` 或任何持有 `os_unfair_lock` 的闭包内，**禁止调用 `getEffectiveRSSI()` 等内部会再加锁的方法**（上轮 P0 崩溃根因）。凡动锁内代码，改完必须跑 Release 构建 + 全套测试。
4. **每个任务独立 commit**，commit message 带 `（ponytail）` 标记，中文 message。
5. **每完成一个任务跑一次全量测试**，确保 398 个基线测试一个不丢，全绿后才进入下一个任务。
6. 执行完后更新本留言板 Status + 追加 LOG，说明每个任务的 commit hash 与测试结果。

## 1. 审计发现（标注 ponytail 标签）

总览：`delete:` 4 组、`shrink:` 4 组、`yagni:` 1 组、观察 2 条、明确不做 1 条。
预计净减：**主代码约 -480 ~ -620 行，测试约 -300 行，0 依赖移除**。

### delete: 死代码（高收益、低风险）

**D1. `MenuTab.device` 死 tab** — `MainWindowView.swift:11` case 定义 + `:144-145` contentView 分支
- 证据：SidebarView 三个分组（common/settings/diagnostics）均无 `.device` 入口；无任何代码 `select` 或 `newValue` 它；`contentView` 中 `.device` 与 `.overview` 渲染同一个 `OverviewView`。
- 动作：删 case + `case .device` 分支（保留 `.overview`）。约 -4 行。

**D2. `MenuBarPopoverView.connectionColor` 未使用属性** — `MenuBarPopover.swift:169-172`
- 证据：全文无引用。
- 动作：删除。约 -4 行。

**D3. 10 处 `print(...)` 冗余调试日志**（GUI app 中 print 被丢弃，且与 Log.* 成对重复）
- `FUn.swift:385, 392, 708, 863`（均有相邻 `Log.ble.debug` 同一信息）
- `FUnManager.swift:458, 820, 834`（相邻有 `Log.sm.debug` 或 `timingLog`）
- 动作：删 print，保留 Log.* / timingLog。约 -10 行。

**D4. `FUnlockResultVerifier` 结构体 + 两个专属测试类** — `FUnManager.swift:954-1045`；`FUnlockTests.swift:1038-1360`（约 -90 生产行 + -300 测试行）
- 证据：生产代码除定义处外**零调用**（grep 确认）。生产实际走 `unlockEventExtras` + `ScriptRunner` 直调（`FUnManager.swift:732,757,792`）。
- 该结构体是被测试养着的平行实现，不承载任何生产功能。
- **前置审查（执行者必须完成）**：FUnlockTests 1038-1360 引用该结构体的测试，逐一确认其**只测结构体自身方法**（`logUnlockResult`/`logUnlockResultTimeout`/`makeExtras`），不测生产路径。若发现测试间接覆盖了生产事件格式，需先为 `unlockEventExtras` 补等价回归测试再删。
- 动作：删结构体 + 两个测试类（`FUnlockResultVerifierTests`、`FUnlockResultVerifierIntegrationTests`）。

### yagni: 单实现抽象 / 测试专用双版本

**Y1. `SystemInteractionService.verifyUnlock` 实例版 + 静态注入版** — `SystemInteractionService.swift:436-498`
- 两方法逻辑完全相同，静态版仅供测试注入闭包。
- 动作（可选，若做需小心）：实例版改为「调用静态版 + 传真实系统闭包」，删实例版重复逻辑。约 -20 行。
- 该文件 ⚠️ 无覆盖测试，改动后至少保证编译 + 全量测试不回归。

### shrink: 同逻辑更少行

**S1. `FUn().UNLOCK_DISABLED` 工厂实例读常量** — 3 处：`FUnManager.swift:224`、`OverviewView.swift:41,85`
- `FUn.swift:132` `let UNLOCK_DISABLED = 1`、`:133` `let LOCK_DISABLED = -100` 是**实例属性**，却被当静态用。3 处 `FUn()` 新建无意义 FUn 实例（连带初始化 CBCentralManager，曾在启动初始化里干活）。
- 动作：`UNLOCK_DISABLED`/`LOCK_DISABLED` 改为 `static let`；3 处 `FUn().X` 改 `FUn.X`。其余 `fun.UNLOCK_DISABLED`（实例访问静态成员）语法依然有效，无需改，但可顺手统一为 `FUn.UNLOCK_DISABLED`（可选）。

**S2. 成对重复日志收敛**（低优先级，可选） — 主要集中于 `SystemInteractionService.swift`（37 处 `logDebug` 与 30 处 `Log.sm.debug` 成对）、`FUnManager.swift`、`FUn.swift`
- 同一条信息既写 `/tmp/funlock_debug.log` 又写 os.log，开发期排障冗余。
- 动作：**仅删同一函数内紧邻成对、信息完全重复的那一行**（保留一套即可，推荐保留 `Log.sm.debug`/`Log.ble.debug` 即 os.log 版；`logDebug` 保留给 SystemInteraction 注入链路做文件留痕）。每处单独判断，拿不准就跳过。
- 若执行者觉得风险高，可整项跳过并在报告注明「S2 跳过」。

**S3. `getMACFromUUID` / `getNameFromMAC` 重复读同一 plist** — `FUn.swift:37-54`
- 两函数各自 `NSDictionary(contentsOfFile: .../Bluetooth.plist)` 读一次整表。可合并为一次读取，返回 `(mac, name)`。
- 动作（可选）：合并为单个 helper，两个 call site 调整。约 -8 行。⚠️ 无专属测试，改动后跑构建 + 手动冒烟（设备发现路径）。

**S4. `AppDelegate.openSettings(_:)` 与 `requestAccessibilityIfNeeded()` 重复「AppleScript 打开系统设置」** — `AppDelegate.swift:159-162` vs `419-429`
- 两处内联几乎相同的 `tell application "System Settings" ... reveal pane id` 脚本。
- 动作：抽私有 `openSystemSettingsPane(_ pane: String)`，两处复用。约 -8 行。

### 观察（本轮不动，仅记录）
- `Device.description` iBeacon 分支用 `Data(bytes:count:)`（废弃 API，有警告风险）— 功能逻辑，保留。
- `Log.dev` 仅 `LEDeviceInfo` 用 4 次 — 保留。

### 明确不做
- **不碰**：信号管道（SignalPipeline Kalman/EWLR/IQR）、锁冷静期（proximityGracePeriod）、快速轮询节奏、动态阶梯阈值、联动迟滞、斜率自适应锁屏。这些全是上轮被误删、本轮红线「不能精简功能」的保护对象。

## 2. 执行计划（任务分解，供 opencode 逐条执行）

> 每个任务：独立 commit → 跑全量测试 → 全绿才进下一个。commit message 用 `refactor: ...（ponytail）`。

### 任务 1：死代码清理（D1 + D2 + D3）
1. `MainWindowView.swift`：删 `case device` 枚举项 + `contentView` 中 `case .device:` 分支。
2. `MenuBarPopover.swift`：删 `connectionColor` 计算属性。
3. `FUn.swift` + `FUnManager.swift`：删列出的 10 处 `print(...)`。
4. 跑：`xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' test`
5. commit：`refactor: 清理死 tab/未用属性/冗余 print（ponytail）`

### 任务 2：阈值常量静态化（S1）
1. `FUn.swift`：`UNLOCK_DISABLED`、`LOCK_DISABLED` 改 `static let`（注意在类内使用处如 `self.LOCK_DISABLED` 变 `Self.LOCK_DISABLED`，`fun.UNLOCK_DISABLED` 保持亦可）。
2. `FUnManager.swift:224`、`OverviewView.swift:41,85`：`FUn().X` → `FUn.X`。
3. 跑全量测试。commit：`refactor: 阈值禁用常量静态化，消除无意义 FUn 实例（ponytail）`

### 任务 3：FUnlockResultVerifier 移除（D4，需前置审查）
1. **前置审查**：逐条读 `FUnlockTests.swift:1038-1360`，确认引用该结构体的测试只测其自身方法、不测生产事件格式；若否，先为 `unlockEventExtras` 补等价测试（1-2 个即可）。
2. 删 `FUnManager.swift:954-1045` 结构体。
3. 删两个测试类 `FUnlockResultVerifierTests`、`FUnlockResultVerifierIntegrationTests`（若同一类内夹杂生产测试，只删相关 method）。
4. 跑全量测试。commit：`refactor: 移除生产零调用的 FUnlockResultVerifier 及专属测试（ponytail）`

### 任务 4（可选）：verifyUnlock 双版本合并（Y1）
1. `SystemInteractionService.swift`：实例版 `verifyUnlock` 改为 `Self.verifyUnlock(timeout:notificationTimeout:waitForNotification:checkUnlocked:)` 调用静态版，传真实 `waitForUnlockNotification`/`checkScreenUnlocked` 闭包。
2. 确认 `@MainActor` 语义不丢。
3. 跑全量测试。commit：`refactor: 合并 verifyUnlock 实例/静态双实现（ponytail）`

### 任务 5（可选）：plist 读取合并 + 系统设置 helper（S3 + S4）
1. `FUn.swift`：合并 `getMACFromUUID`/`getNameFromMAC` → 单次读 plist，返回 `(mac: String?, name: String?)`；更新 `didDiscover` 调用点。
2. `AppDelegate.swift`：抽 `openSystemSettingsPane(_:)`，替换两处内联 AppleScript。
3. 跑全量测试 + 构建。commit：`refactor: 合并 plist 读取与系统设置跳转 helper（ponytail）`

### 任务 6（可选，可跳过）：成对双日志收敛（S2）
1. 逐处删 `SystemInteractionService.swift`/`FUnManager.swift`/`FUn.swift` 中与 `logDebug`/`Log.*` 紧邻成对、信息完全重复的一行（保留一套）。
2. 每删一处跑一次构建；整步做完跑全量测试。
3. 若某处拿不准保留哪套，跳过该处。commit：`refactor: 收敛成对重复日志（ponytail）`

## 3. 验收标准

1. `xcodebuild ... test` 全量通过，**398 个基线测试一个不丢**（D4/Task3 只允许删专属测试类，若删后测试数 < 398 需说明差额全部来自 FUnlockResultVerifier 专属类）。
2. 主源码行数从 8,862 减少（删除量在 commit diff 可见）。
3. 对照功能清单逐项确认未删功能：走近快速轮询、动态阶梯阈值、联动迟滞、斜率自适应锁屏、iMessage 通知、导入导出、脚本、统计、诊断、遥测、更新检查、权限引导 → 全部保留。
4. 每个任务一个 commit，message 带 `（ponytail）`。
5. 完成后再跑 `git diff main --stat` 核对总改动面。
6. 在本留言板 Status 登记完成 + LOG 追加结果（commit hash 列表 + 测试数 + 净删行数）。
