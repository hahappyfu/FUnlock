# FUnlock 全维度审计总报告

**日期**：2026-09-26　**版本**：2.8.37 (1499)　**分支**：main
**规模**：主程序 57 文件约 11,100 行 Swift + 测试约 4,700 行；Release 二进制 5.75MB；无第三方库依赖

---

## 0. 审计方法与合规性

- **方法**：架构通读（codegraph + 全量核心文件精读）→ 四维度并行专项审计（并发/算法/安全状态机/UI 架构，Fable 轮 + Sonnet 补充轮）→ 主审计者对每条关键结论独立交叉验证 → 运行实证（进程采样、日志增长实测、AppleScript 行为实测）。
- **合规性**：全程只读，未修改任何代码；对运行中 App 仅做只读采样与日志读取，无任何变更。全部发现均为对你自有软件的防御性披露，修复建议均为加固方向。
- **验证说明**：文中标注「实测」的结论经主审计者在本机复现确认；标注「已验证」的经代码路径复核；其余为子审计结论，均已核对文件行号。

## 1. 执行摘要

| 维度 | P0 | P1 | P2 | 一句话评价 |
|---|---|---|---|---|
| 算法/信号链 | 2 | 9 | 8 | 单模块数学干净，跨模块配参有三处实质错误 |
| 安全/状态机 | 3 | 10 | 7 | 注入纵深防御扎实，意图识别与更新链是弱点 |
| 并发/运行时 | 2 | 6 | 8 | 主干纪律好，Timer 线程契约系统性破损 |
| UI/类型/测试 | 0 | 10 | 22 | 分层清晰，配置系统与测试隔离是结构弱点 |
| **运行实测** | — | — | — | **CPU ≈15%（偏高）、内存 21MB（优秀）、日志 16MB（有界）** |

**最严重的三件事**：① 设备在强在场信号下突然消失（关机/没电）时，Mac 保持解锁约 3 分钟（衰减封顶 + 严格小于比较堵死了唯一的快速锁屏路径）；② 「只唤醒不解锁」开关在显示器休眠并行路径被绕过，用户明确禁用自动解锁时仍会注入密码；③ 静默自动更新链路（零确认 + 可预测 /tmp 路径 + 签名校验后 TOCTOU）是持有登录密码的工具的最高价值供应链劫持面。

## 2. P0 — 必须立即修复

