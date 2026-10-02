# FUnlock 三轮审计终稿：双审交叉验证报告（09-28 → 10-02 试运行）

> 本报告为**终稿**，由两份独立审计交叉合并而成：主审计（Fable 5，基于 4 天全量日志）+ 独立复核（Opus，不信任主审计结论、独立重查日志与源码、另查崩溃报告/提交代码/测试）。分歧点已由主会话逐条验证仲裁。**本报告取代 docs/audits/2026-10-02-audit-report.md**（该文有两处错误推论，见 §三）。
> 运行版本：v2.8.37 build 1523（09-30 15:21 装机，进程自 09-30 18:00 运行，PID 873）。
> 数据源：decisions.jsonl 2791 条、debug.log(.old) 38k 行、timing.log(.old)、shadow_telemetry.csv 181 行、events.log 534 条、进程采样 sample/ps。

## 结论（先行）

**样本达标**（解锁事件 1383 条、覆盖 4 天），可进入初步分析；telemetry 未达进阶标准，参数级优化需继续积累。**无回退信号**，但存在 **1 个正在发生的 P1 资源泄漏**（当前进程 CPU 21.3% 空转，且持续上涨）与 **1 个 100% 复现的 P1 功能缺陷**（入侵告警每次手动解锁必误报）。8 项断言双审一致，全部证实；主审计报告的 2 处推论被复核推翻并已仲裁。修复优先级清单见 §五。

## 一、8 项断言：双审一致性结果

| # | 断言 | 主审计 | Opus 复核 | 仲裁 |
|---|---|---|---|---|
| 1 | intruded 100% 误报（22/22 手动解锁触发，判定无 RSSI 在场条件） | 证实 | 证实 | ✅ 证实 |
| 2 | 首注失败 7/25=28%，Shift 后固定 300ms 不足，3 次用户放弃等待 | 证实 | 证实 | ✅ 证实 |
| 3 | 09-30 11:57 注入与手动解锁赛跑被误报 axRevoked + 模态警告 | 证实 | 证实 | ✅ 证实 |
| 4 | 预唤醒 0 触发；休眠期采样缺口最大 527s；preWake=-85 与锁屏阈值同值 | 证实 | 证实 | ✅ 证实 |
| 5 | wifiPaused 配置完好但 09-30 06:55 后 0 触发；SSID 读取失败静默放行 | 证实 | 证实 | ✅ 证实 |
| 6 | 遥测 Result/Duration/Inject/Confirm 四列 100% N/A，调用方从不传参 | 证实 | 证实 | ✅ 证实 |
| 7 | 运行的是 Debug 构建（-dev bundle id、-Onone、含 debug.dylib），Keychain 服务名随 bundle id | 证实 | 证实 | ✅ 证实 |
| 8 | 样本统计（成功 18 / 失败 7 / userUnlocked 22 / wifiPaused 1335→0 / manualLockActive 1230 / degraded 0 / ERROR 0） | 证实 | 证实 | ✅ 证实，intruded 计数口径见 §三-3 |

## 二、合并后最终问题清单（按优先级）

### P1-1 呼吸动画空转：transient Popover 下 b41341d 修复失效，CPU 15~21% 永久空转【Opus 新发现，主审计漏判】

- **现象**：进程当前 CPU **21.3%** 且持续上涨（审计开始时 16.5%，47 分钟后 21.3%；累计 CPU 时间与"首次点开弹窗后按 15-19% 空转"精确吻合）。`sample 873` 可见 RepeatAnimation.animate / NSHostingView.layout / CA::Transaction::commit 高频重绘。
- **根因**：`AppDelegate.swift:551` popover `.behavior = .transient` 且**未实现 NSPopoverDelegate**。点击外部关闭时 AppKit 仅 orderOut，contentViewController 常驻、SwiftUI 不触发 `.onDisappear`，b41341d 的动画启停绑定失效。用户 10-02 11:08:54 点开一次弹窗后即永久空转。
- **主审计纠偏**：原报告以"平均 1% CPU"推断修复生效——平均掩盖了阶跃劣化（前 41 小时 0%，首次展开后 15-21% 持续至今）。
- **修复**：实现 NSPopoverDelegate，在 popoverDidClose 中重置 popoverVisible；或关闭时释放 contentViewController。**这是当前唯一在消耗电量的进行时缺陷，建议最优先。**

