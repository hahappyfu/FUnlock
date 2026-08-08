# FUnlock 项目全面审计报告

**日期：** 2026-08-07
**版本：** 2.8.30 (1263)
**分支：** feat/diagnostics-tab
**代码规模：** ~8300 行 Swift，38 个源文件

---

## 一、审计总览

| 维度 | Critical | Important | Nice to have | 亮点 |
|------|----------|-----------|--------------|------|
| 代码质量 | 5 | 8 | 8 | — |
| 架构设计 | 3 | 3 | 2 | SystemInteractionService 三级降级设计良好 |
| 测试覆盖 | 6 缺失 | 4 缺失 | 3 缺失 | SignalPipeline/FUnlockStateMachine 测试完善 |
| 安全 | 2 | 5 | 4 | Keychain 安全级别正确、密码不写日志 |
| 性能 | 4 | 5 | 4 | 内存占用仅 ~100KB、Timer 无泄漏 |

---

## 二、必须修复（Critical）

### 代码质量

| # | 问题 | 文件 | 风险 |
|---|------|------|------|
| C1 | Device 类属性无线程安全保护 | FUn.swift:54-117 | BLE 线程写、主线程读，竞态崩溃 |
| C2 | devices 字典跨线程无锁访问 | FUn.swift:135,879-923 | 字典并发读写崩溃 |
| C3 | Thread.sleep 阻塞主线程 | SystemInteractionService.swift:71,297 | UI 冻结 0.3 秒 |
| C4 | lockLog 全局函数线程不安全 | FUn.swift:7-17 | 并发写文件数据损坏 |
| C5 | LEDeviceInfo 全局变量无线程保护 | LEDeviceInfo.swift:5-7 | 竞态条件 |

### 安全

| # | 问题 | 风险 |
|---|------|------|
| H1 | BLE 设备身份验证缺失 — RSSI 可被欺骗 | 攻击者可在 10-30 米内伪造信号解锁 |
| H2 | 更新机制缺少代码签名验证 | 供应链攻击可替换二进制 |

### 测试缺失

| # | 缺失模块 | 风险 |
|---|---------|------|
| T1 | WiFiMonitor 完全无测试 | WiFi 断连导致解锁异常 |
| T2 | RingBuffer 完全无测试 | 边界溢出未验证 |
| T3 | BLE 连接/断开回调无测试 | 蓝牙断开后状态残留 |
| T4 | onDeviceLeft() 无独立测试 | 误锁或漏锁 |
| T5 | SystemInteractionService 核心方法无测试 | 密码注入失败 |
| T6 | SignalDataStore 完全无测试 | 数据不一致 |

---

## 三、应该修复（Important）

### 代码质量

| # | 问题 | 文件 |
|---|------|------|
| I1 | performInjectionAndVerify 中 isAutoUnlocking 竞态窗口 | FUnManager.swift:684 |
| I2 | scanForPeripherals 中 currentScanAllowDuplicates 读写不一致 | FUn.swift:211 |
| I3 | Task 闭包中隐式捕获 self 强引用风险 | FUnManager.swift:617-626 |
| I4 | UserDefaults 读取频率过高 | FUn.swift:334,554,746 |
| I5 | ScriptRunner 文件 I/O 无同步保护 | ScriptRunner.swift:51-67 |
| I6 | monitoredUUIDs 读取不在锁内 | FUn.swift:842,866 |
| I7 | Bundle ID 硬编码 | UpdateDownloader.swift:89 |
| I8 | 通知文案未国际化 | FUnlockStateMachine.swift:154 |

### 架构

| # | 问题 | 建议 |
|---|------|------|
| A1 | FUnManager 职责过重（46KB） | 拆分为 LockScreenStateManager + UnlockDecisionEngine |
| A2 | 两套状态系统协调不明 | 明确 FUnlockStateMachine 和 LockScreenState 关系 |
| A3 | AppDelegate 混杂业务逻辑 | 创建 AppCoordinator 协调器 |

### 安全

| # | 问题 | 修复建议 |
|---|------|---------|
| M1 | AppleScript 命令行密码泄露 | 用 NSAppleScript 或 stdin 管道 |
| M2 | 用户事件脚本无沙箱 | 执行前验证代码签名 |
| M3 | /tmp 调试日志符号链接攻击 | 改用 ~/Library/Logs/FUnlock/ |
| M4 | /tmp 更新目录符号链接风险 | 用 FileManager.temporaryDirectory |
| M5 | 权限撤销后无运行时监控 | 定期检查 AXIsProcessTrusted() |

### 性能

| # | 问题 | 优化建议 |
|---|------|---------|
| P1 | lockLog 同步写文件（每 2-8 秒） | 改为长生命周期 FileHandle 或 os.Logger |
| P2 | DecisionLogger.record() 每次拷贝 500 元素数组 | 仅在诊断 Tab 可见时发布更新 |
| P3 | SignalDataStore Timer 永久运行 | 改为按需启动 |
| P4 | StatsView 图表每秒 5 次重绘 | 降为 2-3 秒刷新 |
| P5 | readTail 全量读取文件 | 改为尾部反向读取 |

