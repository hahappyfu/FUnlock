# FUnlock 日志复盘报告(2026-09-30)

> 任务:按[日志驱动迭代规则](../dev-rules/log-driven-iteration.md),用真实运行日志评估 2026-09-28 第二轮审计修复(P0×5、P1×5、Phase 6 EMA 重构)的实际表现。
> 运行版本:**v2.8.37 (build 1522)**,安装于 2026-09-28 14:43,进程自 09-29 09:22 运行中。
> Keychain 生产条目 `com.fuhahah.FUnlock`:**存在** ✅(自动解锁凭据就绪)。
> 数据来源:`~/Library/Logs/FUnlock/` 的 decisions.jsonl、debug.log(.old)、timing.log、shadow_telemetry.csv。

## 结论(先行)

**样本量不足(有效窗口 ~1.8 天 < 3 天),仅初步观察,不进入优化决策。**

初步观察:四项重点修复中 **P0-3、P1-2、P0-4 初步判定生效**,**预唤醒(Phase 6)整个窗口 0 次触发、功能近乎不可达,判存疑**。发现 1 个 P1 级新异常(显示器熄灭场景首次注入不稳定)与 2 个低优先级观察项。建议按本文 §4 继续积累样本,下轮复盘时复核。

窗口说明:decisions.jsonl 覆盖 09-29 11:48 → 09-30 10:03(用户按真机清单记录日志位点后);09-28 14:43(装机)→ 09-29 11:48 的事件从 debug.log.old / timing.log / shadow_telemetry.csv 补全。09-28 14:43 之前的日志为旧构建,已剔除。

## 1. 样本量表(09-28 14:43 → 09-30 10:03,约 43 小时)

| 事件类型 | 次数 | 说明 |
|---|---|---|
| 自动解锁成功 | **8** | 09-28 ×2(16:05、16:33)、09-29 ×6(12:13、12:22、13:08、14:05、16:05、17:29) |
| 解锁失败(首次注入验证失败) | **2** | 均为"第 1/3 次尝试",且都在 ~13s 后重试成功(09-29 14:05、16:05) |
| 自动锁屏(lockedAway) | **10** | 09-28 ×1 + decisions 内 9 条;全部单次触发,无重复锁屏(A5 ✓) |
| 手动锁屏(userLocked) | 4 | 09-29 17:32、23:36;09-30 02:05、07:09 |
| 手动输密码解锁(userUnlocked) | 6 | 09-29 17:31、21:42、23:38;09-30 00:41、06:55、08:19(原因见 §3-E) |
| **pre-wake 触发** | **0** | wakeOnProximity 全程开启,`[SM] pre-wake triggered` 零次(09-26 起全部日志) |
| **入侵告警(intruded)** | **0** | 09-26 起全部日志零条 |
| **degraded 降级** | **0** | 零条 |
| stateMachineBlocked 跳过 | 4 | 全部围绕两次在途解锁的门控拦截(P0-4 预期行为) |
| unlockCooldownActive 跳过 | 11 | 正常冷却(3.8s/4.3s/1.6s/4.8s 等) |
| wifiPaused 跳过 | 1335 | 家庭 WiFi 'Xiaomi_DB79_5G' 暂停解锁(解锁评估 1370 条中占 97%) |
| noPresence / signalBelowThreshold / manualLockActive 跳过 | 4 / 6 / 10 | 均为门控正常拦截 |
| 系统睡眠/唤醒 | 2 / 2 | 夜间合盖,唤醒后扫描恢复无异常 |
| 显示器睡眠/唤醒 | 4 / 4 | — |
| ERROR 级日志 / lock verify 回滚 | 0 / 0 | — |

样本偏移说明:用户大部分时间在家庭 WiFi 下,解锁被按设计暂停,样本偏向"离开 WiFi/外出返回"场景;解锁事件 10 次(8 成功 + 2 失败),天数 1.8 天,**未达"3 天"门槛**。

## 2. 四项重点修复的真实表现判定

### ① P0-3 手动唤醒自动解锁 —— **生效(初步)**

修复前此路径 100% 自杀(先调度后取消);现观察到完整解锁链在手动点亮屏幕后 0.3~0.4s 内启动:

```
[09-29 14:04:58.503] [LOCK] onDeviceApproached screen=locked(manual) eff=-61.1 ...
[09-29 14:04:58.864] tryUnlock() START - screen=locked(manual), locked=true      ← 0.36s 启动
[09-29 14:04:58.886] calling injectPasswordWithPrelude
[09-29 14:05:12.838] tryUnlock() START(重试)→ 14:05:14 unlockSuccess
```

同型证据:09-28 16:05:18、09-29 16:05:35、17:29:40 均为 `screen=locked(manual)` 下 tryUnlock 全链执行并最终 `dual verify passed, counter reset`。注:清单 A3 期望的 `unlockTask STARTED→WOKE` 日志串在 build 1522 中不存在(0 命中),功能等效证据以 `tryUnlock() START` 链为准。

### ② P1-2 合法解锁不误报入侵 —— **生效(初步)**

09-28 起 8 次自动解锁成功后均**无** intruded 记录(全日志 0 条)。6 次手动输密码解锁均发生在设备在场(rssi -50~-62)或 WiFi 暂停场景,不触发入侵符合预期。
未能判定项:B2(设备不在场时手动解锁仍报入侵)在本窗口无对应场景,语义是否保留无法从本期日志证实。

### ③ P0-5 / Phase 6 预唤醒即时性 —— **存疑(0 次触发,功能近乎不可达)**