### P1-2 入侵告警 100% 误报（22/22）

双方一致（§一-1）。修复后窗口内 22 次手动解锁（含大量 RSSI -48~-66 设备紧贴场景）全部在 2.04~2.33s 后触发 intruded。根因：`FUnManager+Events.swift:118-129` 判定仅 `!wasFUnUnlock` + 功能开关，**无设备在场判定**。当前无系统通知，仅 events.log + 用户脚本钩子；一旦用户为 intruded 配脚本（AutomationView 支持），每次手动输密码都会误触发。修复：onUnlock 捕获解锁瞬间信号快照，`eff ≥ unlockRSSI` 时不告警。

### P1-3 首注失败：显示器熄灭场景 28% 失败率

双方一致（§一-2）。全部 7 次失败序列相同：`IOEnginePower not found` → Shift → 固定 300ms（`SystemInteractionService.swift:332` 硬编码）→ posted=true → 验证超时；3 次用户 1.7-8.9s 后放弃等待手动输密码（每次还叠加一次 intruded 误报）。修复：Shift 后轮询显示器电源就绪（IOEnginePower 出现）再注入，上限 3s；重试退避 13s → 3-5s。

### P1-4 注入失败误报 axRevoked + 模态弹窗

双方一致（§一-3）。`UnlockOrchestrator.swift:170-177` 把任何 posted=false 折叠为 axRevoked；`SystemInteractionService.swift:541` runModal 抢焦点。09-30 11:57 实际是用户手动解锁与注入赛跑（Level1/2 失败、Level3 因 screen no longer secure 中止，5 秒内屏幕已 unlocked）。修复：区分瞬态竞态（屏幕状态翻转）与真实权限撤销（tap 创建失败），瞬态不弹窗。

### P2-1 预唤醒结构性不可达

双方一致（§一-4），Opus 补充一个根因：`FUnManager+Events.swift:200,286` 门控要求 `screen == .displaySleeping`，**手动锁屏（locked(manual)）下即使屏幕黑屏也永远无法触发**。叠加：休眠期采样缺口最大 531.6s（10-01 09:08→09:16）、preWakeThreshold=-85 与 lockRSSI 同值、注释"-60"过时。修复：先补扫描停顿成因观测；preWake 与 lockRSSI 解耦（如固定 -75）；放宽门控覆盖 locked(manual) 熄屏态。

### P2-2 单测污染生产 events.log【Opus 新发现，主审计仅标"历史遗留"】

根因已定位：`FUnlockTests/StateAndConfigTests.swift:247` `ScriptRunner(dedupWindow: 3.0) {...}` 未传 testLogDirectory，落入默认 `ScriptRunner.shared.testLogDirectory`（生产环境为 nil）→ 写入真实 `~/Library/Application Support/FUnlock/events.log`；测试时钟固定 1_700_000_000（2023-11-15）。96 条 test_default_window = 48 次测试运行 ×2 条。修复：显式传 `testLogDirectory: tempDir`。

### P2-3 诊断页分块渲染以 `\.offset` 为 ID，动态追加致乱序/闪烁【Opus 新发现】

`DiagnosticsView.swift:180` `ForEach(...chunked(pageSize:).enumerated(), id: \.offset)`——时间线倒序追加时新事件挤入第 0 块，后续块整体后移但 ID 不变，SwiftUI 错误复用卡片状态。修复：块 ID 改用块内首末事件 ID 组合或时间戳哈希。

### P2-4 wifiPaused 停触发 + 静默 fail-open