---

## 四、可以改进（Nice to have）

| # | 问题 | 来源 |
|---|------|------|
| N1 | .overview 和 .device 渲染相同视图 | 架构 |
| N2 | Device.uuid 使用隐式解包可选类型 | 代码质量 |
| N3 | iBeaconPrefix 值超出 uint16 范围 | 代码质量 |
| N4 | UNLOCK_DISABLED/LOCK_DISABLED 命名不规范 | 代码质量 |
| N5 | UserDefaults 判断模式重复 | 代码质量 |
| N6 | deviceIconName 逻辑分散 | 架构 |
| N7 | DebugLog 文件句柄每次打开不缓存 | 性能 |
| N8 | computeHeartbeatInterval 可能除零 | 代码质量 |

---

## 五、实施计划

### 阶段 1：安全与稳定性（1-2 天）

**目标：** 消除崩溃风险和安全漏洞

| 任务 | 工作量 | 优先级 |
|------|--------|--------|
| C1+C2: Device/字典线程安全保护 | 中 | P0 |
| C3: Thread.sleep 改为 usleep 或异步 | 小 | P0 |
| C4: lockLog 加锁保护 | 小 | P0 |
| C5: LEDeviceInfo 全局变量加锁 | 小 | P0 |
| M3+M4: /tmp 日志改为 ~/Library/Logs/ | 小 | P1 |
| H2: 更新机制加代码签名验证 | 中 | P1 |
| M1: AppleScript 密码传递改为 stdin | 小 | P1 |

### 阶段 2：测试补全（2-3 天）

**目标：** 覆盖关键路径，防止回归

| 任务 | 工作量 | 优先级 |
|------|--------|--------|
| T1: WiFiMonitor 测试 | 中 | P1 |
| T2: RingBuffer 测试 | 小 | P1 |
| T4: onDeviceLeft() 测试 | 小 | P1 |
| T5: SystemInteractionService 测试（mock） | 大 | P2 |
| T3: BLE 连接回调测试 | 中 | P2 |
| T6: SignalDataStore 测试 | 小 | P2 |

### 阶段 3：架构优化（3-5 天）

**目标：** 降低复杂度，提高可维护性

| 任务 | 工作量 | 优先级 |
|------|--------|--------|
| A1: 拆分 FUnManager.swift | 大 | P2 |
| A2: 统一状态管理系统 | 中 | P2 |
| A3: 创建 AppCoordinator | 中 | P3 |
| I8: 通知文案国际化 | 小 | P3 |

### 阶段 4：性能优化（1-2 天）

**目标：** 减少不必要的资源消耗

| 任务 | 工作量 | 优先级 |
|------|--------|--------|
| P1: lockLog 改为 os.Logger | 小 | P2 |
| P2: DecisionLogger 按需发布更新 | 小 | P3 |
| P3: SignalDataStore Timer 按需启动 | 小 | P3 |
| P4: StatsView 图表降频 | 小 | P3 |
| I4: UserDefaults 缓存 | 小 | P3 |

---

## 六、架构亮点（已有的良好设计）

1. **SystemInteractionService 三级降级** — CGEvent → HID → AppleScript，优雅降级
2. **DecisionLogger 同因合并** — 3 秒窗口内相同事件只记录一次，减少噪音
3. **FUnlockStateMachine 防抖 + 降级** — 连续失败自动降级，防止密码风暴
4. **Keychain 安全级别** — kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly，正确选择
5. **密码不写日志** — 所有日志路径只记录字符数，不记录密码内容
6. **信号处理管道** — Kalman + EWLR + IQR 异常检测，工程化设计
7. **环形缓冲** — 内存可控（~100KB），无泄漏风险

---

## 七、BLE 安全补充说明

H1（BLE 身份验证缺失）是该应用的**根本性架构限制**，修复需要：
- 手机端配合（需要开发 iOS companion app）
- BLE 配对密钥协商
- 应用层加密质询-响应

这是一个**长期改进方向**，短期内可通过以下方式缓解：
- 增加解锁成功后的二次确认（如 Touch ID）
- 记录解锁时的 RSSI 指纹，异常时触发降级
- 添加"已知环境"白名单（Wi-Fi SSID）

---

## 八、决策点（需要你确认）

1. **H1 BLE 安全**：是否投入开发 iOS companion app 来实现加密质询？
2. **A1 架构拆分**：是否现在拆分 FUnManager，还是等功能稳定后再重构？
3. **H2 更新签名**：是否现在就加代码签名验证，还是等发布正式版时一起做？
4. **阶段优先级**：是否按 阶段1→2→3→4 顺序执行，还是有其他优先考虑？