| # | 问题 | 位置 | 场景 |
|---|---|---|---|
| P0-1 | **衰减封顶 20dB + 严格 `<` 比较使心跳锁路径在强在场信号下永不触发**。`decayedEffectiveRSSI` 惩罚封顶 20dB，锁定条件 `eff < lockThreshold` 严格小于：只要最后有效采样 ≥ 阈值-20（默认 -60），衰减后永不跌破阈值 → 心跳锁计时器永不启动。设备突然消失（关机/没电/强干扰）时唯一兜底是 3×60s 信号超时链 → **Mac 保持解锁约 180 秒** | [FUnLockCoordinator.swift:21-34](FUnlock/FUnLockCoordinator.swift:21), :137-154 | **实测**：用户在场 eff=-56~-59、lockRSSI=-85 时 -56-20=-76 ≥ -85 恒成立；断连处理注释「由心跳衰减机制判断 ~10 秒锁屏」证实设计意图与实现失效 |
| P0-2 | **`wakeWithoutUnlocking`（只唤醒不解锁）在显示器休眠并行分支被绕过**：displaySleeping 分支先于该 guard 执行并 return，0.8s 并行任务只复查 manualLock/systemReady → 用户明确关闭自动解锁时仍注入密码解锁 | [UnlockOrchestrator+AutoUnlock.swift:70-93](FUnlock/UnlockOrchestrator+AutoUnlock.swift:70) | 开 wakeOnProximity + 关自动解锁的用户，设备靠近即被解锁 |
| P0-3 | **静默自动更新全链路零确认**：检测到新版 → 自动下载 → 自动替换 /Applications 并重启，全程无用户确认；且每次解锁后 2 秒自动触发检查 | [FUnManager.swift:95-107](FUnlock/FUnManager.swift:95), [FUnManager+Events.swift:94](FUnlock/FUnManager+Events.swift:94) | GitHub release 被替换 → 所有用户下次解锁后被静默换装恶意二进制（该工具持有登录密码 + 辅助功能权限） |
| P0-4 | **`/tmp/FUnlock-update` 可预测共享路径 + 签名校验后 TOCTOU，可跨用户执行代码**：固定路径在 1777 目录，`removeItem` 被预占时静默失败 → 下载/解压/install.sh 落入攻击者目录；`codesign` 校验与安装之间有 `sleep 2` 窗口可换入未签名恶意副本 | [UpdateDownloader.swift:16,39-40](FUnlock/UpdateDownloader.swift:16), [UpdateInstaller.swift:23-69](FUnlock/UpdateInstaller.swift:23) | 同机其他用户预占目录 → 以受害者身份执行任意代码 |
| P0-5 | **Device 对象字段锁外写/锁内读数据竞争**：`device.rssi/manufacture/model/scanTimer` 在 bleQueue 锁外修改，`snapshotLocked` 在主线程锁内读 → 引用 retain/release 失衡风险 | [BLEPeripheralHandler.swift:257-281](FUnlock/BLEPeripheralHandler.swift:257), [BLEScanner.swift:244-250](FUnlock/BLEScanner.swift:244) | 连接成功 GATT 回调与 UI 派发并发时触发 |
| P0-6 | **`lockTimeout` 插值方向反了**：`t = (-slope - 1)/7`，slope=-7.9 得 4.96s（应 ≈2.54s）、slope=-1.1 得 2.54s（应 ≈4.96s）——陡降拿长超时、缓降拿短超时，且 -8/-1 两边界跳变 ±2.5s 不连续 | [SignalHysteresisEngine.swift:51-60](FUnlock/SignalHysteresisEngine.swift:51) | **已验证**（主审计重算）：快速离开锁屏多拖 ~2.5s；阈值旁缓降只给 2.5s |
| P0-7 | **`monitoredUUIDs` 锁外 `contains`**：CoW 容器并发读 + 锁内写 = 未定义行为 | [BLEScanner.swift:218,227](FUnlock/BLEScanner.swift:218) | 绑定/解绑设备同时处理 didDiscover 洪流 |

## 3. P1 — 错误行为 / 安全加固 / 竞态

### 3.1 锁屏意图识别与事件竞态（根因：distributed notification 不可靠时无 CGSession 实测兜底）

- **手动启动屏保不被识别为手动锁定**（[FUnManager+Events.swift:98-101](FUnlock/FUnManager+Events.swift:98)）：`onScreensaverStart` 不设 intent → 用户热角屏保后设备靠近仍自动解锁。
- **`isSelfLocking` 单布尔无超时复位**（[FUnManager+Events.swift:113-130](FUnlock/FUnManager+Events.swift:113)）：锁屏通知丢失后标志残留 true → 用户下次手动锁屏被误判为自动 → 手动锁屏保护失效。
- **自动锁屏失败静默无验证**（[FUnManager+Events.swift:179-191](FUnlock/FUnManager+Events.swift:179)）：SACLockScreenImmediate 在无 AX 权限时降级为仅关屏不锁会话、屏保未设密码要求时同样不锁——但照样通知「已锁定」，虚假安全感。
- **屏保期间双保险验证误报「已解锁」**（[SystemInteractionService.swift:53-56](FUnlock/SystemInteractionService.swift:53)）：屏保运行时 `CGSSessionScreenIsLocked==0` → 注入失败被记成功 → **失败计数清零，degraded 降级保护可被绕过**。
- **manualLock 24h deadline 与「永久阻止」语义矛盾**（[LockScreenState.swift:40-47](FUnlock/LockScreenState.swift:40)）：手动锁屏 24 小时后（期间未解锁）设备靠近仍自动解锁。
- **FUn 自唤醒显示器触发 onUserIntervention 取消刚调度的解锁任务**（[AppDelegate.swift:551-553](FUnlock/AppDelegate.swift:551) + :396-406）：screensDidWake 双订阅按注册顺序先 onDisplayWake（调度 0.3s 任务）后 onUserIntervention（取消之）→ 唤醒路径的自动解锁被自己杀死，须等下一轮采样补偿。「用户干预」与「程序自唤醒」被混淆。
- **无认证分布式通知可伪造触发钥匙串密码删除**（[AppDelegate.swift:574-578](FUnlock/AppDelegate.swift:574)）：任意本地进程可广播 `com.apple.security.loginwindow.passwordChanged` → 删除密码 + 弹窗（DoS + 社工面）。

