# FUnlock 三轮审计：新版试运行报告（09-28 → 10-02）

> ⚠️ **本报告已被 [2026-10-02-audit-final.md](2026-10-02-audit-final.md) 取代**（双审交叉验证终稿）。本报告中两处推论已被复核推翻：①"平均 1% CPU 说明呼吸动画修复生效"（实为首次展开弹窗后 15-21% 永久空转，见终稿 P1-1）；②"每次手动解锁触发一次联网更新检查"（checkUpdate 有 24h 限流，见终稿 §三-1）。保留本文件仅作审计过程溯源。

> 任务：对 2026-09-28 装机以来的新版试运行做全量审计（运行表现 / 上轮修复复核 / 新问题 / 工程遗漏）。
> 运行版本：v2.8.37（build 1523），09-30 15:21 装机，进程自 09-30 18:00 连续运行，累计 CPU ≈ 44 分钟（平均 ≈1%）。
> 数据源：`~/Library/Logs/FUnlock/`（decisions.jsonl 2791 条、debug.log 38k 行、timing.log、shadow_telemetry.csv 179 行）+ `~/Library/Application Support/FUnlock/events.log` 534 条。
> 样本口径：旧窗口 09-28 14:43 → 09-30 10:03（1.8 天），新窗口 09-30 10:03 → 10-02 16:19（2.3 天），合计约 4 天。

## 结论（先行）

**按日志驱动迭代规则：样本已过基础标准（解锁事件 1383 条、覆盖 4 天），可进入初步分析；telemetry 179 行未达进阶标准（400），参数级优化仍须继续积累。**

三项发现需要立即处理：**① 入侵告警 100% 误报（22/22 手动解锁均触发 intruded）**，上轮"P1-2 生效"的结论被推翻——原因是上轮复盘的数据源漏掉了 events.log；**② 显示器熄灭场景首注失败持续复现（7/25 = 28%）**，其中 3 次用户放弃等待、2-9 秒内手动输密码，功能在用户眼里等于失效；**③ 一次瞬时注入失败（与手动解锁赛跑）被误报为 axRevoked 并可能弹出模态警告**。另外确认：预唤醒（Phase 6）结构性不可达、wifiPaused 停止触发但无法从日志区分"人不在家"还是"读取失败"、遥测 Result 列 100% N/A、**运行的是 Debug（-Onone）构建**。

无回退信号（无崩溃、无误锁、无连击、日志系统健康），当前版本可继续运行。

## 一、样本量（达标层）

| 事件类型 | 旧窗口 | 新窗口 | 合计 |
|---|---|---|---|
| 自动解锁成功 | 8 | 10 | 18 |
| 首注失败（第 1/3 次） | 2 | 5 | 7（28% 首注失败率） |
| 自动锁屏 lockedAway | 10 | 17 | 27 |
| 手动锁屏 / 手动解锁 | 4 / 6 | 11 / 16 | 15 / 22 |
| intruded（修复后） | 3 | 26 | 29 |
| pre-wake 触发 | 0 | 0 | 0 |
| degraded / ERROR 级日志 | 0 / 0 | 0 / 0 | 0 / 0 |
| wifiPaused | 1335 | **0** | 1335（09-30 06:55 后消失） |
| manualLockActive | 10 | 1230 | 1240 |

跳过原因新窗口分布：manualLockActive 1230（94%）>> unlockCooldownActive 22 > signalBelowThreshold 18 > stateMachineBlocked 10 > noPresence 6。

## 二、四项重点修复复核（推翻一项）

### ① P1-2 合法解锁不误报入侵 —— ❌ 无效，上轮结论被推翻

**证据**：events.log 中修复后仍记录 29 条 intruded（09-29×3、09-30×17、10-01×4、10-02×5）。与 decisions.jsonl 交叉验证：**22/22 次手动解锁（userUnlocked）都在 2 秒后触发 intruded**，无一例外——包括设备在场信号良好（RSSI -50~-66，高于 -65 解锁阈值）的场景。

