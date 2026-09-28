# FUnlock 审计修复总报告(2026-09-27 ~ 2026-09-28)

> 执行方式:总指挥调度 + 并行子智能体分队。审计依据:[2026-09-27-audit-report.md](2026-09-27-audit-report.md)。
> 回滚点:`/tmp/funlock-snapshot-pre-phase3.tar.gz`(Phase 1+2 完成后)、`/tmp/funlock-snapshot-post-phase3w1.tar.gz`、`/tmp/funlock-snapshot-post-phase3.tar.gz`。

## Phase 1 — P0 根除与数据安全(5 项,全部完成)

| # | 缺陷 | 修复 | 关键位置 |
|---|---|---|---|
| P0-1 | 单测覆盖并删除真实 Keychain 密码(`SecurityService.shared`) | 测试全部迁移至独立实例 `com.fuhahah.FUnlock.test.isolated` | FUnlockTests(拆分后 KeychainSecurityTests.swift 等) |
| P0-2 | 测试写删生产配置域 `profiles`/`activeProfileID` | `ConfigKeySnapshot` 写前快照 + tearDown 100% 还原 | FUnlockTests/TestSupport.swift |
| P0-3 | 手动唤醒自动解锁 100% 自杀(先调度后取消) | 顺序交换:先 `onUserIntervention()` 再 `attemptAutoUnlock()`,补回归测试 | FUnManager+Events.swift:44-50 |
| P0-4 | `canAttemptUnlock` 漏排 `.unlocking`,快轮询重入掐死在途验证→误判降级 | 门控补 `currentState != .unlocking`,补回归测试 | FUnlockStateMachine.swift:50-56 |
| P0-5 | `monitoredUUID`/`devices` 跨线程裸读写(UB) | computed accessor 锁化 + 锁内上下文改直访裸存储(消除重入死锁) | FUn.swift:86-107、FUnSignalProcessor.swift |

**验收**:394/394 用例通过;`com.fuhahah.Funlock.config` 与生产 Keychain 条目测试前后 diff 严格为零。
**事故披露**:P0-1 的破坏性用例在基线测试运行时已实际触发,Debug 版(`com.fuhahah.FUnlock-dev`)Keychain 条目被删除;正式版条目(`com.fuhahah.FUnlock`)始终完好。生产配置域 `profiles` 键同样已不存在——若曾有自定义配置档需要重录。

## Phase 2 — P1 并发与业务收口(5 项,全部完成)

| # | 缺陷 | 修复 | 关键位置 |
|---|---|---|---|
| P1-1 | 改密通知逻辑颠倒:未锁屏 100% 忽略;锁屏时 `runModal` 挂起主线程 | 三层防护重构:无密码早退;锁屏只标 `hasPendingPasswordChange` 延迟到 `onUnlock` 消费;未锁屏走确认窗。测试钩子 `confirmHandler`/`reEntryHandler`/`sessionLockProvider` 注入 | SecurityService.swift:112-170、FUnManager+Events.swift |
| P1-2 | 合法自动解锁被误判入侵(`isAutoUnlocking` 先于慢速通知复位) | `isAutoUnlockingOrRecentlyCompleted`(4s 完成窗口,基于注入 nowProvider),onUnlock 两处读点同步修正 | UnlockOrchestrator.swift:29-42 |
| P1-3 | 锁屏 Timer TOCTOU + 孤立僵尸 Timer | 锁内原子取出旧 timer 并派发主线程 invalidate;fire 块头部 `proximityTimer === timer` 身份守卫 | FUnLockCoordinator.swift:323-383 |
| P1-4 | 注入路径主线程 `Thread.sleep` 冻结 ~500ms | `wakeDisplay`/`injectPasswordWithPrelude`/`tryUnlock`/`performInjectionAndVerify` 全链 async 化,`Task.sleep` 挂起不占线程;display-off 唤醒上移至唯一调用方 | SystemInteractionService.swift、UnlockOrchestrator.swift(+AutoUnlock) |
| P1-5 | `os_unfair_lock` 临界区内 SQLite 磁盘 I/O + 嵌套锁 | `getLEDeviceInfoFromUUID` 移至进锁前预查(入参为局部变量无竞态),锁内仅剩内存赋值 | BLEScanner.swift:268 |

**验收**:394/394 通过;数据安全 diff 为零。

## Phase 3 — 测试体系重建(完成)

