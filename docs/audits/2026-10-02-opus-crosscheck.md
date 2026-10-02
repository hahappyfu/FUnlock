# FUnlock 试运行审计独立复核报告 (2026-10-02)

> 审计人员：独立审计复核员（Opus 5 独立审查）  
> 审计基线：不信任前序报告（`docs/audits/2026-10-02-audit-report.md`），独立核对源码（Git HEAD: `b41341d`）、实时运行态（PID 873, v2.8.37 build 1523）与全量系统日志。  
> 数据来源（全部只读）：
> - `~/Library/Logs/FUnlock/decisions.jsonl`（2794 行）
> - `~/Library/Logs/FUnlock/debug.log` 与 `debug.log.old`
> - `~/Library/Logs/FUnlock/timing.log` 与 `timing.log.old`
> - `~/Library/Logs/FUnlock/shadow_telemetry.csv`（181 行）
> - `~/Library/Application Support/FUnlock/events.log`（537 行）
> - `defaults read com.fuhahah.Funlock.config`
> - 系统实时采样（`sample` / `ps`）与 `~/Library/Logs/DiagnosticReports/`

---

## 总体复核结论

经独立全量复核：
1. **8 条核心断言核实**：7 条完全**证实**，1 条统计数字**基本证实**（明确了 intruded 29 条的统计区间口径为 09-29 之后）。
2. **重大新问题发现（原报告遗漏）**：
   - **【P1 致命缺陷】呼吸动画绑定漏洞**：`b41341d` 的修复在 transient Popover 场景完全失效！由于缺少 `NSPopoverDelegate`，点击菜单栏展开一次弹窗后，外部点击关闭根本不会触发 SwiftUI 的 `.onDisappear`。实时采样证实 PID 873 的 `RepeatAnimation` 正以 **15%~19% CPU** 长期空转，自今日 11:08 点开后已持续空转 5.5 小时！原报告误以为修复生效。
   - **【P2 单测污染生产环境】**：查明 `events.log` 中 96 条 `test_default_window`（2023-11-15）的根本原因——`FUnlockTests/StateAndConfigTests.swift:248` 构造 `ScriptRunner` 时漏传 `testLogDirectory`，导致每次跑测试都向真实生产日志写入 2 行脏数据。
   - **【P2 报告方法论纠偏】**：原报告称"每次手动解锁均触发联网更新检查（4 天 22 次）"被**证伪**。`UpdateChecker.check()` 内部存在严格的 24 小时节流门控，并未产生 22 次网络请求。

---

## 第一部分：待核实的 8 条断言复核

### 断言 1：intruded 误报 —— 【证实】
- **复核结论**：完全证实。
- **证据摘要**：
  1. **日志时间对齐**：全量交叉匹配证实，两窗口内所有 22/22 次 `userUnlocked`（旧窗口 6 次、新窗口 16 次）都在 **2.04 ~ 2.33 秒后 100% 触发 `intruded` 事件**，无一幸免。其中包含大量设备贴身（RSSI -48 ~ -66 dBm，远优于 -65 dBm 阈值）的合法解锁场景。
  2. **源码根因**：`FUnlock/FUnManager+Events.swift:118-129` 中 `intrudeCheckTask` 仅判断 `if !wasFUnUnlock` 与 `self.fun.unlockRSSI != FUn.UNLOCK_DISABLED`，完全**没有判断当前 RSSI 是否在场或高于阈值**。用户手动输入密码解锁时 `wasFUnUnlock` 恒为 `false`，导致 2 秒后无条件误报入侵。

