# FUnlock V3 安全加固版设计规格

**版本：** 2.6.0
**日期：** 2026-07-31
**状态：** 已批准

---

## 1. 概述

FUnlock V3 安全加固版是一个重大升级，旨在解决当前 50% 的解锁成功率问题，并提升应用的安全性和稳定性。

### 1.1 核心目标

- **提升解锁成功率**：从 50% 提升到 95%+
- **提升响应速度**：解锁响应时间 < 1 秒
- **增强安全性**：密码存储和传输安全加固
- **提升稳定性**：连续失败降级机制

### 1.2 主要改动

1. Actor 并发改造
2. 注入前奏（Shift 键 + 300ms 延迟）
3. 双保险验证（通知 + CGSession 兜底）
4. 防抖冷却锁
5. 预备唤醒
6. 连续失败降级
7. Keychain 安全收紧

---

## 2. 架构设计

### 2.1 整体架构

```
┌─────────────────────────────────────────────────────────────┐
│                    FUnlock V3 架构                           │
├─────────────────────────────────────────────────────────────┤
│  UI Layer (MenuDashboardView)                               │
├─────────────────────────────────────────────────────────────┤
│  State Machine Layer (FUnlockStateMachine Actor)            │
├─────────────────────────────────────────────────────────────┤
│  Service Layer                                              │
│  ├── BLE Service (FUn)                                      │
│  ├── Screen Wake Service (IOPMAssertion)                    │
│  ├── Password Injection Service (CGEvent + AppleScript)     │
│  ├── Keychain Service (SecurityService)                     │
│  └── Notification Service (Local Notifications)             │
├─────────────────────────────────────────────────────────────┤
│  System Layer (IOKit, CoreGraphics, NSWorkspace)            │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 核心组件

#### FUnlockStateMachine Actor

```swift
actor FUnlockStateMachine {
    // 状态定义
    enum State {
        case active              // 正常使用中
        case displayAsleep       // 屏幕息屏，但系统未休眠
        case preWaking           // 触发预备唤醒
        case readyToUnlock       // 屏幕已亮，等待信号达到阈值
        case unlocking           // 正在注入密码
        case cooldown            // 冷却防抖中
        case degraded            // 连续失败降级中
    }
    
    // 核心属性
    private(set) var currentState: State = .active
    private var lastUnlockAttempt: Date = .distantPast
    private var consecutiveFailures: Int = 0
    private var activeTask: Task<Void, Never>?
    
    // 防抖配置
    private let unlockCooldown: TimeInterval = 5.0
    private let failureCooldown: TimeInterval = 10.0
    private let maxConsecutiveFailures: Int = 3
    
    // 状态转换方法
    func transition(to newState: State) {
        // 合法性校验
        guard canTransition(from: currentState, to: newState) else {
            return
        }
        currentState = newState
    }
    
    // 解锁尝试
    func attemptUnlock() -> Bool {
        let now = Date()
        
        // 防抖检查
        guard now.timeIntervalSince(lastUnlockAttempt) > unlockCooldown else {
            return false
        }
        
        // 降级检查
        guard consecutiveFailures < maxConsecutiveFailures else {
            transition(to: .degraded)
            return false
        }
        
        lastUnlockAttempt = now
        transition(to: .unlocking)
        return true
    }
}
```

---

## 3. 功能设计

### 3.1 Actor 并发改造

**目标：** 用 Actor 替代 NSLock，确保线程安全

**改动：**
- 创建 `FUnlockStateMachine Actor`
- 将所有状态变量移入 Actor
- 使用 `await` 访问 Actor 状态
- 移除所有 `NSLock` 代码

**文件：**
- 新建：`FUnlock/FUnlockStateMachine.swift`
- 修改：`FUnlock/FUnManager.swift`

### 3.2 注入前奏

**目标：** 解决"密码射入虚空"问题

**改动：**
- 密码注入前发送 Shift 键
- 等待 300ms 让 UI 渲染
- 然后再发送密码

**流程：**
```swift
func injectPasswordWithPrelude(_ password: String) async {
    // 1. 发送 Shift 键
    sendShiftKey()
    
    // 2. 等待 300ms
    try? await Task.sleep(nanoseconds: 300_000_000)
    
    // 3. 检查是否被取消
    guard !Task.isCancelled else { return }
    
    // 4. 发送密码
    sendPassword(password)
    
    // 5. 发送 Return 键
    sendReturnKey()
}
```

**文件：**
- 修改：`FUnlock/SystemInteractionService.swift`

### 3.3 双保险验证

**目标：** 提升解锁验证的可靠性

**改动：**
- 主通道：监听 `com.apple.screenIsUnlocked` 分布式通知
- 兜底：3 秒后使用 `CGSessionCopyCurrentDictionary` 查询
- 超时处理：3 秒内未收到通知则使用兜底方案

**代码（Swift 结构化并发正确实现）：**
```swift
func verifyUnlock() async -> Bool {
    return await withTaskGroup(of: Bool.self) { group in
        // 添加主通道：等待通知
        group.addTask {
            await self.waitForNotification("com.apple.screenIsUnlocked")
            return true
        }
        
        // 添加兜底通道：3秒超时
        group.addTask {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return self.checkScreenUnlocked() // 超时后直接调用兜底查询
        }
        
        // 获取最先完成的任务结果，然后立即取消另一个未完成的任务
        let result = await group.next() ?? false
        group.cancelAll() 
        return result
    }
}
```

**注意：** Swift 标准库没有 `Task.race` API，必须使用 `withTaskGroup` 实现竞速/超时逻辑。

**文件：**
- 修改：`FUnlock/FUnManager.swift`

### 3.4 防抖冷却锁

**目标：** 防止频繁触发解锁

**改动：**
- 解锁成功后冷却 5 秒
- 解锁失败后冷却 10 秒
- 冷却期间忽略 BLE 信号

**文件：**
- 修改：`FUnlock/FUnlockStateMachine.swift`

### 3.5 预备唤醒

**目标：** 提前唤醒屏幕，减少解锁延迟

**改动：**
- 信号达到 -60dBm 时唤醒屏幕
- 等待 1-2 秒让 UI 渲染
- 信号达到 -50dBm 时进行密码注入

**信号平滑：**
```swift
func smoothedRSSI(_ rawRSSI: Double) -> Double {
    // 使用 EMA（指数移动平均）过滤毛刺
    let alpha = 0.3
    return alpha * rawRSSI + (1 - alpha) * previousRSSI
}
```

**文件：**
- 修改：`FUnlock/FUn.swift`
- 修改：`FUnlock/SystemInteractionService.swift`

### 3.6 连续失败降级

**目标：** 避免频繁错误输入导致账户锁定

**改动：**
- 连续失败 3 次后停止自动解锁
- 发送本地通知提醒用户
- 用户确认后重置失败计数

**代码：**
```swift
func handleUnlockFailure() {
    consecutiveFailures += 1
    
    if consecutiveFailures >= maxConsecutiveFailures {
        // 降级
        transition(to: .degraded)
        
        // 发送通知
        sendLocalNotification(
            title: "FUnlock 自动解锁失败",
            body: "您是否修改了 Mac 登录密码？点击重新配置。"
        )
    }
}
```

**文件：**
- 修改：`FUnlock/FUnlockStateMachine.swift`
- 修改：`FUnlock/AppDelegate.swift`

### 3.7 Keychain 安全收紧

**目标：** 提升密码存储安全性

**改动：**
- 设置 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
- 重启后必须手动解锁一次
- 密码修改检测
- **冷启动错误码捕获**

**代码：**
```swift
func savePassword(_ password: String) {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "FUnlock",
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        kSecValueData as String: password.data(using: .utf8)!
    ]
    
    SecItemAdd(query as CFDictionary, nil)
}

