# FUnlock 代码优化执行计划

> 基于审计报告 `docs/audits/code-audit-2026-06-17.md` | 创建日期: 2026-06-17
>
> **状态: 全部完成** ✅ | 完成日期: 2026-06-17
>
> **红线**: 绝不破坏非对称 Kalman 滤波、时间衰减逻辑、`InputActivityMonitor` 状态锁保护机制。

---

## 第〇阶段：编译基线确认（前置）

- [x] **T00** 运行 `xcodebuild -project BLEUnlock.xcodeproj -scheme FUnlock -configuration Release build 2>&1 | tail -20` — 确认当前基线可编译，记录输出。
  - 风险: 🟢 低 | 影响: 无 | 验证: `xcodebuild` 返回 0

---

## 第一阶段：低风险清理（无业务逻辑变更）

- [x] **T01** 删除死代码：移除 `FUnManager.swift:98` 和 `AppDelegate.swift:142` 中未使用的 `cancellables` 属性。
  - 风险: 🟢 低 | 影响: 无（全局无一处 `.store(in:)` 引用）| 验证: 编译通过 + `grep -rn 'cancellables' FUnlock/*.swift` 无残留

- [x] **T02** 移除冗余的 `@available(macOS 12.0, *)` 标注：`MenuDashboardView.swift:9` 和 `CalibrationWizardView.swift:6`。
  - 风险: 🟢 低 | 影响: 无（部署目标已是 12.0）| 验证: 编译通过

- [x] **T03** 修复更新检查 URL：`checkUpdate.swift:20` — 从 `api.github.com/repos/ts1/BLEUnlock` 改为 Gitee API 端点或项目自建端点。
  - 风险: 🟢 低 | 影响: 更新通知可能恢复生效 | 验证: 编译通过 + 查看 URL 字符串已更新

- [x] **T04** 修复废弃的 `@NSApplicationMain` → `@main`：`AppDelegate.swift:127`。
  - 风险: 🟢 低 | 影响: 应用入口，Swift 5.3+ 等价替换 | 验证: 编译通过 + 应用可正常启动

- [x] **T05** 删除废弃的 `NSUserNotificationCenterDelegate` 协议方法：`AppDelegate.swift:189` 的 `userNotificationCenter(_:shouldPresent:) -> Bool`。
  - 风险: 🟢 低 | 影响: 无（UNUserNotificationCenter 走新协议方法）| 验证: 编译通过

---

## 第二阶段：并发安全加固（核心风险线）

- [x] **T06** 为 `InputActivityMonitor` 的 `lastInputTime` 添加 `os_unfair_lock` 保护：`AppDelegate.swift:19,26,52`。
  - 风险: 🟡 中 | 影响: 修改 `lastInputTime` 读写路径，不改变对外接口
  - **红线守卫**: `isActive` computed property 的行为不变；`IOHIDManager` 回调路径保持轻量
  - 验证: 编译通过 + 人工验证输入活动检测仍正常工作

- [x] **T07** 移除 `FUnManager` 中 `@MainActor` 类内部的冗余 `DispatchQueue.main.async`：检查 `FUnManager.swift:429,438,480` 三处，若确在 MainActor context 则直接调用。
  - 风险: 🟡 中 | 影响: 唤醒重试、锁屏路径的调度时序
  - **红线守卫**: `wakeTask` 闭包内的调用链不变；`lockOrSaveScreen()` 的 `SACLockScreenImmediate()` 仍必须在主线程
  - 验证: 编译通过 + 确认 `wakeDisplay()` 和 `SACLockScreenImmediate()` 仍在主线程/主 actor 执行

- [x] **T08** 修复 `FUn.startMonitor()` 未清理 `connectionTimer` 的问题：`FUn.swift:184` 附近增加 `connectionTimer?.invalidate(); connectionTimer = nil`。
  - 风险: 🟡 中 | 影响: 快速切换设备时的连接管理
  - 验证: 编译通过 + 逻辑审查确保与 `connectMonitoredPeripheral` 中的创建配对

- [x] **T09** 修复 `FUnManager.cleanup()` 未清理 `heartbeatTimer` 的问题：`FUnManager.swift:668-671` 增加 `fun.cancelHeartbeat()` 调用。
  - 风险: 🟢 低 | 影响: 退出清理路径
  - 验证: 编译通过 + `cancelHeartbeat()` 已在 `FUn.swift:346` 定义为 `private`，需要暴露或直接在 cleanup 中调用公共方法

---

## 第三阶段：资源泄漏修复（IOPMAssertion）

- [x] **T10** 修复 `wakeDisplay()` 的 IOPMAssertion 泄漏：`lowlevel.c:5-25`。
  - 方案:
    1. 移除效果不明的第 1 种方式 (`IOPMAssertionDeclareUserActivity`)
    2. 将 `preventSleepID` 改为函数返回值传递，或新增 `releaseWakeAssertion()` 函数
    3. 保留 IORegistry 方式作为最深层的兜底
  - 风险: 🟡 中 | 影响: 显示器唤醒行为
  - **红线守卫**: `wakeDisplay()` 唤醒效果不退化；不破坏现有的 0.5s 重试 + 10 次上限逻辑
  - 验证: 编译通过 + 人工验证设备靠近时显示器能正常唤醒