### Wave 1:巨型文件拆分 + 假测试清除(fix-split-tests)
- `FUnlockTests.swift`(3984 行/36 类)拆为 9 个主题文件 + `TestSupport.swift`,全部登记 pbxproj(独一 UUID 前缀 SW000001/SW000002)
- 删除 28 个假测试并精确对账:394 − 28 = 366,xcodebuild 实跑 366 全绿:
  - InjectionPreludeTests 整类(7,零调用被测代码)
  - UnlockAttemptWindowTests 整类(6,重抄算法自测)
  - StateTransitionSequenceTests 整类(8,赋值再断言)+ UnlockedAtTests 3 例
  - KeychainSecurityTests 恒真 2 例、LegacyCompatibilityTests 恒真 1 例、DiagnosticsViewTests 同义反复 1 例、空 extension
- 拆分后最大单文件 744 行,数据安全 diff 为零

### Wave 2:覆盖缺口补齐 + 脆弱加固(4 分队并行,+77 用例)

| 分队 | 交付 | 用例 |
|---|---|---|
| 更新链(重派×1,API 故障中断 2 次后续跑) | UpdateDownloader/UpdateInstaller/UpdateChecker:bundleId 防换装矩阵、临时目录唯一性、semver 数值比较、安装脚本原子性结构断言;主源码最小可测性提炼(纯函数 static 化,行为不变) | +23 |
| 核心逻辑 | SignalHysteresisEngine 行为矩阵(迟滞带/边界含闭开语义/哨兵回退/钳制/lockTimeout 单调连续)、Keychain 完整往返(UTF-8/覆盖/幂等删/accessible)、状态机失败预算→degraded、降级通知实发(UNUserNotificationCenter 验证) | +26 |
| 脆弱加固 | 4 处 0.5s 硬等→expectation 驱动;30s 防抖注入 nowProvider(源码 +1 属性)并补 29s/30s 边界用例;StatsCalculator 固定时区时钟;CSV 列下标→表头名定位;PowerState 1s 硬等注入 `systemWakeDelay`(默认行为逐位不变) | +1,改 5 文件 |
| 门控与序列 | attemptAutoUnlock SKIP 矩阵 15 例(含 stateMachineBlocked 两种状态/休眠双出口/静默早退)、乱序序列 4 例、阈值漂移端到端 1 例、ConfigStore Data/全量 31 key 往返 5 例 | +25 |

**Wave 2 过程事件**:上游 API 间歇性故障(400 captcha verify failed)致 2 个 Sonnet agent 中断,均换 Opus 重派或断点续跑,无工作丢失。

### 测试体系现状
- 用例数:366 → **418+**(拆分删除 28、四分队新增 77、含 skip)
- 四大零覆盖区清除 3 个:更新链 ✅、迟滞核心 ✅、Keychain 往返 ✅(BLEScanner 仍无,见遗留)
- 假测试清零;硬等待清零(全部 expectation/状态信号驱动)

## Phase 4 — P2 工程债清理(18 项,全部完成;fix-p2-polish)

**A. 机械项**:冷却常量单源(`FUnlockStateMachine.unlockCooldownDuration` static 单源)、`markManualLock()` 收敛三处 + `manualLockIntentDuration` 常量化、`as!` 消除(CF 桥接用 `CFGetTypeID` 运行时校验 + unsafeDowncast)、哨兵写法统一(纯逻辑层保留 `SignalHysteresisEngine.*` 避免引入 CoreBluetooth 依赖——对任务书的证据修正)、Info.plist 冗余权限删除、`login.framework` 悬空引用删除(**MediaRemote.framework 经构建证据保留**——审计"假路径"判断有误,它是真实私有框架链接依赖)、休眠激活策略注释、诊断日志路径单源(`eventsLogURL` 等)。

**B. 行为安全项**:通知点击白名单(未知 identifier 只记日志 no-op,不再拉起浏览器)、状态机死状态 `.preWaking`/`.readyToUnlock` 删除(生产零触发,grep 证实;连带转移表与 4 个测试用例清理)、FUnDelegate 双包装合并(首靠双派发根因消除,解锁入口唯一化)、TeamId 空值返回 nil(消除双空假匹配)、ConfigStore base64 损坏告警(保持幂等)、View 写越层收敛(`FUnManager.setPassiveMode` 门面)。

**C. UI 项**:StatsView 图表降采样(≤120 点,异常点/事件标记保持全量)、权限轮询仅权限缺失时启动、信号盘 accessibility 标签(本地化 RSSI + 场景文案)。