func fetchPassword() -> String? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "FUnlock",
        kSecReturnData as String: true
    ]
    
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    
    // 冷启动错误码捕获
    if status == errSecInteractionNotAllowed {
        // Mac 刚重启，用户还没进行第一次手动解锁
        // 保持静默，不增加失败计数，不触发降级
        // 等待用户完成第一次手动解锁
        return nil
    }
    
    guard status == errSecSuccess, let data = result as? Data else {
        return nil
    }
    
    return String(data: data, encoding: .utf8)
}
```

**冷启动处理策略：**
- 当 Keychain 返回 `errSecInteractionNotAllowed` 时，表示 Mac 刚重启，用户还没进行第一次手动解锁
- 此时 FUnlock 应保持静默，不增加"连续失败计数"，不触发降级通知
- 静默等待用户完成第一次手动解锁后，再恢复正常功能

**文件：**
- 修改：`FUnlock/SecurityService.swift`

---

## 4. 状态机设计

### 4.1 状态定义

```swift
enum FUnlockState {
    case active              // 正常使用中
    case displayAsleep       // 屏幕息屏，但系统未休眠
    case preWaking           // 触发预备唤醒
    case readyToUnlock       // 屏幕已亮，等待信号达到阈值
    case unlocking           // 正在注入密码
    case cooldown            // 冷却防抖中
    case degraded            // 连续失败降级中
}
```

### 4.2 状态转换图

```
                    ┌─────────────┐
                    │   active    │
                    └──────┬──────┘
                           │
                           ▼
                    ┌─────────────┐
                    │displayAsleep│
                    └──────┬──────┘
                           │
                           ▼
                    ┌─────────────┐
                    │  preWaking  │
                    └──────┬──────┘
                           │
                           ▼
                    ┌─────────────┐
                    │readyToUnlock│
                    └──────┬──────┘
                           │
                           ▼
                    ┌─────────────┐
                    │  unlocking  │
                    └──────┬──────┘
                           │
                           ▼
                    ┌─────────────┐
                    │  cooldown   │
                    └──────┬──────┘
                           │
                           ▼
                    ┌─────────────┐
                    │  degraded   │
                    └─────────────┘
