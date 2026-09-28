# FUnlock 真机行为验证清单(Phase 5)

> 审计修复后的实机回归清单。按 [日志驱动迭代规则](../dev-rules/log-driven-iteration.md) 执行:每项验证前清空/记录日志位点,验证后按日志样本量与内容判定,不以单次主观感受下结论。
> 对应修复:2026-09-27/28 的 Phase 1(P0 五项)与 Phase 2(P1 五项)。

## 准备

1. 用最新代码构建 Release 包并安装(标准流程:先删旧版 → pkill 确认退出 → 安装 → 启动)
2. 打开诊断页,记录当前日志位点;日志目录:`~/Library/Logs/FUnlock/`
3. 准备:已绑定的 Apple Watch/iPhone、可锁屏环境、系统设置改密能力(备用测试机密码)

## A. 核心解锁链(Phase 1 修复直接对应)

| # | 场景 | 步骤 | 预期 | 判定日志 |
|---|---|---|---|---|
| A1 | 正常靠近解锁 | 离 Mac >5m 锁屏 → 佩戴设备走近 | 解锁成功,无密码错误告警 | decisions.log: unlockSuccess;无 degraded |
| A2 | 快轮询重入不掐验证(P0-4) | 连续走近→远离→走近 3 轮 | 每轮解锁正常,`consecutiveUnlockAttempts` 不累积到 3,永不降级 | decisions.log 无 stateMachineBlocked 后的 unlockFailed 连击 |
| A3 | 手动唤醒自动解锁(P0-3) | 设备在场,锁屏 → **手动按键盘/动鼠标**点亮屏幕 | 0.3s 后自动注入解锁(修复前 100% 失效) | debug.log: unlockTask STARTED → WOKE → tryUnlock |
| A4 | 程序自唤醒不误触发干预 | 设备在场锁屏 → 等待 FUnlock 自己唤醒屏幕的路径 | 解锁正常,干预语义不误杀解锁任务 | 同上 |
| A5 | 离开锁屏 | 佩戴设备离开 >30s | 自动锁屏,无重复锁屏事件 | events.log 单条 locked |
| A6 | 信号回升不误锁(P1-3) | 在锁定计时器窗口内回到电脑前操作 | 不锁屏;日志出现 "timer fired but signal recovered/input active" | debug.log [LOCK] |
| A7 | 预唤醒即时性(Phase 6 EMA 重构) | 开启 wakeOnProximity → 锁屏并等显示器休眠 → 从 5m 外匀速走近 | 到达解锁距离前 1-2m 屏幕点亮;无 10-20s 迟滞;设备离场后(失联 nil 派发)**不**为无人在场误点亮 | debug.log `[SM] pre-wake triggered` 时间戳与 RSSI 曲线 |

## B. 安全与误报(Phase 2 修复直接对应)

| # | 场景 | 步骤 | 预期 | 判定 |
|---|---|---|---|---|
| B1 | 合法解锁不误报入侵(P1-2) | A1 成功后静置 5s | **无** intruded 脚本触发、无虚假入侵审计记录 | events.log 无 intruded |
| B2 | 手动解锁仍报入侵(保留语义) | 设备不在场,手动输密码解锁 | intruded 正常触发(该告警应保留) | events.log 有 intruded |
| B3 | 改密-未锁屏确认(P1-1) | 系统设置修改密码(屏幕未锁) | FUnlock 立即弹确认窗;确认后引导重输;拒绝则保留旧密码 | debug.log: password changed, asking user confirmation |
| B4 | 改密-锁屏延迟弹窗(P1-1) | 锁屏状态下由他机/脚本触发改密广播 | 不弹窗、主线程不死锁;**下次解锁后**补弹确认窗 | debug.log: session locked, deferring → onUnlock 消费 |
| B5 | 注入期间 UI 不冻结(P1-4) | A3 触发瞬间观察菜单栏/窗口响应 | 无彩虹球、图标不卡顿(修复前主线程冻结 ~0.5s) | 主观 + 无 ANR 日志 |

## C. 稳定性抽查

| # | 场景 | 步骤 | 预期 |
|---|---|---|---|
| C1 | 睡眠唤醒循环 | 合盖睡眠 → 开盖,重复 5 次 | 每次唤醒扫描恢复、无幽灵设备、无扫描泄漏 |
| C2 | WiFi 暂停 | 回到家庭 WiFi,验证暂停/恢复逻辑 | 按配置暂停解锁;离开后恢复 |
| C3 | 多设备切换 | 绑定第二台设备后轮流靠近 | 监控目标正确切换,无 UUID 撕裂导致的崩溃 |
| C4 | 长时间驻留 | 设备在场静置 1h | 心跳日志 60s 一条(不膨胀),能耗正常(活动监视器对比) |
| C5 | 更新链 | 检查更新流程(若有测试通道) | 下载→校验→确认弹窗→安装,无静默覆盖 |

## 判定标准

- 每项至少 3 次重复采样(日志驱动:样本量不足不判定)
- A2/B1/B3/B4 为本轮修复的核心验证项,任何异常立即回滚:`tar xzf /tmp/funlock-snapshot-pre-phase3.tar.gz`
- 全部通过 → 构建版本号自增提交

## 遗留待决(不在本轮,见 2026-09-28-fix-report)

kSecUseDataProtectionKeychain(存量密码迁移)、SHA256 更新清单(需服务端格式)、RSSI 颜色双标准统一(需定标准)、BLE 中继边界(产品设计)、BLEScanner 单测(需协议抽象)、NSAlert 收敛(11 处重构)、ConfigKey 枚举化(23 key × 11 文件)、图表假深谷(改渲染需定视觉方案)、smoothedRSSI 双驱动(有行为影响)。
