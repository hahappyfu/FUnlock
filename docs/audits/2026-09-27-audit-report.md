# FUnlock 第二轮审计总报告(2026-09-27)

> 指挥中心合并版。数据来源:4 个并行审计子智能体(修复验证/并发/测试/架构)+ 构建基线 + 测试基线。
> 所有 P0/P1 均经总指挥亲自对照当前代码核验;标注「修正」处为核验时对子智能体结论的校正。

## 0. 基线数据

- 构建:`BUILD SUCCEEDED`,零编译警告(仅 1 条 Run Script 阶段无 outputs 的工程配置警告)
- 测试:390/390 通过
- 关键事实:**测试全绿本身是危险信号**——两个破坏性用例"通过"的同时删除了真实数据(见 P0-1/P0-2)

## 1. 合并发现清单

### P0(必须立即修复,按后果排序)

| # | 标题 | 来源 | 核验 |
|---|---|---|---|
| P0-1 | 单测清空真实 Keychain 密码:`testHandlePasswordChangedIgnoresWhenSessionUnlocked` 使用 `SecurityService.shared`(真实条目),先覆盖真密码再 `deletePassword()` | 修复验证组 | ✅ 已触发:基线测试已删除 `com.fuhahah.FUnlock-dev` 条目;生产条目完好 |
| P0-2 | 测试写删生产配置域:`ProfileImportExportTests` setUp 对 `ConfigStore.shared`(suite `com.fuhahah.Funlock.config`)执行 `removeObject("profiles"/"activeProfileID")`;至少 6 个测试类读写该生产域 | 测试组 | ✅ 当前生产域已无这两个键 |
| P0-3 | 手动唤醒自动解锁 100% 自杀:`onDisplayWake` 手动分支先 `attemptAutoUnlock()` 调度 300ms 延时任务,下一行 `onUserIntervention()` → `cancelPendingTasks()` 同步取消它 | 并发组 | ✅ 全链坐实 |
| P0-4 | `canAttemptUnlock` 漏排 `.unlocking`,0.5s 快轮询重入时 `unlockTask?.cancel()` 掐死在途 2s 双保险验证→误判失败→连续 3 次触发 `.degraded` 永久停摆 | 并发组 | ✅ 门控与取消链坐实;【修正】agent 原称"每次解锁必死"言过:快成功场景 `guard screenLocked` 先 SKIP,真实窗口是注入慢(>0.5s)或注入失败时 |
| P0-5 | `FUn.monitoredUUID`/`FUn.devices` getter/setter 透传无锁(BLEScanner.swift:89 注释自认跨线程共享),主线程 UI 轮询读 vs bleQueue 锁内写,Swift 内存模型 UB | 并发组 | ✅ 坐实;同文件 `unlockRSSI` 有锁化 getter/setter 可作参照模式 |

### P1(重要)

| # | 标题 | 来源 | 核验 |
|---|---|---|---|
| P1-1 | `passwordChanged` 逻辑颠倒:`guard isSessionLocked` 使真实改密(必在未锁屏时)100% 被忽略;锁屏时收到通知反而 `runModal()` 挡在锁屏后阻塞主线程 | 修复验证组 | ✅ 坐实(上轮 B4 修复引入) |
| P1-2 | 合法自动解锁被误判入侵:`isAutoUnlocking` 由 verify defer 过早复位,慢速分布式通知(100-500ms)到达时已为 false→误触发 `intruded` 脚本 | 并发组 | ✅ 机制坐实;概率依赖真实通知延迟 |
| P1-3 | 离场锁屏 Timer TOCTOU + 缺身份守卫,产生僵尸 Timer | 并发组 | ✅ TOCTOU 结构坐实;【修正】fire 块有信号回升保护+身份校验清理,真实危害收敛为"用户确已离场时双定时器重复锁屏事件",非"在场误锁屏" |
| P1-4 | 密码注入路径主线程 `Thread.sleep` 共 ~500ms(代码注释自认技术债,上轮标"本轮不动") | 并发组 | ✅ 代码自认 |
| P1-5 | `os_unfair_lock` 临界区内调 SQLite 磁盘查询与嵌套锁(BLEScanner 锁内 `getLEDeviceInfoFromUUID`) | 并发组 | 待修复时顺带确认 |

### P2(合并去重后的工程债)

**架构组 8 条**(全部核验;F-2 写入点修正为 NetworkSettingsView.swift:43):架构文档滞后、View 直持 FUn 越层写入、NSAlert 模板重复 11 处、冷却 5s 双处定义、手动锁语义散布 3 处+86400 魔法数、`as! CFNumber` 防御不对称、禁用哨兵双写法、RSSI 格式化 29 处。

**上轮 P2 未做清单 18 项**(修复验证组逐项对照):公证/SHA256、Keychain 数据保护标志、通知白名单、死状态清理(preWaking/readyToUnlock)、图表假深谷、smoothedRSSI 双重驱动、ConfigKey 枚举、休眠激活策略 Hack、信号环拆分、图表降采样、Accessibility 标签、权限轮询收敛、Info.plist 冗余、pbxproj 悬空引用、FUnDelegate 双包装、RSSI 颜色双标准、日志路径单源、BLE 中继设计边界(产品决策)。

**测试组缺口**:4 大零覆盖区(更新链 255 行、SignalHysteresisEngine.checkProximity 本体、Keychain 存取往返、BLEScanner 335 行);约 40 个空转/同义反复假测试(InjectionPreludeTests 7 个零调用、UnlockAttemptWindowTests 重抄算法自测、testTimeStringContainsOnlyTime 断言=实现);10 个脆弱测试(0.5s/1.2s 硬等待、Calendar.current 午夜边界、CSV 列下标断言);FUnlockTests.swift 22 类 14 主题应拆 8-10 文件。

## 2. 核验修正记录(子智能体报告 → 修正后结论)

1. 架构组 F-2:`setPassiveMode` 写越层实为 NetworkSettingsView.swift:43,非 MainWindowView:43
2. 并发组 P0-4(上表):影响范围收窄为慢注入/失败窗口
3. 并发组 P1-3(上表):僵尸 Timer 影响收敛,非"在场误锁"

## 3. 修复路线图

- **Phase 1(数据安全 + 自杀逻辑,P0 全清)**:P0-1/P0-2 测试隔离、P0-3 顺序交换、P0-4 门控补全、P0-5 锁化 getter
- **Phase 2(并发收口)**:P1 五项;其中 P1-1 需产品决策(改密通知的确认交互形态)
- **Phase 3(测试体系)**:补 4 大零覆盖区、清空转假测试、拆分巨型测试文件、加固脆弱测试
- **Phase 4(P2 工程债)**:26 条 P2 按收益挑做
- **Phase 5(真机行为验证)**:靠近解锁/离开锁屏/睡眠唤醒/手动唤醒/SSID 切换/改密/更新链,日志驱动验收

## 4. 亮点(保留勿伤)

FUn extension 拆分+线程契约头注释、SignalHysteresisEngine 单源、锁内快照模式、值类型 SignalPipeline、时间源注入、verifyUnlock 可测试版本、节流器内聚、DecisionLogger/TelemetryLogger 主线程解耦。