### 3.2 信号算法（数学与配参）

- **Kalman 负向 delta 不加速 Q**（[SignalPipeline.swift:149-159](FUnlock/SignalPipeline.swift:149)）：稳态增益 K≈0.119，3 dB/s 走远时估计滞后约 50dB——BLE 不断连则阈值判定永不触发，只能等断连后的衰减路径（又叠加 P0-1）。
- **EWLR 窗口 1.5s 与采样档 0.5/2/8s 失配**（[SignalPipeline.swift:40,118-142](FUnlock/SignalPipeline.swift:40)）：2s/8s 档窗口内仅 1 样本 → 斜率恒 0 →「快速下降 2.5s 锁屏」与「斜率自适应超时」整体失效（**实测**：运行日志确认 8s 采样档在场常态）。
- **IQR 异常检测从不生效**（[SignalPipeline.swift:108-116](FUnlock/SignalPipeline.swift:108)）：要求窗口 ≥5 样本，1.5s 窗口在 0.5s 档最多 4 个 → 门限永不满足；且异常样本仍全权重进入滤波。
- **RSSI=127 哨兵映射为 0 dBm**（[BLEScanner.swift:212](FUnlock/BLEScanner.swift:212), [BLEPeripheralHandler.swift:166](FUnlock/BLEPeripheralHandler.swift:166)）：0 dBm 尖峰可把估计上拉约 13dB 瞬间越过解锁阈值——**已验证**，屏幕锁定时可触发一次真实注入尝试。
- **Q 不随 dt 缩放**（[SignalPipeline.swift:43,161-164](FUnlock/SignalPipeline.swift:43)）：0.5/2/8s 三档等效过程噪声差 16 倍，8s 档对真实移动「失聪」。
- **衰减惩罚不分方向**（[SignalPipeline.swift:91-96](FUnlock/SignalPipeline.swift:91)）：快速接近（slope>2）同样放大惩罚 → 解锁感知延迟 +33%。
- **惩罚与采样间隔耦合**（[SignalPipeline.swift:94-97](FUnlock/SignalPipeline.swift:94)）：同一物理信号因轮询档位不同 static 偏移差最多 2.6dB，档位切换瞬间 effectiveRSSI 跳变 → 阈值边缘抖动。
- **setUnlockRSSI 联动在下限制造 lock>unlock 反向迟滞**（[FUnManager.swift:131-133](FUnlock/FUnManager.swift:131)）：DiagnosticsView 允许 unlock=-100，联动 `max(-110,-95)=-95` → close 与 away 区间重叠 → **循环锁屏**。lock 滑块同样无 lock<unlock 约束可手动提交重叠区间。
- **WiFiMonitor 授权判定不匹配 + SSID nil 失败开放**（[WiFiMonitor.swift:34-43](FUnlock/WiFiMonitor.swift:34)）：请求 WhenInUse 却只认 authorizedAlways → 授权流程死循环；权限被收回后 SSID=nil 被当作「不匹配」放行 → Wi-Fi 暂停静默失效（macOS 27 下权限收回不弹窗，风险放大）。

### 3.3 并发与运行时

- **双保险验证「竞速」不竞速**（[SystemInteractionService.swift:395-431,462-481](FUnlock/SystemInteractionService.swift:395)）：轮询循环 `try? await Task.sleep` 吞掉 CancellationError 且不查 Task.isCancelled → 快路径 200ms 确认后仍等满 2s → 媒体恢复/遥测/状态机成功处理整体延迟约 1.8s。
- **Timer invalidate 线程契约破损**（[BLEPeripheralHandler.swift:52-59,68-86](FUnlock/BLEPeripheralHandler.swift:52) 等）：bleQueue 创建 + main 注册 + bleQueue invalidate；invalidate 与 fire 并发时 block 仍可能再跑一次——60s 边界 connectionTimer 可能误 cancel 刚建立的连接。
- **每采样重建 60s signalTimer**（[FUnLockCoordinator.swift:44-73](FUnlock/FUnLockCoordinator.swift:44)）：2Hz 快轮询下每秒 2 次 Timer alloc + RunLoop 注册，且与主线程 invalidateAllTimers 存在双线程重建竞态（解绑后 timer 复活）。
- **主线程同步阻塞**（[SystemInteractionService.swift:309,250,101](FUnlock/SystemInteractionService.swift:309)）：注入路径 Thread.sleep(0.3) + AppleScript 同步执行 + wakeDisplay 内 sleep → 主线程冻结数百 ms。
- **接近期主线程风暴**：每样本派发 1-2 个 Task{@MainActor} + 每采样 `updateStatusBarIcon` 的 lockFocus 位图重染（[AppDelegate.swift:232-237](FUnlock/AppDelegate.swift:232)）+ 每 0.5s cancel/重建 unlockTask + pauseOnWiFi 时每轮门控同步调 CoreWLAN XPC。
- **InputActivityMonitor 鼠标从未被匹配**（[AppDelegate.swift:40-48](FUnlock/AppDelegate.swift:40)）：匹配表只有键盘(0x01/0x06)与触控板(0x0D/0x04)，鼠标(0x01/0x02)不在 → `isMousePress` 死代码 → **纯鼠标用户被判定「无输入」，lockOnIdle 下打字/浏览中被自动锁屏**；触控板 device 匹配 0x04 与事件过滤 0x09 亦不一致。