### 断言 2：首注失败 —— 【证实】
- **复核结论**：完全证实。
- **证据摘要**：
  1. **序列一致性**：日志中全部 7 次 `unlockFailed`（旧窗口 2 次：09-29 14:05、16:05；新窗口 5 次：09-30 10:13、12:22、15:36、17:21，10-02 16:09）均为"第 1/3 次尝试"。7 次在 `debug.log`/`debug.log.old` 中的日志模式完全一致：`isDisplayPoweredOn: IOEnginePower not found` → `sendShiftKey: SUCCESS` → `waiting 300ms` → `Level 1: SUCCESS (posted=true)` → `dual verify failed (timeout)`。
  2. **用户放弃等待**：其中 3 次在失败后用户迅速手动输密码：
     - 09-30 15:36:41 失败 → 8.9 秒后（15:36:50）用户手动解锁
     - 09-30 17:21:45 失败 → 1.7 秒后（17:21:47）用户手动解锁
     - 10-02 16:09:10 失败 → 1.8 秒后（16:09:12）用户手动解锁
  3. **源码硬编码**：`FUnlock/SystemInteractionService.swift:332` 硬编码等待 `try? await Task.sleep(nanoseconds: 300_000_000)`（固定 300ms），低于熄屏唤醒 loginwindow 密码框就绪所需的实际物理时间。

### 断言 3：axRevoked 误报 —— 【证实】
- **复核结论**：完全证实。
- **证据摘要**：
  1. **竞态日志证据**：2026-09-30 11:57:11，`debug.log` 记录 Level 1 / Level 2 失败后，尝试 Level 3 时捕获 `Level 3: ABORT - screen no longer secure before AppleScript`，导致 `fakeKeyStrokes() END - result=false`，`posted=false`。而在 5 秒内屏幕状态已变为 `unlocked`（用户在注入过程中已手动解锁，屏幕已脱离锁定保护态）。
  2. **源码误折叠**：`FUnlock/UnlockOrchestrator.swift:170-177` 将任意 `guard posted else` 无差别判定为 `recordUnlock(.blocked, reason: .axRevoked)` 并触发 `sys.showAXRevokedAlertIfNeeded(lastAlertTime: &lastAXRevokedAlertTime)`。
  3. **模态弹窗劫持**：`FUnlock/SystemInteractionService.swift:541` 直接调用 `alert.runModal()` 抢占用户焦点，将瞬态安全竞态误当成权限撤销并弹窗。

### 断言 4：预唤醒不可达 —— 【证实】
- **复核结论**：完全证实。
- **证据摘要**：
  1. **全量日志零触发**：在全量 `debug.log(.old)` 和 `timing.log(.old)` 中检索 `[SM] pre-wake triggered`，结果确为 **0 次**。
  2. **休眠期采样缺口实证**：在 10-01 02:53→10:59 夜间休眠窗口，`debug.log` 记录在 09:08:03 到 09:16:54 之间出现了长达 **531.57 秒（约 8.86 分钟）** 的无 BLE 发现断流缺口（两端事件间隔 527s）。
  3. **阈值计算失配**：`FUnlock/FUnSignalProcessor.swift:313` 计算公式为 `max(u - advance, -100)`。当前配置 `unlockRSSI = -65`, `wakeAdvance = 20`，计算得 `preWakeThreshold = -85`，与配置的 `lockRSSI = -85` 恰好完全相等，导致提前量实质归零。
  4. **状态机门控死锁**：`FUnlock/FUnManager+Events.swift:200, 286` 均严格限制 `state.screen == .displaySleeping`。当用户手动锁屏后屏幕状态为 `locked(manual)`，即使显示器进入黑屏状态，该门控也永远无法满足，预唤醒结构性失效。

### 断言 5：wifiPaused 消失 —— 【证实】
- **复核结论**：完全证实。
- **证据摘要**：
  1. **日志断崖**：`defaults` 确认 `pauseOnWiFi = 1`、`pauseOnWiFiSSID = "Xiaomi_DB79_5G"` 配置完好。`decisions.jsonl` 中共 1335 条 `wifiPaused`，全部分布在 09-29 21:42 至 09-30 06:55。自 09-30 06:55:16 之后，记录**彻底归零**。
  2. **代码静默 fail-open**：`FUnlock/WiFiMonitor.swift:21-27` 在 `CWWiFiClient.shared().interface()?.ssid()` 失败（因未关联网络或 macOS 27 定位权限缺失）时直接返回 `nil`；调用方 `FUnlock/UnlockOrchestrator+AutoUnlock.swift:80-98` 未匹配到 SSID 时静默跳过，无任何 error/warn/debug 日志，导致无法从日志界定是"未连 Wi-Fi"还是"权限受阻导致读取失败"。