```

### 4.3 状态转换规则

| 当前状态 | 触发条件 | 目标状态 | 动作 |
|---------|---------|---------|------|
| active | 屏幕息屏 | displayAsleep | 启动 BLE 扫描 |
| displayAsleep | RSSI >= -60dBm | preWaking | 唤醒屏幕 |
| preWaking | 屏幕已亮 | readyToUnlock | 等待信号 |
| readyToUnlock | RSSI >= -50dBm | unlocking | 注入密码 |
| unlocking | 解锁成功 | active | 重置计数器 |
| unlocking | 解锁失败 | cooldown | 增加失败计数 |
| cooldown | 冷却时间结束 | active | 重置状态 |
| any | 连续失败 3 次 | degraded | 停止自动解锁 |
| **preWaking / readyToUnlock / unlocking** | **用户主动干预（键盘/鼠标/触控板）** | **active** | **立即取消 activeTask，紧急刹车** |

### 4.4 用户主动干预处理

**场景：** 用户在 FUnlock 执行解锁过程中主动操作电脑（敲键盘、摸触控板）

**风险：** 密码可能被注入到用户正在使用的应用中（如微信聊天框）

**解决方案：**
```swift
// 监听用户主动干预
NotificationCenter.default.addObserver(
    forName: NSWorkspace.screensDidWakeNotification,
    object: nil,
    queue: .main
) { [weak self] _ in
    // 如果不是由 FUnlock 主动触发的唤醒
    guard let self, self.currentState != .active else { return }
    
    // 强制切回 active 状态
    self.transition(to: .active)
    
    // 紧急刹车，取消所有进行中的任务
    self.activeTask?.cancel()
    
    // 重置状态
    self.consecutiveFailures = 0
}
```

**状态转换规则：**
- 触发条件：监听到 `NSWorkspace.screensDidWakeNotification`（非 FUnlock 主动触发），或检测到键盘/鼠标原生交互
- 目标状态：强制切回 `active`
- 动作：立即调用 `activeTask?.cancel()`，销毁后续的密码注入

---

## 5. 错误处理

### 5.1 错误类型

| 错误类型 | 处理方式 | 用户提示 |
|---------|---------|---------|
| BLE 连接失败 | 静默重试 | 无 |
| 屏幕唤醒失败 | 静默重试 | 无 |
| 密码注入失败 | 增加失败计数 | 无 |
| 连续失败 3 次 | 降级 | 通知用户 |
| Keychain 访问失败 | 降级 | 通知用户 |

### 5.2 降级策略

**自动降级：**
- 连续失败 3 次
- 停止自动解锁
- 发送本地通知

**手动恢复：**
- 用户点击通知
- 打开设置页面
- 重新输入密码
- 重置失败计数

---

## 6. 测试策略

### 6.1 单元测试

- Actor 状态转换测试
- 防抖冷却逻辑测试
- 信号平滑算法测试
- 连续失败降级测试

### 6.2 集成测试

- BLE 信号 → 预备唤醒 → 密码注入 完整流程
- 电源状态变化 → 扫描控制
- 密码修改 → 降级 → 恢复

### 6.3 安全测试

- Keychain 访问权限测试
- 密码存储加密测试
- 并发访问安全性测试

---

## 7. 性能基准

| 指标 | 目标 | 测试方法 |
|------|------|---------|
| 解锁响应时间 | < 1 秒 | 测量从信号达标到解锁完成的时间 |
| 解锁成功率 | > 95% | 统计 100 次解锁尝试的成功次数 |
| 内存使用 | < 100 MB | 监控应用内存占用 |
| CPU 使用 | < 5% | 监控应用 CPU 占用 |

---

## 8. 部署策略

### 8.1 本地测试

- 每完成一个改动就编译测试
- 确保功能正确后再继续下一个改动
- 使用详细日志记录问题

### 8.2 代码审查

- 每完成一个改动就进行子代理审查
- 审查重点：安全性
- 使用 SwiftLint 检查代码风格

### 8.3 发布

- 本地构建先测试
- 稳定后再 push 到 GitHub
- 使用 GitHub Actions 自动构建 Release

---

## 9. 文档更新

### 9.1 README

- 更新版本号
- 更新功能说明
- 更新安装说明

### 9.2 开发文档

- 更新架构设计
- 更新状态机说明
- 更新 API 文档

---

## 10. 风险评估

| 风险 | 影响 | 缓解措施 |
|------|------|---------|
| Actor 改造引入回归 | 高 | 分阶段改造，每步测试 |
| 预备唤醒误触发 | 中 | 信号平滑 + 防抖 |
| 连续失败降级误触发 | 中 | 适当的阈值和恢复机制 |
| Keychain 权限问题 | 高 | 充分测试权限配置 |

---

## 11. 成功标准

- [ ] 解锁成功率 > 95%
- [ ] 解锁响应时间 < 1 秒
- [ ] 内存使用 < 100 MB
- [ ] CPU 使用 < 5%
- [ ] 所有单元测试通过
- [ ] 所有集成测试通过
- [ ] 安全测试通过
- [ ] 代码覆盖率 > 80%
- [ ] SwiftLint 检查通过
- [ ] 本地测试稳定
- [ ] 文档更新完成