### 3.4 状态机与解锁流水线

- **degraded 唯一可靠恢复路径是通知点击**（[FUnlockStateMachine.swift:99-102](FUnlock/FUnlockStateMachine.swift:99), [FUnManager+Events.swift:55-59](FUnlock/FUnManager+Events.swift:55)）：用户干预 `resetToActive(clearFailures: false)` 保留 failures=3 → 下次 attemptUnlock 再次降级；通知被拒/勿扰吞掉时自动解锁永久停摆直到重启 app；且此路径降级不发通知（无提示）。
- **cooldown→unlocking 转移缺失**（[FUnlockStateMachine.swift:64-81](FUnlock/FUnlockStateMachine.swift:64)）：attemptUnlock 返回 true 但 transition 静默失败 → 状态停留 cooldown，状态显示与实际动作脱节。
- **guardFetchPassword 失败后状态卡 .unlocking 无回落**（[UnlockOrchestrator.swift:110-133](FUnlock/UnlockOrchestrator.swift:110)）。
- **乐观更新 unlockedAt/lastUnlockTime 无回滚**（[UnlockOrchestrator.swift:143-144](FUnlock/UnlockOrchestrator.swift:143)）：注入失败也触发 3s 防抖 + 5s 冷却，且 recentlyUnlocked 门控基于未发生的解锁。
- **AppleScript 单引号转义导致 L3 兜底必失败**（[SystemInteractionService.swift:234](FUnlock/SystemInteractionService.swift:234)）：**实测**（本机 NSAppleScript）：`"pass\'word"` 编译报 "Expected “"” but found unknown token"——含单引号密码在 CGEvent 两级失败时 100% 解锁失败；而 L3 存在的意义恰是 CGEvent 失败的兜底。修复即删掉该行（单引号无需转义，已实测验证）。
- **degraded 通知点击即恢复无二次确认**（[AppDelegate.swift:276-280](FUnlock/AppDelegate.swift:276)）。

### 3.5 配置与类型

- **配置键 23 个散落 11 文件 + bool 键缺失双语义**（[ConfigStore.swift:151-163](FUnlock/ConfigStore.swift:151)）：`enabled`/`lockOnIdle` 已踩「UI 默认 true、后端裸读 false」的坑，其余键随时可能重蹈。
- **测试直接污染生产数据**：iMessageNotifierTests tearDown 删真实生产 suite 键；LegacyCompatibilityTests 截断真实 `~/Library/Application Support/FUnlock/events.log`。
- **阈值钳制 4 处重复且不一致**（[FUnManager.swift:132](FUnlock/FUnManager.swift:132) 引用 `OverviewView.RSSIRange.min`——模型层倒挂视图层；CalibrationWizard -95/-30、DiagnosticsView -95/-100 字面量各自为政）。
- **配置导入缺合理性校验**（[ConfigStore.swift:118-126](FUnlock/ConfigStore.swift:118), [ProfileManager.swift:90-111](FUnlock/ProfileManager.swift:90)）：恶意配置可删 suite 任意 key、把解锁阈值设到 -100 极松值放大中继攻击距离。

### 3.6 测试隔离与权限声明（Sonnet UI 补充轮新发现）

