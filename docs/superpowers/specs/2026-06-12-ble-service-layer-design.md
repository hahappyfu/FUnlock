# BLEUnlock 蓝牙服务层重构设计

**日期**：2026-06-12
**版本**：1.0
**状态**：设计阶段

---

## 1. 概述

### 1.1 项目背景

BLEUnlock 是一个 macOS 菜单栏应用，通过 BLE 蓝牙信号强度自动锁屏/解锁 Mac。当前架构存在以下问题：

- AppDelegate.swift 职责过重（UI + 业务逻辑 + 系统交互混杂）
- 蓝牙状态管理与 UI 耦合紧密
- 缺少清晰的数据层/服务层分离
- 难以进行单元测试

### 1.2 重构目标

**主要目标**：
- 将蓝牙设备管理从 AppDelegate 解耦到独立的 BluetoothManager
- 使用 Combine 实现响应式数据流
- 使用 Swift Concurrency 管理异步操作
- 使用 Result 类型进行错误处理
- 渐进式迁移，确保功能不中断

**成功标准**：
- AppDelegate 不再直接调用 BLE 类
- BluetoothManager 通过 @Published 属性提供数据
- 单元测试覆盖核心逻辑
- 所有现有功能正常工作

---

## 2. 架构设计

### 2.1 整体架构

```
┌─────────────────────────────────────────┐
│  AppDelegate (UI Layer)                 │
│  - 菜单栏管理                           │
│  - 用户交互                             │
│  - 状态显示                             │
└──────────────┬──────────────────────────┘
               │ Combine Publishers
┌──────────────▼──────────────────────────┐
│  BluetoothManager (Service Layer)       │
│  - 设备扫描管理                         │
│  - RSSI 监控                            │
│  - 连接状态管理                         │
│  - @Published 属性                      │
└──────────────┬──────────────────────────┘
               │ Delegate / Callbacks
┌──────────────▼──────────────────────────┐
│  BLE (Core Layer) - 保持不变            │
│  - CoreBluetooth 封装                   │
│  - 底层蓝牙操作                         │
└─────────────────────────────────────────┘
```

### 2.2 分层职责

**UI Layer (AppDelegate)**：
- 管理菜单栏和状态栏图标
- 订阅 BluetoothManager 的 @Published 属性
- 处理用户交互事件
- 执行锁屏/解锁操作

**Service Layer (BluetoothManager)**：
- 管理设备扫描生命周期
- 封装 RSSI 监控和判断逻辑
- 提供响应式数据流（Combine）
- 线程安全的状态管理

**Core Layer (BLE)**：
- 封装 CoreBluetooth 底层操作
- 处理蓝牙设备连接/断开
- 读取 RSSI 和设备信息
- **保持不变**，降低重构风险

---

## 3. 详细设计

### 3.1 BluetoothManager 接口

```swift
// BluetoothManager.swift

import Combine
import Foundation

/// 蓝牙设备状态
enum BluetoothDeviceState {
    case disconnected
    case scanning
    case connecting
    case connected
    case monitoring
}

/// 蓝牙管理器错误
enum BLEError: Error {
    case bluetoothUnavailable
    case deviceNotFound
    case connectionFailed
    case rssiReadFailed
}

/// 蓝牙管理器
@MainActor
class BluetoothManager: ObservableObject {
    // MARK: - Published Properties（UI 可直接订阅）

    /// 当前监控的设备
    @Published var monitoredDevice: Device?

    /// 扫描到的设备列表
    @Published var discoveredDevices: [Device] = []

    /// 设备连接状态
    @Published var deviceState: BluetoothDeviceState = .disconnected

    /// 当前 RSSI 值
    @Published var currentRSSI: Int = -100

    /// 设备是否在场（用于锁屏判断）
    @Published var isDevicePresent: Bool = false

    /// 蓝牙是否可用
    @Published var isBluetoothAvailable: Bool = false

    // MARK: - Private Properties

    private let ble: BLE
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    init(ble: BLE = BLE()) {
        self.ble = ble
        setupBLECallbacks()
    }

    // MARK: - Public Methods

    /// 开始扫描设备
    func startScanning() -> Result<Void, BLEError> {
        guard isBluetoothAvailable else {
            return .failure(.bluetoothUnavailable)
        }
        ble.startScanning()
        deviceState = .scanning
        return .success(())
    }

    /// 停止扫描
    func stopScanning() {
        ble.stopScanning()
        deviceState = .disconnected
    }

    /// 选择监控设备
    func selectDevice(_ device: Device) -> Result<Void, BLEError> {
        ble.startMonitor(uuid: device.uuid)
        monitoredDevice = device
        deviceState = .monitoring
        return .success(())
    }

    /// 取消监控
    func deselectDevice() {
        ble.stopMonitor()
        monitoredDevice = nil
        deviceState = .disconnected
    }

    /// 设置 RSSI 阈值
    func setRSSIThresholds(lock: Int, unlock: Int) {
        ble.lockRSSI = lock
        ble.unlockRSSI = unlock
    }

    // MARK: - Private Methods

    private func setupBLECallbacks() {
        // 设置 BLE 回调，更新 @Published 属性
        ble.delegate = self
    }
}

// MARK: - BLEDelegate

extension BluetoothManager: BLEDelegate {
    func newDevice(_ device: Device) {
        discoveredDevices.append(device)
    }

    func updateDevice(_ device: Device) {
        if let index = discoveredDevices.firstIndex(where: { $0.uuid == device.uuid }) {
            discoveredDevices[index] = device
        }
    }

    func removeDevice(_ device: Device) {
        discoveredDevices.removeAll(where: { $0.uuid == device.uuid })
    }

    func updateRSSI(_ rssi: Int, passive: Bool) {
        currentRSSI = rssi
    }

    func updatePresence(_ present: Bool) {
        isDevicePresent = present
    }

    func bluetoothPowerWarn() {
        isBluetoothAvailable = false
    }
}
```