- [x] **T11** 在 `FUnManager.startWakeRetry()` 中：每次重试完成后释放前次 `wakeDisplay()` 的 assertion（配合 T10 的 `releaseWakeAssertion()`）。唤醒成功或 10 次失败后最终释放。
  - 风险: 🟡 中 | 影响: 唤醒重试循环的资源管理
  - 验证: 编译通过 + 代码审查 assertion 创建/释放配对

---

## 第四阶段：架构解耦与健壮性

- [x] **T12** `checkUpdate.swift` 重构为 `UpdateChecker` 类：将全局变量 `notified`、`checking`、`lastCheckAt` 封装为实例属性；作为 `FUnManager` 的依赖注入。
  - 风险: 🟡 中 | 影响: 更新检查的调用方式，`FUnManager.onUnlock()` 中的 `checkUpdate()` 调用需改为 `updateChecker.check()`
  - 验证: 编译通过 + 更新检查逻辑不变

- [x] **T13** `AppDelegate.swift:305-314` 的 `NotificationCenter` block-based observers 迁移为 Combine 发布者 + sink（存入 `cancellables`）。
  - 风险: 🟡 中 | 影响: 系统通知的注册/注销，所有 8 个 observer 的闭包逻辑不变
  - **红线守卫**: `screensDidSleep`、`screensDidWake`、`willSleep`、`didWake`、`screenIsUnlocked`、`screenIsLocked`、`screensaver.didstart`、`screensaver.didstop` 的事件转发不丢失不重复
  - 验证: 编译通过 + 人工验证锁屏/解锁/休眠/唤醒事件仍被正确捕获

- [x] **T14** 修复强制解包（`!`）：`FUnManager.swift:554,577,595` 三处。
  - `554`: `password.data(using: .utf8)!` → `guard let pw = password.data(using: .utf8) else { return }`
  - `577`: `kCFBooleanTrue!` → `kCFBooleanTrue as AnyObject` 或 `true as CFBoolean`
  - `595`: `String(data: data, encoding: .utf8)!` → `guard let str = String(...) else { errorModal(...); return nil }`
  - 风险: 🟢 低 | 影响: 密码存取路径的错误处理更安全
  - 验证: 编译通过 + 密码为空或损坏时不会崩溃

- [x] **T15** 为 `FUnManager` 添加 `deinit`：取消所有 `Task` (`wakeTask`、`unlockTask`、`intrudeCheckTask`)。
  - 风险: 🟢 低 | 影响: 无（正常退出走 `applicationWillTerminate` → `cleanup()`）
  - 验证: 编译通过 + `deinit` 中的 cancel 调用与 `cleanup()` 保持一致

---

## 第五阶段：测试修复

- [x] **T16** 重写 `FUnlockTests.swift`：删除旧的 EMA 测试（API 已不兼容），为以下核心路径编写可编译、可运行的测试：
  1. `getEstimatedRSSI` — Kalman 单步/多步滤波正确性
  2. `getEffectiveRSSI` — 时间衰减计算正确性
  3. `LockScreenState.canAutoUnlock` — 各守卫条件
  4. `LockIntent.isManualLockActive` — 超时判断
  5. 信号丢失 3 次超时（`signalLostCount` 递增逻辑）
  - 风险: 🟡 中 | 影响: 测试覆盖
  - **红线守卫**: 不修改 `FUn.swift` 和 `FUnManager.swift` 的任何业务逻辑
  - 验证: `xcodebuild ... -scheme FUnlock -configuration Debug test 2>&1` 所有测试通过

---

## 执行顺序与依赖关系

```
T00 (基线编译)
 │
 ├─► T01 · T02 · T03 (独立低风险，可并行)
 │     │
 │     └─► T04 · T05 (废弃 API，依赖 or 不依赖 T01-03)
 │           │
 │           └─► T06 · T07 · T08 · T09 (并发安全，依赖 T00 基线)
 │                 │
 │                 ├─► T10 · T11 (IOPMAssertion，依赖 T00)
 │                 │
 │                 └─► T12 · T13 · T14 · T15 (架构/健壮性，可并行)
 │                       │
 │                       └─► T16 (测试，依赖前面所有)
```

---

## 统计

| 阶段 | 任务数 | 高优 | 中优 | 低优 |
|------|--------|------|------|------|
| 〇 基线 | 1 | - | - | 1 |
| 一 清理 | 5 | - | - | 5 |
| 二 并发 | 4 | - | 4 | - |
| 三 资源 | 2 | - | 2 | - |
| 四 架构 | 4 | - | 3 | 1 |
| 五 测试 | 1 | - | 1 | - |
| **合计** | **17** | **0** | **10** | **7** |

每个任务独立 commit，每次修改后验证编译。