- **测试会删除用户真实 Keychain 密码**（[FUnlockTests/FUnlockTests.swift:2728-2756](FUnlockTests/FUnlockTests.swift:2728)）：KeychainSecurityTests 用真实 SecurityService（生产 service 名）写后无条件 `deletePassword()` 连删两次——开发机跑一次测试即可能删掉用户真实解锁密码。应注入测试专用 service 名。
- **测试触发生产副作用**（[FUnlockTests/FUnlockTests.swift:1019-1036](FUnlockTests/FUnlockTests.swift:1019)）：真实 FUnManager 的 `onUnlock()` 内 2s 延迟任务会执行用户的 intruded 自定义脚本、写生产 events.log、发真实网络请求。需注入 noop scriptRunner/updateChecker。
- **测试→生产越界补点**：构造真实 FUnManager 未注入 decisionLogger → 写生产 decisions.jsonl；向生产 suite 写 wakeAdvance/enabled 等键无 tearDown 清理（好的一面：ConfigStoreTests/LogRotationTests/DecisionLoggerTests 隔离模式完善，照抄即可）。
- **缺 `NSAppleEventsUsageDescription`**（[Info.plist](FUnlock/Info.plist)）：hardened runtime 下向 Messages/System Settings 发 Apple Events 不弹 TCC 授权窗——新装用户 iMessage 通知静默失败、「打开系统设置」按钮无效。一行修复。

## 4. P2 — 改进建议（紧凑清单）