**根因**：入侵判定（`FUnManager+Events.swift:118-129`）只有 `!wasFUnUnlock` 一个条件（"是不是 FUn 自动解锁的"）+ `unlockRSSI != UNLOCK_DISABLED`（功能开关），**从未实现设备在场（RSSI）判定**。上轮修复只解决了"FUn 自己的自动解锁被误标"，没解决"真正手动解锁"的区分。上轮复盘数据源只看了 decisions.jsonl/debug.log（intruded 只写入 events.log），因此误判"0 条、修复生效"。

**当前影响**：无系统通知，仅写 events.log + 触发用户脚本钩子（AutomationView 支持把 intruded 接到自定义脚本）——一旦用户配了脚本（如 iMessage/Webhook 告警），每次手动输密码都会误触发告警。数据层面 events.log 被 29 条噪声污染。

**修复方向**：onUnlock 中捕获解锁瞬间快照，`eff ≥ unlockRSSI`（或在场判定）时不发 intruded；仅设备不在场时才告警（对齐上轮 B2 语义）。

### ② P0-3 手动唤醒自动解锁 —— ✅ 持续生效

新窗口 10 次解锁成功中 6 次 screen=locked(manual)/locked(away)，`tryUnlock() START` 在接近事件后 0.3~0.4s 内启动，全链完整。无回退。

### ③ P0-4 无 degraded / 无连击 —— ✅ 持续生效

degraded 0 条；stateMachineBlocked 10 次全部是在途解锁期间的门控拦截（预期行为）；无"blocked 后失败连击"模式。

### ④ P0-5 / Phase 6 预唤醒 —— ❌ 结构性不可达（升级为实证）

0 次触发。新证据：显示器休眠期 RSSI 采样缺口比上轮记录的 18s **严重得多**——10-01 02:53→10:59 休眠窗口内最大缺口 **527s（8.8 分钟）**、>5s 缺口 1784 次；10-01 12:06→16:42 窗口 4.6 小时仅 60 条 RSSI、最大缺口 **6456s（1.8 小时）**。EMA 在休眠期被饿死，信号不可能在用户手动点亮前爬到 preWakeThreshold（-85）。且 `preWakeThreshold = unlockRSSI(−65) − wakeAdvance(20) = −85` 与锁屏阈值 -85 恰好同值（`FUnManager+Events.swift:199` 注释里的"-60"已过时）。

**修复方向**：先补观测再动手——排查休眠期扫描停顿成因（Watch 广播策略 vs CoreBluetooth 在显示器休眠时被系统挂起），再定 preWake 阈值基线。当前建议把 preWakeThreshold 与 lockRSSI 解耦（如固定 -75）。

## 三、新确认的问题（按优先级）

### P1-A 显示器熄灭首注失败（上轮 P1 未修，持续复现）

7 次失败全部是"第 1/3 次尝试"，序列一致：`isDisplayPoweredOn: IOEnginePower not found` → Shift 唤醒 → **固定等 300ms** → 注入 posted=true → 验证超时 → fail。显示器从熄灭到 loginwindow 密码框就绪超过 300ms，首注落入空窗。后果量化：7 次失败中 3 次用户 2-9 秒后手动输密码（09-30 15:36、17:21、10-02 16:09），另有 2 次靠 13s 重试救回。用户可感延迟 13-16s，且每次都伴随一次 intruded 误报。

**修复方向**：Shift 后轮询显示器电源就绪（IOEnginePower 出现）再注入，上限超时（如 3s）；或首注失败后缩短重试退避（13s → 3-5s）。

### P1-B 瞬时注入失败误报 axRevoked + 模态告警

09-30 11:57:11：Level1（cgSessionEventTap）→ Level2（cghidEventTap）均失败、Level3 因"screen no longer secure"中止——实际是**用户手动解锁与注入赛跑**（2 秒后屏幕即变 unlocked），权限本身正常。但代码把任何 `posted=false` 都折叠为 axRevoked（`UnlockOrchestrator.swift:175`），并可能触发 `showAXRevokedAlertIfNeeded` 模态弹窗（`runModal` 抢焦点）。应区分：屏幕状态翻转（良性竞态）vs 权限真实撤销（tap 创建失败 + 权限 API 确认）。

### P2-A wifiPaused 停止触发，且 fail-open 静默