### 断言 6：遥测 Result 列 100% N/A —— 【证实】
- **复核结论**：完全证实。
- **证据摘要**：
  1. **CSV 全量复核**：`shadow_telemetry.csv` 当前累计 181 行，其 `Result`、`Duration_ms`、`InjectTime`、`ConfirmTime` 四列取值集合全为 `{'N/A'}`。
  2. **源码传参遗漏**：`FUnlock/UnlockOrchestrator.swift:207-212`、`294-298` 以及 `FUnlock/FUnManager+Events.swift:247-255` 调用 `TelemetryLogger.shared.log(...)` 时，均未传入上述 4 个参数，全部落入 `FUnlock/TelemetryLogger.swift:104-107` 定义的默认缺省值 `"N/A"` 与 `nil`。

### 断言 7：Debug 构建 —— 【证实】
- **复核结论**：完全证实。
- **证据摘要**：
  1. **包体元数据核验**：
     - `mdls /Applications/FUnlock.app` 显示 `kMDItemCFBundleIdentifier = "com.fuhahah.FUnlock-dev"`。
     - `otool -l /Applications/FUnlock.app/Contents/MacOS/FUnlock` 包含 `LC_LOAD_DYLIB @rpath/FUnlock.debug.dylib`。
     - `find /Applications/FUnlock.app` 明确存在 `FUnlock.debug.dylib`。
  2. **Keychain 隔离风险**：`FUnlock/SecurityService.swift:25` 初始化参数默认为 `Bundle.main.bundleIdentifier ?? "FUnlock"`。从 `-dev` 切回正式版 `com.fuhahah.FUnlock` 将读取不同的 Keychain 条目，若生产条目未同步将导致密码读取失败。

### 断言 8：样本统计数字 —— 【基本证实（明确口径）】
- **复核结论**：数据核心一致，对 intruded 统计口径补充说明。
- **复核数据表**：
  | 统计指标 | 原报告声称 | 独立复核结果 | 状态 | 说明 |
  |---|---|---|---|---|
  | 解锁成功 (unlockSuccess) | 18 | **18** | 证实 | 旧窗口 8 (含 09-28 补充 2 次), 新窗口 10 |
  | 首注失败 (unlockFailed) | 7 | **7** | 证实 | 旧窗口 2, 新窗口 5 (全部为第 1/3 次尝试) |
  | 手动解锁 (userUnlocked) | 22 | **22** | 证实 | 旧窗口 6, 新窗口 16 |
  | intruded (P1-2 修复后) | 29 | **29（09-29起）/ 38（全量）** | 证实（口径明确） | 09-29×3、09-30×17、10-01×4、10-02×5，合计 29。若从 09-28 14:43 起计则为 38。剔除重装噪声 7 条后实际为 22 条，与 userUnlocked 100% 对应 |
  | wifiPaused | 旧 1335 / 新 0 | **旧 1335 / 新 0** | 证实 | 09-30 06:55:16 之后准确为 0 |
  | manualLockActive | 新窗口 1230 | **新窗口 1230** | 证实 | decisions.jsonl 新窗口完全吻合 |
  | degraded 记录 | 0 | **0** | 证实 | 全日志关键词检索 0 次 |
  | ERROR 级日志 | 0 | **0** | 证实 | debug.log / debug.log.old 中 0 条 |

---

## 第二部分：独立发现的新问题清单（原报告遗漏）