- **运行实测**：CPU ≈15%（累计 115min CPU/17.9h 运行 ≈10.7% 单核，对状态栏 app 偏高，主分布在 SwiftUI 渲染/日志 IO/Timer churn）；内存 RSS 21MB（优秀）；日志目录 16MB 有界（5MB 轮转 ×2 代，decisions.jsonl 1MB 上限）但 **heartbeat 每 3s 一条 lockLog 无节流**是 debug.log 5MB 主因。
- **BLE 中继攻击是设计边界**：解锁门控仅依赖广播 RSSI 派生的 presence，不要求活跃 GATT 连接或挑战-应答；中继真实信号即可远程解锁（记录为边界风险，修复需产品决策）。
- **分发**：实测 FUnlock.zip 内 app 为 `Apple Development` 开发证书、无公证（notarytool 零调用）、zip 无 SHA256、Bundle ID 硬编码 `com.fuhahah.FUnlock`；用户被迫习惯绕过 Gatekeeper。
- **Keychain**：未设 kSecUseDataProtectionKeychain（login keychain 同用户任意进程可读）；密码 Swift String 常驻内存不可擦除。
- **通知**：未知 identifier 的通知点击一律打开外部 GitHub URL（[AppDelegate.swift:281-283](FUnlock/AppDelegate.swift:281)），建议白名单外 no-op。
- **死代码**：`LockScreenState.canAutoUnlock` 无调用点且与并行唤醒语义矛盾；状态机 preWaking/readyToUnlock 无生产进入路径；StatsView macOS13 分支（部署目标已 14.0）。
- **heartbeat 哨兵缺陷**（[FUnLockCoordinator.swift:116-123](FUnLockCoordinator.swift:116)）：lockRSSI=-100 时 3s 档永不出现；禁锁后心跳仍 2s 空转。
- **thresholdRSSI=-90 与 unlock=-100 矛盾**：设备列表过滤掉 RSSI<-90 的合法设备，绑定入口与阈值语义打架；unlock=-100 时 preWake 外推 -120 使唤醒失去「接近才唤醒」语义。
- **图表失真**：参考线 unlockThreshold/lockThreshold 从未被赋值（恒 -60/-80）；锁/解合成事件样本直插 -100 假深谷；unlockRSSI=1 时 presence 仍翻转记假 unlocked 事件。
- **pre-wake 三重污染**：同一 smoothedRSSIValue 被原始值与 displayRSSI 截断值交替驱动，`Int()` 截断偏 +1dB；alpha=0.3 + init -100 使 2s 采样下滞后约 18s；**校准向导采样源（displayRSSI 链，绑定后 ~62s 才收敛）与判定源（effectiveRSSI）不同源 → 校准均值系统性偏高 10-20dB，建议阈值严重失真**。
- **RingBuffer 容量 300**：0.5s 快轮询仅覆盖 2.5 分钟，图表时间跨度随档位漂移 8 倍。
- **心跳自停依赖「属性等值」不变量**（[FUnLockCoordinator.swift:126-135](FUnLockCoordinator.swift:126)）：用 `self.heartbeatTimer?.invalidate()` 自停，任何新创建点即产出僵尸心跳；resetSignalTimer 的 `timer.invalidate()` 写法才是对的。
- **Combine sink 无 `.receive(on: .main)`**（[AppDelegate.swift:548-578](FUnlock/AppDelegate.swift:548)）：8 个 sink 直接调 @MainActor 方法，契约无保护。
- **锁纪律毛边**：scanMode/currentScanAllowDuplicates/阈值字段写侧不持锁（与 @unchecked Sendable 注释契约矛盾）；`recordUnlockAttempt` 用 Date() 而非注入时间源；verify Task 未挂入 unlockTask（cancelPendingTasks 取消不了在途验证）；ConfigStore 导出 `"\(value)"` 字符串化 + import "true"/"false" Bool 优先匹配；onSystemSleep 的 setActivationPolicy(.regular) hack；resetScanTimer 每发现重建 Timer。
- **UI 层业务逻辑下沉**：校准向导 `max(unlock, lock + 5)` 硬编码迟滞 5，与全局规范 `lockUnlockDelayGap = 10` 不一致——向导写出的配置违反迟滞约束且随后被 setUnlockRSSI 联动覆盖（[CalibrationWizardView.swift:354-361](FUnlock/CalibrationWizardView.swift:354)）；DiagnosticsView 的 ActionHint 阈值调整是第三套策略；ConfigSettingsView 导入依赖「先 setUnlockRSSI 再覆盖 lock」的调用顺序注释。
- **渲染性能**：SignalDataStore `Timer.publish(every:1s)` 全生命周期每秒锁内全量 toArray（无图表 UI 也在跑）；OverviewView body 每 BLE 广播（1-4Hz）重算整个 Form；StatsView 图表每秒重建 300 样本 ×4 ForEach；MainWindowView 5s 定时 AXIsProcessTrusted 查询常驻。
- **可访问性**：MenuBarPopover 自绘 Capsule 开关无 `.accessibilityAddTraits(.isToggle)`；信号环/柱无 RSSI 数值的 accessibilityLabel；toast 用 `asyncAfter 3s` 清空，连续两个 toast 时第一个定时器会提前清掉第二个。
- **Info.plist**：`NSInputMonitoringUsageDescription` 声明了但代码未用 InputMonitoring 框架（实际需要的是辅助功能权限），冗余误导；版本号双轨（Info.plist 硬编码 + pbxproj MARKETING_VERSION 空，自增脚本改写 git 跟踪文件导致频繁「自增版本号」提交）。
- **构建**：login.framework 悬空引用（不在 Link phase、代码零引用）；MediaRemote.framework 的假相对路径（靠 search path 兜底）；exportDiagnostics 在主线程 `waitUntilExit()` 打包 zip（日志大时 UI 冻结）；Release 瘦身现状良好（-O + dSYM，xcassets 仅 1.2MB），无需额外 strip。
- **测试杂项**：冷却过期测试真实等待 5.1s（同文件已有时间源注入示范）；`updatePresence(presence:true)` 与 `onDeviceApproached()` 双包装调同一方法，其一为死代码。
- **i18n**：2 处硬编码中文绕过 8 语言（CalibrationWizardView.swift:350、ProfileManager.swift:11）。
- **类型**：SignalSample.event 字符串魔法值；ScreenState 以 description 展示字符串持久化再反向解析；RSSI→颜色 3 套标准并存；DeviceSnapshot.init 死参数 id / Device.uuid IUO；LEDeviceInfo 全局可变状态无锁（connect 可双开 SQLite）。
- **日志**：路径清单硬编码 4 文件 + DiagnosticsView 导出再复制一份；DecisionLogger.write 全部 try? 静默吞错。
- **UI**：updateStatusBarIcon 每采样重绘位图（与 P1 主线程风暴同源）；CalibrationWizard Int 步进魔法数字 + 两采样小节复制粘贴；@ObservationIgnored 标注不足（依赖与内部簿记也在观察跟踪）。
- **构建**：README 宣称 macOS 13.0+、实际部署目标 14.0；exportAllSettings/importAllSettings 完全无测试。

## 5. 架构层面总评