配置完好（pauseOnWiFi=1、SSID="Xiaomi_DB79_5G"），但 09-30 06:55 后 0 触发。当前 Mac 未关联任何 WiFi（抽查时点），最可能是用户不在家/未连家庭 WiFi（国庆出行与 10-01 起夜间手动锁屏行为吻合）。但 `WiFiMonitor.currentSSID` 读取失败时**静默返回 nil 直接放行，无任何日志**——若定位权限（macOS 27 SSID 读取所需）被撤销，功能会悄无声息失效，日志无法区分两种情形。**修复方向**：SSID 读取失败/未关联时加 debug 日志；诊断页显示当前 SSID 读取状态。

### P3-A 遥测 Result 列 100% N/A（上轮 P3 未修，确认）

shadow_telemetry.csv 179 行全部 Result/Duration_ms/InjectTime/ConfirmTime = N/A。根因：`TelemetryLogger.log` 的参数默认值 `result: "N/A"`，而 `UnlockOrchestrator.swift:207` 的调用方从不传参（verify 结果就在同函数内，几行就能接上）。RSSI 列正常。

### P3-B 杂项

- **onDeviceApproached 突发重复**：3 天 1779 个"200ms 内 ≥3 连发"簇（如 07:10.442 同一毫秒两条、eff 值不同），靠近处理管线对突发无去重，每簇冗余跑 3 次评估。
- **每次手动解锁触发一次联网更新检查**（`onUnlock` 尾部 `checkUpdate()`），4 天 22 次，低量但无必要。
- **测试事件污染生产日志**：events.log 含 96 条 `test_default_window`（时间戳 2023-11-15），历史测试写入遗留。
- 09-30 15:26 重装期间 7 条 intruded 突发为安装噪声，已剔除分析。

## 四、工程与流程问题

1. **运行的是 Debug 构建**：安装包 `com.fuhahah.FUnlock-dev`、`SWIFT_OPTIMIZATION_LEVEL=-Onone`、包内含 FUnlock.debug.dylib。与记忆中"编译 Release 再安装"的流程不符（docs/0804-handoff.md 的构建命令也写的是 Debug）。-Onone 放大了 CPU 成本（12.6% 呼吸动画问题就是在 Debug 下实测的；当前平均 1% 说明 b41341d 的修复很可能已在运行版本内——构建 15:21 早于提交 15:27，属先构建后提交）。
2. **切回 Release 的连锁代价**：TCC 辅助功能/定位授权按 bundle id 绑定（-dev → 生产 id 需重新授权）；Keychain 服务名 = `Bundle.main.bundleIdentifier`，Release 版会读 `com.fuhahah.FUnlock` 条目（可能是旧密码），两套条目并存易踩错。
3. **`docs/audits/2026-09-30-log-review.md` 未提交**（git 未跟踪），且上轮复盘的 intruded 判定因数据源遗漏 events.log 而失真——建议修正该文档 §2-② 的结论后一并提交。
4. docs/handoff.md 约定"CFBundleVersion 提交时保持 1258、部署时自动递增、勿提交递增值"，但 ac02675 提交了 1523，流程与实际不一致。

## 五、建议行动（按日志驱动迭代规则）

可直接动手（依据充分，不动参数）：
1. intruded 加设备在场判定（修 P1-2，验证：手动解锁不再产生 intruded，设备不在场时仍告警）
2. 首注等待显示器就绪 + 缩短重试退避（修 P1-A，验证：显示器熄灭场景首注成功率）
3. axRevoked 区分瞬态失败与真实撤销，瞬态不弹窗（验证：模拟赛跑场景无告警）
4. telemetry 补传 result/duration/inject/confirm 四参（验证：CSV 新行字段非 N/A）
5. SSID 读取失败加日志（补观测）

先补观测再动手：
6. 预唤醒：休眠期扫描停顿成因（加扫描事件日志 / 对比系统休眠层级），preWake 阈值与 lockRSSI 解耦后再验证 A7
7. wifiPaused：加"未关联 WiFi / SSID 读取失败"日志后跑满一周，确认功能本身健康

流程项：确认 Debug/Release 构建意图；修正并提交两篇复盘文档；测试 events.log 写入路径核对（LogRotationTests 已有隔离，核对 96 条遗留来源）。