双方一致（§一-5）。配置完好但 09-30 06:55 后 0 触发；抽查时 Mac 未关联任何 WiFi，最可能人不在家，但 `WiFiMonitor.swift:21-27` 失败静默返回 nil、调用方无日志，无法区分"没连 WiFi"与"定位权限被撤"。修复：SSID 读取失败/未关联时加 debug 日志 + 诊断页状态提示。

### P3-1 遥测四列 100% N/A

双方一致（§一-6）。三个调用点（UnlockOrchestrator.swift:207/294、FUnManager+Events.swift:247）均未传 result/durationMs/injectTime/confirmTime。修复：把验证结果直接接上。

### P3-2 CFBundleVersion 规范失配

双方一致。docs/handoff.md 约定"提交保持 1258、部署时递增、勿提交递增值"，ac02675 提交了 1523。恢复基准或更新文档约定。

### P3-3 工程杂物

- b41341d 未推送 origin（本地领先 1 提交）
- 仓库根 FUnlock.zip 为 09-28 旧产物（比运行版本旧一天）
- docs/audits/2026-09-30-log-review.md 与两篇新审计报告未提交
- onDeviceApproached 突发重复：3 天 1779 个"200ms 内 ≥3 连发"簇，无去重

## 三、分歧仲裁（3 处）

1. **"每次手动解锁触发一次联网更新检查（4 天 22 次）"——主审计错误，撤销。** checkUpdate.swift:22-27 有 24h 限流（lastUpdateCheck=10-02 01:15:37），22 次调用中 21 次直接返回，实际请求约 1 次/24h。非问题，从清单移除。
2. **"平均 1% CPU 说明 b41341d 修复生效"——主审计错误，撤销。** 实为阶跃型回归：0% → 首次展开弹窗后 15-21% 永久空转。见 P1-1。
3. **intruded 计数口径——统一为：** 09-29 起 29 条，其中 7 条为 09-30 15:26 重装噪声；剔除后 22 条真实告警 = 22/22 次手动解锁一一对应。核心结论（100% 误报）不受口径影响。

## 四、方法论教训（供下轮复盘参考）

1. **数据源完整性**：intruded 只写 events.log，上轮复盘漏看导致 P1-2 误判"生效"；下轮必须覆盖全部五个日志文件。
2. **平均值陷阱**：CPU 用"累计/墙钟"平均会掩盖阶跃劣化；应分时段看 CPU 或直接 `sample`。
3. **代码核实**：从调用栈推断行为（checkUpdate 每次调用=每次请求）不成立，必须读实现。

## 五、修复优先级

| 序 | 问题 | 级别 | 依据充分度 | 动作 |
|---|---|---|---|---|
| 1 | 呼吸动画空转（正在烧电） | P1 | 充分 | 立即改：NSPopoverDelegate 关停动画 |
| 2 | intruded 加在场判定 | P1 | 充分 | 改：onUnlock 信号快照门控 |
| 3 | 首注等显示器就绪 + 缩短重试 | P1 | 充分 | 改：轮询 IOEnginePower + 退避 3-5s |
| 4 | axRevoked 区分瞬态竞态 | P1 | 充分 | 改：区分后瞬态不弹窗 |
| 5 | 单测隔离漏洞 | P2 | 充分（根因已定位） | 改：传 testLogDirectory |
| 6 | 诊断页分块 ID | P2 | 充分 | 改：稳定块 ID |
| 7 | SSID 失败日志（补观测） | P2 | 充分 | 改 + 继续观察一周 |
| 8 | 遥测四参回写 | P3 | 充分 | 改：接上验证结果 |
| 9 | 预唤醒阈值解耦 + 门控放宽 | P2 | 需先补观测 | 先查休眠期扫描停顿成因 |
| 10 | build 号规范、推送、zip、文档提交 | P3 | — | 流程整理 |

**验证方式**：每项修复后按日志驱动迭代规则用真实日志验证——P1-2 看 events.log 中 intruded 是否只出现在设备不在场时；P1-3 看显示器熄灭场景首注成功率；P1-1 看 `ps` CPU 在弹窗展开-关闭后是否回落。