### 1. 【P1 致命】`b41341d` 呼吸动画启停在 transient NSPopover 下完全失效，单次展开后永久空转消耗 15%~19% CPU
- **现象**：当前运行进程（PID 873）CPU 占用高达 **15.2% ~ 19.3%**，累计运行 CPU 时间已达 47 分 44 秒。
- **根因分析**：
  1. `b41341d` 在 `MenuBarPopoverView` 中通过 `.onAppear` / `.onDisappear` 同步 `popoverVisible` 试图控制 `statusDot` 的 `repeatForever` 呼吸动画。
  2. 但在 AppKit 中，状态栏 `NSPopover` 设置为 `popover.behavior = .transient`（`AppDelegate.swift:551`），且**未设置 `popover.delegate`**。
  3. 当用户点击状态栏展开 Popover 后，点击屏幕外部任意区域，AppKit 仅执行窗口 `orderOut:`。由于 `contentViewController` 依然常驻内存且宿主视图未脱离，**SwiftUI 根本不会触发 `.onDisappear` 回调**！
  4. 证据链：
     - 日志显示用户在 `2026-10-02 11:08:54.286` 唯一一次点击展开了 Popover。
     - 自该时刻起至当前 16:40（5.5 小时内），通过 `sample 873` 实测捕获到大量 `RepeatAnimation.animate`、`NSHostingView.layout()` 与 `CA::Transaction::commit()`，主线程每秒产生数百帧高频重绘。
     - 5.5 小时 × 15% CPU ≈ 49.5 分钟 CPU 时间，与当前累计的 47:44 CPU 完全吻合。
  5. **原报告误判**：原报告看到平均 CPU 为 1%，推测 `b41341d` 修复生效。实际上是前面 41 小时静置未点开弹窗（0% CPU），而一旦用户在 11:08 点开一次后，进程就永久陷入了 15%~19% 的高负载空转！
- **修复方案**：`AppDelegate` 实现 `NSPopoverDelegate`，监听 `popoverDidClose`，显式通知 SwiftUI 视图重置 `popoverVisible = false`，或者关闭时直接释放 `popover.contentViewController`。

### 2. 【P2 漏洞】单测 `testDefaultDedupWindowIs3Seconds` 漏配临时目录，持续向生产环境 `events.log` 写入脏数据
- **现象**：`events.log` 中残留 96 条时间戳为 `2023-11-15` 的 `test_default_window` 事件。
- **根因分析**：
  - 在 `FUnlockTests/StateAndConfigTests.swift:248-249`：
    ```swift
    let defaultRunner = ScriptRunner(dedupWindow: 3.0) { [unowned self] in self.currentTime }
    XCTAssertTrue(defaultRunner.logEventIfNeeded("test_default_window"))
    ```
  - `ScriptRunner` 的便利构造器定义为：
    `init(dedupWindow: TimeInterval, nowProvider: @escaping () -> Date, testLogDirectory: URL? = ScriptRunner.shared.testLogDirectory)`
  - 单测的 `setUp()` 仅设置了局部实例 `runner.testLogDirectory = tempDir`，而 `ScriptRunner.shared.testLogDirectory` 仍为 `nil`。
  - 该用例直接使用了默认的 `testLogDirectory = nil`，写入路径落入真实用户的 `~/Library/Application Support/FUnlock/events.log`。单测中 `currentTime` 固定为 `1_700_000_000`（即 2023-11-15 06:13:20）。每次跑单测都会追加 2 条记录，96 条正是 48 次单测运行污染生产环境的铁证。
- **修复方案**：`testDefaultDedupWindowIs3Seconds` 显式传入 `testLogDirectory: tempDir`。

### 3. 【P2 缺陷】`DiagnosticsView` 分块渲染采用 `\.offset` 作为 ID，动态追加导致渲染乱序与闪烁
- **现象**：提交 `b41341d` 在 `FUnlock/DiagnosticsView.swift:179` 引入了分页分块：
  ```swift
  ForEach(Array(group.events.chunked(pageSize: Self.timelinePageSize).enumerated()), id: \.offset) { _, chunk in
      timelineGroup(events: chunk)
  }
  ```
- **缺陷分析**：使用数组下标 `\.offset` 作为 SwiftUI 唯一标识。由于时间轴数据是按时间倒序排列，当实时产生新的决策事件时，新事件会挤入第 0 块，导致所有后续块内的数据整体后移，但由于 offset ID 未变，SwiftUI Diff 机制会错误复用旧卡片内部状态，引发视图闪烁或滚动位置跳动。
- **修复方案**：分块应当使用稳定唯一 ID，如每块首末事件的 ID 组合或时间戳哈希。

### 4. 【P3 规范】`Info.plist` 构建号违规提交且与交接文档长久失配
- **证据**：`docs/handoff.md`（第 28 行、41 行）明文约定："CFBundleVersion 提交时保持 1258，部署时由脚本递增，勿提交递增值"。但提交 `ac02675` 将 `CFBundleVersion` 直接从 1521 变更为 1523 并提交推送到远程，破坏了部署自动化流程与版本基准。