**分层**（UI → 协调 @MainActor → 核心 BLE/信号 → 系统交互）边界清晰，且持续在改善：跨线程边界全部走不可变值快照（DeviceSnapshot/SignalSnapshot），`Task { @MainActor [weak self] }` 是统一派发模式，FUn 是唯一 @unchecked Sendable 且带详尽线程契约注释，SignalHysteresisEngine 纯逻辑引擎可单测。**类型体系**以枚举为主（ScreenState/LockIntent/DecisionReason），质量高于同规模项目。

**三个结构性弱点**：① 配置系统双轨——ConfigStore 门面空转、23 个散落键、bool 双语义，任何配置改动依赖人工全局一致性；② 测试与生产之间没有隔离墙（直接操作生产 suite 与真实日志文件）；③ 横切关注点无「单一来源」——阈值钳制 4 处、RSSI 分类 3 套、日志路径 4 文件、四条 RSSI 信号链（raw/Kalman/effective/display/smoothed）各自为政且校准/pre-wake/图表消费的链路与判定链路不同源。

## 6. 亮点（值得保留）

- **注入纵深防御**是同类工具少见的：frontmost=loginwindow 双重校验 + 每 20 字符批间与回车前复查 isSecureToInject；进程内 NSAppleScript（避免 osascript 把密码暴露给 ps）；三级降级注入。
- **Keychain 冷启动处理正确**（errSecInteractionNotAllowed）+ kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly。
- **速率控制链完整**：5s 防抖 + 10s 失败冷却 + 3 次失败降级 + 5 分钟滑动窗口异常告警；onUserIntervention 特意 clearFailures:false 防绕过。
- **cleanup() 延迟 invalidate** 正确规避了 __CFRunLoopDeallocateTimers 历史崩溃（BUGS.md #1）。
- **内存有界且实测极低**：ring 300/500、日志 5MB 轮转、RSS 仅 21MB。
- **测试质量好**：时间源注入、行为级测试、LogRotator 四套共用且有失败降级测试。

## 7. 修复优先级路线图

**R1（安全/正确性，本周）**：P0-1 衰减与阈值联动（cap = max(20, eff_last − lockThreshold + 6) 或向阈值逼近）→ P0-2 wakeWithoutUnlocking 补并行分支检查 → P0-6 lockTimeout 插值公式 → AppleScript 转义删除单引号行（一行修复，已实测）→ NSAppleEventsUsageDescription 补声明（一行修复）→ degraded 恢复加 UI 入口 → P0-7 monitoredUUIDs 锁内快照。

**R2（安全，2 周内）**：更新链整体加固（安装前确认 + SHA256 清单 + FileManager.temporaryDirectory 私有目录 + 签名校验移到 staging 后 + Developer ID 公证）→ 锁屏意图识别收敛（onScreensaverStart 设 intent、isSelfLocking 超时复位、锁屏后回读 CGSession 验证）→ 状态机转移表修复（cooldown→unlocking、失败回落 active、canAttemptUnlock 内聚到 attemptUnlock）→ verifyUnlock 循环尊重取消。

**R3（算法/并发收口）**：信号链重配（EWLR 窗口 ≥2×最大采样间隔、负向 Q 加速、Q×dt、衰减只罚下降方向、衰减独立于采样间隔）→ setUnlockRSSI 联动保证 lock < unlock → Timer 家族统一线程契约（invalidate 派回主线程或换 DispatchSourceTimer）→ Device 字段锁内变更 → 每采样 Timer 重建改事件驱动。

**R4（体验/工程）**：能耗收敛（updateStatusBarIcon 缓存、updateRSSI 节流、SSID 缓存 5-10s、heartbeat 日志降频）→ 配置键收敛 enum + 强制门面 → **测试夹具工厂（Keychain 测试 service 隔离、noop scriptRunner、独立 suite——测试删真实密码是最高优先）** → 阈值钳制/颜色分类/日志路径单一来源 → 输入监视器补鼠标匹配 → 校准向导改采 effectiveRSSI 并统一迟滞常量 → 图表参考线赋值 → 版本号脚本补 input/output 声明。

---

*子审计来源：Fable 轮（并发/算法/安全/UI）× Sonnet 补充轮（并发/算法/安全/UI）× 主审计者独立验证与运行实测（进程采样、日志增长、AppleScript 行为、插值公式重算、断连路径复核）。全部子报告见 /tmp/funlock-audit-*.md。*