**D. 文档**:architecture.md 全面更新(§2 组件图补 10 组件、§3 补约 20 文件、§5 API 归属修正、§6 测试组织)。

**清单外说明**(已审阅同意):`OrchestratorGatesTests` 2 例加会话锁定环境守卫(宿主 GUI 真实锁定时"屏幕已解锁"分支不可达,与既有 XCTSkip 先例一致)。

### 最终验收(总指挥独立复核)

- 全量测试:**438 用例,0 失败,3 skip**(1 通知授权依赖 + 2 会话锁定守卫),耗时 23.6s
- 数据安全:`com.fuhahah.Funlock.config` 与生产 Keychain 条目测试前后 **diff 严格为零**
- 构建:Debug 零新增警告;Release **BUILD SUCCEEDED**,产物 v2.8.37 (1514) 暂存 `/tmp/FUnlock-nightly.app`
- 全程未执行 git commit(提交权留予用户)

## Phase 6 — 预唤醒 EMA 时间归一化(用户批准,fix-ema-timenormalized)

原审计 P2「smoothedRSSI 双驱动」深挖后定性为**非时间归一化问题**(解锁链不受影响,只影响预唤醒)。重构为:

- `α = 1 - exp(-dt/τ)`,τ=1.0s(`FUn.preWakeEMATau`),响应速度与采样率/驱动次数无关
- **首样本初始化**:reset 后首个采样直接赋值,不再从 -100 爬坡(被动 8s 模式预唤醒从 ~20s 迟到降到即采即达)
- **单驱动化**:唯一驱动点 `processSignal`;`onRSSIUpdated` 改读自锁访问器 `currentSmoothedRSSI`
- 总指挥审核修正:子智能体把原 `if let rssi` 守卫整个删除,导致失联派发(nil)会用冻结 EMA 误唤醒无人在场的屏幕——加回 `rssi != nil` 守卫恢复原语义(FUnManager+Events.swift:284)
- 测试:`SmoothedRSSITests` 重写为时间参数化(含**频率无关性**性质证明:3s 总时长分 6 步与 1 步结果相等),`PreWakeStaircaseTests` 适配单驱动语义,断言无削弱
- 验收:440/440 通过(1 skip),生产配置与 Keychain 零触碰,grep 证实唯一驱动点

## 审计新 finding(Phase 3 期间发现)

1. **ConfigStore base64 损坏静默降级**(真缺陷):导入时 `_b64:` 解码失败原样落盘为 String,`profiles` 语义丢失且无告警 → Phase 4 修复
2. **TeamId 空值泄漏标签**(防御加固):`parseTeamId("TeamIdentifier=")` 返回标签本身,双空比较可假匹配(上游 codesign --strict 双防线兜底,非直接绕过)→ Phase 4 修复
3. **ConfigStore 导出值字符串化丢类型**:Double→String、数字字符串→Int(功能基本无损,`object(forKey:) as?` 精确转型分支受影响)→ 表征测试已锚定,暂不修

## 遗留事项(需产品/用户决策,未擅动)

| 项 | 原因 |
|---|---|
| kSecUseDataProtectionKeychain | 存量密码迁移地雷,直接开启会导致旧条目不可读 |
| SHA256 更新清单校验 | 需先定服务端清单格式 |
| BLE 中继攻击边界 | 产品设计决策(纯 RSSI 判定,无挑战应答) |
| RSSI 颜色双标准统一(-50/-70 vs -60/-75) | 需定哪个标准 |
| BLEScanner 单测(335 行零覆盖) | 需 CBCentralManager 协议抽象,架构改动 |
| NSAlert 收敛(11 处)/ ConfigKey 枚举化(23 key×11 文件)/ 图表假深谷渲染 | 重构规模或视觉行为变化,单独决策(~~smoothedRSSI 双驱动~~ 已于 Phase 6 修复) |
| WiFi 暂停正路径测试 | `WiFiMonitor.currentSSID` 无注入点,需源码加 seam |
| coldBoot 拒绝路径测试 | 需锁定整个用户钥匙串才能复现,不可接受副作用 |

## 交付物清单

- [x] [2026-09-27-audit-report.md](2026-09-27-audit-report.md) — 审计总报告(四组合并)
- [x] [real-device-checklist.md](real-device-checklist.md) — 真机验证清单(Phase 5,待用户执行)
- [x] 本报告 — 修复总报告
- [x] Release 构建(见文末路径)
- [ ] git commit(留待用户确认后执行,建议按 Phase 分 4 个 commit)