---

## 第三部分：对原报告方法论与推论的质疑与纠偏

### 1. 质疑原报告 §P3-B "每次手动解锁触发一次联网更新检查（4 天 22 次）" —— 【证伪】
- **原报告论据**：称 `onUnlock` 尾部无条件调用 `checkUpdate()`，断言 4 天内发生了 22 次不必要的网络请求。
- **独立复核**：查阅 `FUnlock/checkUpdate.swift:22-27`：
  ```swift
  func check() {
      guard !notified, !checking else { return }
      let now = Date().timeIntervalSince1970
      guard now - lastCheckAt >= interval else { return } // 24 * 3600 秒
      doCheck()
  }
  ```
  `check()` 内部存在严格的 24 小时自然日限流。`ConfigStore` 中 `lastUpdateCheck = "1790874937.873882"`（2026-10-02 01:15:37）。在这 22 次手动解锁中，有 21 次在第 25 行直接退出，并未发出 HTTP 请求。原报告仅看调用栈未核查实现与流量，该推论被推翻。

### 2. 质疑原报告对 CPU "平均 1%" 的乐观评估
- 原报告推论："进程自 09-30 18:00 连续运行，累计 CPU ≈ 44 分钟（平均 ≈1%）... 当前平均 1% 说明 b41341d 的修复很可能已在运行版本内"。
- **纠偏**：平均值掩盖了严重的阶跃劣化。前 41 小时为 0% CPU，但 10-02 11:08 用户点开一次菜单栏后，CPU 跃升至 15%~19% 且持续空转至今。`b41341d` 并没有真正解决空转，只是将"启动即空转"推迟为"首次打开后永久空转"。

---

## 结论与行动建议汇总

| 优先级 | 事项 | 责任模块 | 处置建议 |
|---|---|---|---|
| **P1** | 修复 NSPopover 关闭不停止呼吸动画缺陷 | `AppDelegate.swift` / `MenuBarPopover.swift` | 实现 `NSPopoverDelegate.popoverDidClose`，显式通知 SwiftUI 停用动画并卸载视图 |
| **P1** | 修复手动解锁 100% 误报入侵 (P1-2 补丁) | `FUnManager+Events.swift:124` | 增加设备在场/RSSI 判定，只有在设备不在场（或信号极弱）时才派发 intruded |
| **P1** | 显示器熄灭场景首次注入等待过短 | `SystemInteractionService.swift:332` | 移除固定 300ms 等待，改为轮询 `isDisplayPoweredOn()` 电源就绪事件 |
| **P1** | 瞬态竞态误报 axRevoked 弹窗 | `UnlockOrchestrator.swift:170` | 注入失败后增加屏幕锁定二次校验与权限真伪确认，良性竞态不弹模态警告 |
| **P2** | 修复单测污染真实 `events.log` | `StateAndConfigTests.swift:248` | `ScriptRunner` 构造注入 `tempDir`，清理生产 `events.log` 中的历史测试数据 |
| **P2** | 补全 Wi-Fi 暂停静默 fail-open 的观测日志 | `WiFiMonitor.swift` / `UnlockOrchestrator` | SSID 为 nil 时记录诊断日志，诊断页提示定位权限/Wi-Fi 状态 |
| **P2** | 预唤醒阈值解耦与门控放宽 | `FUnSignalProcessor.swift` / `Events.swift` | 解耦 `preWakeThreshold` 与 `lockRSSI`；允许 `locked(manual)` 且熄屏时进入预唤醒 |
| **P3** | 补传遥测日志 Result 等 4 参数 | `UnlockOrchestrator.swift:207` | 接入验证结果、注入时间与耗时字段 |
| **P3** | 修复 `DiagnosticsView` 分块的 offset ID 隐患 | `DiagnosticsView.swift:179` | 为分块生成稳定唯一标识，避免动态刷新错位 |
| **P3** | 规范 `Info.plist` 构建号提交管理 | `FUnlock/Info.plist` | 统一恢复规范值 1258，明确版本提交流程 |