`wakeOnProximity=true` 全程生效(timing.log 12971 行),但 `[SM] pre-wake triggered` 自 09-26 起**零次**。以 09-29 14:01:56 锁屏 → 14:05:14 解锁窗口解剖:

```
14:01:56  lockedAway,screen=displaySleeping
14:02→14:04:40  [LOCK] applyLockTimer 约 1Hz,eff 从 -91 缓升至 -85.3(preWakeThreshold=-85,差 0.3dBm)
14:04:40→14:04:58  **18 秒采样缺口**(无任何 RSSI 事件)
14:04:58.503  onDeviceApproached screen=locked(manual)  ← 用户已手动点亮屏幕
```

两处预唤醒门控(FUnManager+Events.swift:199-205 阶梯唤醒、:284-292 onRSSIUpdated)均要求 `state.screen == .displaySleeping`。用户手动点亮屏幕后门控永久失效;而 EMA 爬升受显示器休眠期 BLE 采样缺口(18s)与 18 秒前 0.3dBm 之差拖累,始终没能在用户手动点亮前越过 -85。此外当前配置 `preWakeThreshold=-85` 与锁屏阈值同值,提前量≈0(源码注释默认值为 -60)。

正面证据:离场后**无**误点亮(Phase 6 的 nil 派发守卫生效)。EMA 重构本身未见回归,但预唤醒在真实使用中被"用户手动点亮"100% 抢先,功能不可达。

### ④ P0-4 无 degraded / 无连击 —— **生效**

degraded 零条;2 次 unlockFailed 均为"第 1/3 次尝试"且重试成功、`counter reset`;4 次 stateMachineBlocked 全部是在途解锁期间的门控拦截(即 P0-4 补上的 `.unlocking` 排他正常工作),未出现"stateMachineBlocked 后 unlockFailed 连击"的 A2 禁忌模式。

## 3. 新发现的异常模式

### A.【P1 建议】显示器熄灭场景首次注入双验证不稳定(2/3 失败)

三次显示器熄灭下的解锁:09-28 16:05 首次注入 1.7s 验证通过;09-29 14:05、16:05 首次注入均失败、~13s 后重试才成功。失败序列:

```
14:04:58.887  isDisplayPoweredOn: IOEnginePower not found(显示器熄灭)
14:04:58.891  sendShiftKey: SUCCESS → "Shift sent, waiting 300ms"
14:04:59.195  injecting password → posted=true
14:05:00.238  waitForUnlockNotification: timeout (1.0s)
14:05:01.241  checkScreenUnlocked: timeout (2.0s) → dual verify failed, attempts=1/3
14:05:12.838  重试 → 14:05:14 passed
```

初步定位:Shift 唤醒后固定等 300ms 即注入,但显示器从熄灭到 loginwindow 密码框就绪超过 300ms,首次注入落入空窗;重试时屏幕已就绪故成功。用户可感:解锁延迟从 ~2s 变为 ~13-16s(21:42 用户就在自动解锁跑完前 3s 手动输了密码)。方向:固定 300ms 改为等 display power-on 确认,或首次验证失败后缩短重试退避。

### B.【P2 建议】预唤醒不可达(见 §2-③)

建议下轮专项:① preWakeThreshold 与锁屏阈值同值导致提前量≈0,需定配置基线;② 显示器休眠期 BLE 采样缺口(18s)成因排查(Watch 广播间隔 vs Mac 扫描策略);③ 考虑用户手动点亮后补偿评估一次。

### C.【P3 建议】shadow_telemetry 结果字段全 N/A

09-28 起 21 行(auto_lock×12、auto_unlock×9)的 `Result`/`Duration_ms`/`InjectTime`/`ConfirmTime` 全为 N/A,结果回写链路未工作,遥测无法用于注入耗时分析。另:Is_Anomalous=true 出现在 3 次 auto_lock(离场瞬间斜率大,疑似正常离场被误标)。

### D.【记录】manualLockActive 拦截与 WiFi 暂停短路

09-30 07:09 手动锁 → 08:19:51 跳过原因 manualLockActive(手动锁意图 86400s,语义为"直到下次手动解锁",与 FUnManager.swift:71 注释一致,属设计行为)。6 次手动输密码解锁中,21:42/00:41/06:55 为 WiFi 暂停短路拦截、08:19 为 manualLockActive、17:31 与 23:38 为锁后秒级返回(cooldown/阈值边缘),均有门控日志解释,不构成缺陷。

## 4. 按日志驱动迭代规则的结论

- 样本:1.8 天、解锁事件 10 次 → **不足 3 天,标注"样本量不足,仅初步观察",不进入优化决策**。
- 初步判定:P0-3 ✅ 生效 / P1-2 ✅ 生效(B2 场景未覆盖)/ P0-4 ✅ 生效 / Phase 6 预唤醒 ⚠️ 存疑(0 触发)。
- 建议下一轮(优先级):
  1. **P1**:首次注入 300ms 空窗修复(§3-A)——影响每一次显示器熄灭下的解锁延迟,样本内复现率 2/3。
  2. **P2**:预唤醒可达性专项(§3-B)——配置基线 + 休眠期采样缺口排查。
  3. **P3**:shadow_telemetry 结果回写(§3-C)与 Is_Anomalous 离场误标。
  4. 继续积累样本至 ≥3 天且解锁事件 ≥10 次,重点覆盖:设备不在场时手动解锁(B2)、WiFi 环境外多日使用、pre-wake 配置调整后复测 A7。
