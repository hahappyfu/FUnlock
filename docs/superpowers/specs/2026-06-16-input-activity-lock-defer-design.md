# BLE 信号波动防误锁设计

## 背景

FUnlock 通过 BLE 信号强度判断用户是否在电脑旁。当信号低于 `lockRSSI` 阈值持续 5 秒（`proximityTimeout`）后触发锁定。但 BLE 信号不稳定，用户打字时信号可能瞬间跌落导致误锁。

## 目标

检测到键盘/触控板输入活动时，暂缓锁定。用户在用电脑就不该被锁。

## 方案

IOKit HID 事件监听（方案 A）。不需要辅助功能权限，系统级 API，适合 menu bar app。

## 组件设计

### 1. InputActivityMonitor（新建文件）

文件：`FUnlock/InputActivityMonitor.swift`

```swift
class InputActivityMonitor {
    private var hidManager: IOHIDManager?
    private(set) var lastInputTime: Date = Date.distantPast
    var activityWindow: TimeInterval = 30  // 30 秒活动窗口
    
    var isActive: Bool {
        Date().timeIntervalSince(lastInputTime) < activityWindow
    }
    
    func start()  // 创建 HID Manager，匹配键盘+触控板，注册回调
    func stop()   // 关闭 HID Manager
}
```

- 匹配设备：键盘 (UsagePage=0x01, Usage=0x06)、触控板 (UsagePage=0x0D, Usage=0x04~0x09)
- 回调中更新 `lastInputTime = Date()`
- `isActive` 判断最近 30 秒内是否有输入

### 2. 锁定流程改动

文件：`FUnlock/FUn.swift`

当前 `proximityTimer` 回调：
```swift
// 直接锁定
presence = false
delegate?.updatePresence(presence: false, reason: "away")
```

改为：
```swift
if inputMonitor.isActive {
    // 用户在用电脑，重启定时器
    proximityTimer = Timer(timeInterval: proximityTimeout, ...)
    RunLoop.main.add(proximityTimer!, forMode: .common)
} else {
    // 确认离开，锁定
    presence = false
    delegate?.updatePresence(presence: false, reason: "away")
}
```

### 3. Manager 集成

文件：`FUnlock/FUnManager.swift`
- 持有 `inputActivityMonitor: InputActivityMonitor` 引用
- 启动时 `inputMonitor.start()`
- 退出时 `inputMonitor.stop()`

文件：`FUnlock/FUn.swift`
- `FUn` 增加 `weak var inputMonitor: InputActivityMonitor?` 引用
- proximityTimer 回调中通过 `inputMonitor?.isActive` 判断

### 4. 设置 UI

文件：`FUnlock/MenuDashboardView.swift`

toggleSection 新增：
```
 输入活动时暂缓锁定  [开/关]
```

- `@AppStorage("lockOnIdle")` 默认 `true`
- 关闭时跳过输入活动检查，恢复原有行为

### 5. AppDelegate 初始化

文件：`FUnlock/AppDelegate.swift`

```swift
let inputMonitor = InputActivityMonitor()
// 传给 manager 和 fun
manager.inputMonitor = inputMonitor
fun.inputMonitor = inputMonitor
inputMonitor.start()
```

## 文件改动清单

| 文件 | 改动类型 | 说明 |
|------|---------|------|
| `FUnlock/InputActivityMonitor.swift` | 新建 | IOKit HID 输入监听 |
| `FUnlock/FUn.swift` | 修改 | proximityTimer 增加活动检查 |
| `FUnlock/FUnManager.swift` | 修改 | 持有 InputActivityMonitor 引用 |
| `FUnlock/MenuDashboardView.swift` | 修改 | 新增设置开关 |
| `FUnlock/AppDelegate.swift` | 修改 | 初始化 InputActivityMonitor |

## 验证方式

1. 启动 FUnlock，绑定设备，开启自动锁定
2. 打字时观察：信号跌落不应触发锁定
3. 离开电脑 30 秒以上：应正常锁定
4. 关闭"输入活动时暂缓锁定"开关：恢复原有行为