### 3.2 AppDelegate 订阅

```swift
// AppDelegate.swift 中的订阅逻辑

class AppDelegate: NSObject, NSApplicationDelegate {
    @Published var bluetoothManager: BluetoothManager
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 订阅设备状态变化
        bluetoothManager.$isDevicePresent
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isPresent in
                if isPresent {
                    self?.tryUnlockScreen()
                } else {
                    self?.lockScreen()
                }
            }
            .store(in: &cancellables)

        // 订阅 RSSI 变化（用于 UI 显示）
        bluetoothManager.$currentRSSI
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rssi in
                self?.updateRSSIDisplay(rssi)
            }
            .store(in: &cancellables)

        // 订阅设备列表变化
        bluetoothManager.$discoveredDevices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] devices in
                self?.updateDeviceMenu(devices)
            }
            .store(in: &cancellables)
    }
}
```

### 3.3 线程安全策略

- **@MainActor** — BluetoothManager 的所有 @Published 属性更新在主线程
- **BLE 回调** — 使用 `DispatchQueue.main.async` 确保回调在主线程
- **Timer 管理** — 集中在 BluetoothManager，避免分散在多处

---

## 4. 迁移计划

### 4.1 阶段划分

**阶段 1：创建 BluetoothManager 骨架**（1-2 天）
- 创建 BluetoothManager.swift
- 实现基础接口（startScanning, stopScanning, selectDevice）
- 保持 BLE.swift 不变
- AppDelegate 暂不修改

**阶段 2：迁移设备扫描**（1-2 天）
- BluetoothManager 接管设备扫描逻辑
- AppDelegate 通过 BluetoothManager 获取设备列表
- 移除 AppDelegate 中的扫描代码
- **验证点**：设备扫描功能正常

**阶段 3：迁移 RSSI 监控**（2-3 天）
- BluetoothManager 接管 RSSI 读取和判断逻辑
- AppDelegate 订阅 @Published currentRSSI
- 移除 AppDelegate 中的 RSSI 处理代码
- **验证点**：RSSI 显示和锁屏判断正常

**阶段 4：迁移锁屏/解锁决策**（2-3 天）
- BluetoothManager 提供 isDevicePresent 属性
- AppDelegate 订阅 isDevicePresent 触发锁屏/解锁
- 移除 AppDelegate 中的 updatePresence 逻辑
- **验证点**：自动锁屏/解锁功能正常

**阶段 5：清理和测试**（1-2 天）
- 移除 AppDelegate 中残留的蓝牙代码
- 编写 BluetoothManager 单元测试
- 代码审查和重构
- **验证点**：所有测试通过，功能完整

**阶段 6：文档和提交**（1 天）
- 更新代码注释
- 编写迁移文档
- 提交 PR

### 4.2 风险控制

- **每个阶段独立验证** — 确保功能不中断
- **保留旧代码** — 新旧代码并存，通过 feature flag 切换
- **单元测试** — 核心逻辑必须有测试覆盖
- **代码审查** — 每个阶段完成后进行审查

---

## 5. 测试策略

### 5.1 单元测试

**测试范围**：
- BluetoothManager 的公共方法
- RSSI 判断逻辑
- 设备状态管理
- 错误处理

**Mock 策略**：
- MockBLE 类模拟蓝牙设备
- MockBLEDelegate 验证回调
- MockDevice 提供测试数据

**测试用例示例**：
```swift
func testDevicePresenceDetection() {
    let mockBLE = MockBLE()
    let manager = BluetoothManager(ble: mockBLE)

    // 模拟设备进入范围
    mockBLE.simulateRSSI(-50)

    XCTAssertTrue(manager.isDevicePresent)
    XCTAssertEqual(manager.currentRSSI, -50)
}
```

### 5.2 集成测试

**测试范围**：
- 真实蓝牙设备交互
- 系统事件响应（睡眠/唤醒）
- 长时间运行稳定性

---

## 6. 附录

### 6.1 相关文件

- `BLEUnlock/BLE.swift` — 蓝牙核心模块（保持不变）
- `BLEUnlock/AppDelegate.swift` — 应用主控制器（需重构）
- `BLEUnlock/BLEUnlock-Bridging-Header.h` — 桥接头文件

### 6.2 参考资料

- [Apple Combine Documentation](https://developer.apple.com/documentation/combine)
- [Swift Concurrency Guide](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html)
- [CoreBluetooth Programming Guide](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/AboutCoreBluetooth/Introduction.html)

---

**设计完成日期**：2026-06-12
**设计者**：Claude
**审核者**：待定
