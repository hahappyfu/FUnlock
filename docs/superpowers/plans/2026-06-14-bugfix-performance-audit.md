# BLEUnlock Bug Fixes & Performance Optimization Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix all identified logic bugs, performance issues, and edge cases in BLEUnlock

**Architecture:** 修改现有 Swift 源文件，无新文件创建。修复集中在 `BLE.swift`（BLE 核心逻辑）和 `AppDelegate.swift`（状态管理与解锁逻辑）两个文件中。每个 Task 独立可验证。

**Tech Stack:** Swift, CoreBluetooth, Accelerate (vDSP), Cocoa

---

## File Structure

| 文件 | 职责 |
|------|------|
| `BLEUnlock/BLE.swift` | BLE 扫描、RSSI 监控、设备连接管理 |
| `BLEUnlock/AppDelegate.swift` | 菜单 UI、状态管理、解锁/锁定逻辑 |
| `BLEUnlock/LEDeviceInfo.swift` | SQLite 蓝牙设备信息查询 |

---

## Task 1: 唤醒后解锁失败 — `AppDelegate.swift`

**问题：** `updatePresence(presence: true)` 中 `wakeDisplay()` 调用后立即调用 `tryUnlockScreen()`，但 `onDisplayWake` 通知尚未到达，`displaySleep` 仍为 `true`，`tryUnlockScreen()` 的 guard 跳过。

**Files:**
- Modify: `BLEUnlock/AppDelegate.swift:219-235`

- [ ] **Step 1: 修复 `updatePresence` 中唤醒后解锁逻辑**

```swift
func updatePresence(presence: Bool, reason: String) {
    if presence {
        if ble.unlockRSSI != ble.UNLOCK_DISABLED {
            if let un = userNotification {
                NSUserNotificationCenter.default.removeDeliveredNotification(un)
                userNotification = nil
            }
            if displaySleep && !systemSleep && prefs.bool(forKey: "wakeOnProximity") {
                print("Waking display")
                wakeDisplay()
                displaySleep = false  // <-- 新增：立即标记，确保 tryUnlockScreen 不被 guard 拦截
                wakeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true, block: { _ in
                    print("Retrying waking display")
                    wakeDisplay()
                })
            }
            tryUnlockScreen()
        }
    } else {
        if (!isScreenLocked() && ble.lockRSSI != ble.LOCK_DISABLED) {
            pauseNowPlaying()
            lockOrSaveScreen()
            notifyUser(reason)
            runScript(reason)
        }
        manualLock = false
    }
}
```

- [ ] **Step 2: 验证编译通过**

Run: `xcodebuild build -project BLEUnlock.xcodeproj -scheme BLEUnlock -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add BLEUnlock/AppDelegate.swift
git commit -m "fix: set displaySleep=false immediately after wakeDisplay to ensure tryUnlockScreen runs"
```

---

## Task 2: 双禁用导致永不锁定 — `AppDelegate.swift`

**问题：** 用户可同时将 Lock RSSI 和 Unlock RSSI 设为 "Disabled"，导致 Mac 永不自动锁定。

**Files:**
- Modify: `BLEUnlock/AppDelegate.swift:492-502`（setLockRSSI 和 setUnlockRSSI）

- [ ] **Step 1: 在 `setLockRSSI` 中校验**

```swift
@objc func setLockRSSI(_ menuItem: NSMenuItem) {
    let value = menuItem.tag
    if value != ble.LOCK_DISABLED && ble.unlockRSSI == ble.UNLOCK_DISABLED {
        // 如果 Unlock 已禁用，Lock 不能再禁用（否则永不锁定）
        ble.unlockRSSI = -60  // 恢复 Unlock 为默认值
        prefs.set(-60, forKey: "unlockRSSI")
    }
    prefs.set(value, forKey: "lockRSSI")
    ble.lockRSSI = value
}
```

- [ ] **Step 2: 在 `setUnlockRSSI` 中校验**

```swift
@objc func setUnlockRSSI(_ menuItem: NSMenuItem) {
    let value = menuItem.tag
    if value == ble.UNLOCK_DISABLED && ble.lockRSSI == ble.LOCK_DISABLED {
        // 如果 Lock 已禁用，Unlock 不能再禁用（否则永不锁定）
        ble.lockRSSI = -80  // 恢复 Lock 为默认值
        prefs.set(-80, forKey: "lockRSSI")
    }
    prefs.set(value, forKey: "unlockRSSI")
    ble.unlockRSSI = value
}
```

- [ ] **Step 3: 验证编译通过**

Run: `xcodebuild build -project BLEUnlock.xcodeproj -scheme BLEUnlock -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add BLEUnlock/AppDelegate.swift
git commit -m "fix: prevent both lock/unlock RSSI from being disabled simultaneously"
```

---

## Task 3: manualLock 语义错误 — `AppDelegate.swift`

**问题：** `updatePresence(presence: false)` 分支末尾清零 `manualLock`，导致用户手动锁屏后设备走远再回来时自动解锁。

**Files:**
- Modify: `BLEUnlock/AppDelegate.swift:236-244`（updatePresence 的 else 分支）

- [ ] **Step 1: 从 auto-lock 分支移除 `manualLock = false`**

将 `updatePresence` 的 else 分支修改为：

```swift
    } else {
        if (!isScreenLocked() && ble.lockRSSI != ble.LOCK_DISABLED) {
            pauseNowPlaying()
            lockOrSaveScreen()
            notifyUser(reason)
            runScript(reason)
        }
        // 不再在此处清零 manualLock，改为在用户手动解锁时清零
    }
```

- [ ] **Step 2: 验证 `onUnlock` 中已有清零逻辑**

确认 `onUnlock` 方法（AppDelegate.swift:343）中已有 `manualLock = false`，无需重复添加。

- [ ] **Step 3: 验证编译通过**

Run: `xcodebuild build -project BLEUnlock.xcodeproj -scheme BLEUnlock -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add BLEUnlock/AppDelegate.swift
git commit -m "fix: only clear manualLock on user unlock, not on auto-lock"
```

---

## Task 4: BLE 回调阻塞主线程 — `BLE.swift`

**问题：** `CBCentralManager(delegate: self, queue: nil)` 将所有 BLE 回调放在主线程，密集 BLE 环境下阻塞 UI。

**Files:**
- Modify: `BLEUnlock/BLE.swift:118-141, 143-146, 173-185, 202-222, 280-298, 302-350, 353-366, 372-398, 401-453, 456-459`

- [ ] **Step 1: 添加 BLE 队列并修改初始化**

在 `BLE` 类中添加队列属性，并修改 `init()`：

```swift
class BLE: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    let bleQueue = DispatchQueue(label: "com.bleunlock.ble")
    // ... 其他属性不变 ...

    override init() {
        super.init()
        centralMgr = CBCentralManager(delegate: self, queue: bleQueue)
    }
}
```

- [ ] **Step 2: 在需要更新 UI 的回调中 dispatch 到主线程**

修改以下方法，在调用 delegate 前 dispatch 到主线程：

```swift
// updateMonitoredPeripheral 中的 delegate 调用
func updateMonitoredPeripheral(_ rssi: Int) {
    if rssi >= (unlockRSSI == UNLOCK_DISABLED ? lockRSSI : unlockRSSI) && !presence {
        print("Device is close")
        presence = true
        DispatchQueue.main.async {
            self.delegate?.updatePresence(presence: self.presence, reason: "close")
        }
        latestRSSIs.removeAll()
    }

    let estimatedRSSI = getEstimatedRSSI(rssi: rssi)
    DispatchQueue.main.async {
        self.delegate?.updateRSSI(rssi: estimatedRSSI, active: self.activeModeTimer != nil)
    }

    if estimatedRSSI >= (lockRSSI == LOCK_DISABLED ? unlockRSSI : lockRSSI) {
        if let timer = proximityTimer {
            timer.invalidate()
            print("Proximity timer canceled")
            proximityTimer = nil
        }
    } else if presence && proximityTimer == nil {
        proximityTimer = Timer.scheduledTimer(withTimeInterval: proximityTimeout, repeats: false, block: { _ in
            print("Device is away")
            self.presence = false
            DispatchQueue.main.async {
                self.delegate?.updatePresence(presence: self.presence, reason: "away")
            }
            self.proximityTimer = nil
        })
        RunLoop.main.add(proximityTimer!, forMode: .common)
        print("Proximity timer started")
    }
    resetSignalTimer()
}
```

```swift
// resetSignalTimer 中的 delegate 调用
func resetSignalTimer() {
    signalTimer?.invalidate()
    signalTimer = Timer.scheduledTimer(withTimeInterval: signalTimeout, repeats: false, block: { _ in
        print("Device is lost")
        DispatchQueue.main.async {
            self.delegate?.updateRSSI(rssi: nil, active: false)
        }
        if self.presence {
            self.presence = false
            DispatchQueue.main.async {
                self.delegate?.updatePresence(presence: self.presence, reason: "lost")
            }
        }
    })
    if let timer = signalTimer {
        RunLoop.main.add(timer, forMode: .common)
    }
}
```

```swift
// centralManagerDidUpdateState 中的 delegate 调用
func centralManagerDidUpdateState(_ central: CBCentralManager) {
    switch central.state {
    case .poweredOn:
        print("Bluetooth powered on")
        if activeModeTimer == nil {
            scanForPeripherals()
        }
        powerWarn = false
    case .poweredOff:
        print("Bluetooth powered off")
        presence = false
        signalTimer?.invalidate()
        signalTimer = nil
        if powerWarn {
            powerWarn = false
            DispatchQueue.main.async {
                self.delegate?.bluetoothPowerWarn()
            }
        }
    default:
        break
    }
}
```

```swift
// didDiscover 中的 delegate 调用（scanMode 分支）
func centralManager(_ central: CBCentralManager,
                    didDiscover peripheral: CBPeripheral,
                    advertisementData: [String : Any],
                    rssi RSSI: NSNumber)
{
    let rssi = RSSI.intValue > 0 ? 0 : RSSI.intValue
    // ... monitoredPeripheral 逻辑不变 ...

    if (scanMode) {
        // ... ExposureNotification 过滤不变 ...
        let dev = devices[peripheral.identifier]
        var device: Device
        if (dev == nil) {
            device = Device(uuid: peripheral.identifier)
            if (rssi >= thresholdRSSI) {
                device.peripheral = peripheral
                device.rssi = rssi
                device.advData = advertisementData["kCBAdvDataManufacturerData"] as? Data
                devices[peripheral.identifier] = device
                central.connect(peripheral, options: nil)
                DispatchQueue.main.async {
                    self.delegate?.newDevice(device: device)
                }
            }
        } else {
            device = dev!
            device.rssi = rssi
            DispatchQueue.main.async {
                self.delegate?.updateDevice(device: device)
            }
        }
        resetScanTimer(device: device)
    }
}
```

```swift
// didUpdateValueFor 中的 delegate 调用
func peripheral(_ peripheral: CBPeripheral,
                didUpdateValueFor characteristic: CBCharacteristic,
                error: Error?)
{
    if let value = characteristic.value {
        let str: String? = String(data: value, encoding: .utf8)
        if let s = str {
            if let device = devices[peripheral.identifier] {
                if characteristic.uuid == ManufacturerName {
                    device.manufacture = s
                    DispatchQueue.main.async {
                        self.delegate?.updateDevice(device: device)
                    }
                }
                if characteristic.uuid == ModelName {
                    device.model = s
                    DispatchQueue.main.async {
                        self.delegate?.updateDevice(device: device)
                    }
                }
                if device.model != nil && device.manufacture != nil && device.peripheral != monitoredPeripheral {
                    centralMgr.cancelPeripheralConnection(peripheral)
                }
            }
        }
    }
}
```

```swift
// resetScanTimer 中的 delegate 调用
func resetScanTimer(device: Device) {
    device.scanTimer?.invalidate()
    device.scanTimer = Timer.scheduledTimer(withTimeInterval: signalTimeout, repeats: false, block: { _ in
        DispatchQueue.main.async {
            self.delegate?.removeDevice(device: device)
        }
        if let p = device.peripheral {
            self.centralMgr.cancelPeripheralConnection(p)
        }
        self.devices.removeValue(forKey: device.uuid)
    })
    if let timer = device.scanTimer {
        RunLoop.main.add(timer, forMode: .common)
    }
}
```

- [ ] **Step 3: 验证编译通过**

Run: `xcodebuild build -project BLEUnlock.xcodeproj -scheme BLEUnlock -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add BLEUnlock/BLE.swift
git commit -m "perf: move BLE callbacks to dedicated queue, dispatch UI updates to main thread"
```

---

## Task 5: Device.description 磁盘 I/O 优化 — `BLE.swift`

**问题：** `Device.description` 是 computed property，每次 RSSI 更新时多次触发 SQLite/plist 磁盘读取。

**Files:**
- Modify: `BLEUnlock/BLE.swift:29-107`（Device 类）

- [ ] **Step 1: 在 `didDiscover` 中预解析设备信息**

修改 `centralManager(_:didDiscover:)` 中 scanMode 分支，在创建 Device 时立即解析：

```swift
if (dev == nil) {
    device = Device(uuid: peripheral.identifier)
    if (rssi >= thresholdRSSI) {
        device.peripheral = peripheral
        device.rssi = rssi
        device.advData = advertisementData["kCBAdvDataManufacturerData"] as? Data
        // 预解析设备名称和 MAC，避免 description 中重复 I/O
        if let info = getLEDeviceInfoFromUUID(peripheral.identifier.description) {
            device.blName = info.name
            device.macAddr = info.macAddr
        }
        if device.macAddr == nil {
            device.macAddr = getMACFromUUID(peripheral.identifier.description)
        }
        if let mac = device.macAddr, device.blName == nil {
            device.blName = getNameFromMAC(mac)
        }
        devices[peripheral.identifier] = device
        central.connect(peripheral, options: nil)
        DispatchQueue.main.async {
            self.delegate?.newDevice(device: device)
        }
    }
}
```

- [ ] **Step 2: 修改 `Device.description` 使用缓存值**

```swift
override var description: String {
    get {
        if let name = blName {
            if name != "iPhone" && name != "iPad" {
                return name
            }
        }
        if let manu = manufacture {
            if let mod = model {
                if manu == "Apple Inc." && appleDeviceNames[mod] != nil {
                    return appleDeviceNames[mod]!
                }
                return String(format: "%@/%@", manu, mod)
            } else {
                return manu
            }
        }
        if let name = peripheral?.name {
            if name.trimmingCharacters(in: .whitespaces).count != 0 {
                return name
            }
        }
        if let mod = model {
            return mod
        }
        // iBeacon
        if let adv = advData {
            if adv.count >= 25 {
                var iBeaconPrefix : [uint16] = [0x004c, 0x01502]
                if adv[0...3] == Data(bytes: &iBeaconPrefix, count: 4) {
                    let major = uint16(adv[20]) << 8 | uint16(adv[21])
                    let minor = uint16(adv[22]) << 8 | uint16(adv[23])
                    let tx = Int8(bitPattern: adv[24])
                    let distance = pow(10, Double(Int(tx) - rssi)/20.0)
                    let d = String(format:"%.1f", distance)
                    return "iBeacon [\(major), \(minor)] \(d)m"
                }
            }
        }
        if let name = blName {
            return name
        }
        if let mac = macAddr {
            return mac
        }
        return uuid.description
    }
}
```

- [ ] **Step 3: 验证编译通过**

Run: `xcodebuild build -project BLEUnlock.xcodeproj -scheme BLEUnlock -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add BLEUnlock/BLE.swift
git commit -m "perf: pre-resolve device name/MAC at scan time, eliminate per-access disk I/O in Device.description"
```

---

## Task 6: nowPlayingWasPlaying 状态竞争 — `AppDelegate.swift`

**问题：** `pauseNowPlaying()` 使用异步回调设置标志，`playNowPlaying()` 可能在回调返回前读取旧值。

**Files:**
- Modify: `BLEUnlock/AppDelegate.swift:180-203`（pauseNowPlaying 和 playNowPlaying）

- [ ] **Step 1: 添加状态跟踪变量**

在 AppDelegate 属性中添加：

```swift
var nowPlayingPauseCompleted = false
```

- [ ] **Step 2: 修改 `pauseNowPlaying`**

```swift
func pauseNowPlaying() {
    guard prefs.bool(forKey: "pauseItunes") else { return }
    nowPlayingPauseCompleted = false
    MRMediaRemoteGetNowPlayingApplicationIsPlaying(
        DispatchQueue.main,
        { (playing) in
            self.nowPlayingWasPlaying = playing
            self.nowPlayingPauseCompleted = true
            if self.nowPlayingWasPlaying {
                print("pause")
                MRMediaRemoteSendCommand(MRCommandPause, nil)
            }
        }
    )
}
```

- [ ] **Step 3: 修改 `playNowPlaying`**

```swift
func playNowPlaying() {
    guard prefs.bool(forKey: "pauseItunes") else { return }
    guard nowPlayingPauseCompleted else { return }
    if nowPlayingWasPlaying {
        print("play")
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false, block: { _ in
            MRMediaRemoteSendCommand(MRCommandPlay, nil)
            self.nowPlayingWasPlaying = false
        })
    }
}
```

- [ ] **Step 4: 验证编译通过**

Run: `xcodebuild build -project BLEUnlock.xcodeproj -scheme BLEUnlock -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 5: Commit**

```bash
git add BLEUnlock/AppDelegate.swift
git commit -m "fix: guard playNowPlaying on async pause completion to prevent race condition"
```

---

## Task 7: wakeTimer 退避机制 — `AppDelegate.swift`

**问题：** `wakeTimer` 反复调用 `wakeDisplay()` 无退避，成功唤醒后仍持续调用。

**Files:**
- Modify: `BLEUnlock/AppDelegate.swift:226-233`（updatePresence 中的 wakeTimer 逻辑）

- [ ] **Step 1: 添加 wakeSuccess 标志并在 timer 中检查**

在 AppDelegate 属性中添加：

```swift
var wakeSucceeded = false
```

修改 `updatePresence` 中的 wake 逻辑：

```swift
if displaySleep && !systemSleep && prefs.bool(forKey: "wakeOnProximity") {
    print("Waking display")
    wakeDisplay()
    displaySleep = false
    wakeSucceeded = false
    wakeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true, block: { [weak self] _ in
        guard let self = self else { return }
        if self.wakeSucceeded || !self.displaySleep {
            self.wakeTimer?.invalidate()
            self.wakeTimer = nil
            return
        }
        print("Retrying waking display")
        wakeDisplay()
    })
}
```

修改 `onDisplayWake`：

```swift
@objc func onDisplayWake() {
    print("display wake")
    displaySleep = false
    wakeSucceeded = true
    wakeTimer?.invalidate()
    wakeTimer = nil
    tryUnlockScreen()
}
```

- [ ] **Step 2: 验证编译通过**

Run: `xcodebuild build -project BLEUnlock.xcodeproj -scheme BLEUnlock -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add BLEUnlock/AppDelegate.swift
git commit -m "fix: add wake-backoff flag to stop retry timer after successful display wake"
```

---

## Task 8: checkUpdate 重复请求防护 — `AppDelegate.swift`

**问题：** `checkUpdate()` 可在异步响应返回前被多次调用，触发重复网络请求。

**Files:**
- Modify: `BLEUnlock/checkUpdate.swift:3-13`

- [ ] **Step 1: 添加请求中标志**

```swift
private let KEY = "lastUpdateCheck"
private let INTERVAL = 24.0 * 60 * 60
private var notified = false
private var checking = false  // <-- 新增
private var lastCheckAt = UserDefaults.standard.double(forKey: KEY)

func checkUpdate() {
    guard !notified else { return }
    guard !checking else { return }  // <-- 新增
    let now = NSDate().timeIntervalSince1970
    guard now - lastCheckAt >= INTERVAL else { return }
    doCheckUpdate()
}

private func doCheckUpdate() {
    checking = true  // <-- 新增
    var request = URLRequest(url: URL(string: "https://api.github.com/repos/ts1/BLEUnlock/releases/latest")!)
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    let task = URLSession.shared.dataTask(with: request, completionHandler: { data, response, error in
        defer { self.checking = false }  // <-- 新增
        if let jsondata = data {
            if let json = try? JSONSerialization.jsonObject(with: jsondata) {
                if let dict = json as? [String:Any] {
                    if let version = dict["tag_name"] as? String {
                        lastCheckAt = NSDate().timeIntervalSince1970
                        UserDefaults.standard.set(lastCheckAt, forKey: KEY)
                        compareVersionsAndNotify(version)
                    }
                }
            }
        }
    })
    task.resume()
}
```

- [ ] **Step 2: 验证编译通过**

Run: `xcodebuild build -project BLEUnlock.xcodeproj -scheme BLEUnlock -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add BLEUnlock/checkUpdate.swift
git commit -m "fix: prevent duplicate update check network requests with checking flag"
```

---

## Task 9: 通知观察者清理 — `AppDelegate.swift`

**问题：** `applicationWillTerminate` 为空，未移除通知观察者。

**Files:**
- Modify: `BLEUnlock/AppDelegate.swift:733-735`（applicationWillTerminate）

- [ ] **Step 1: 在 `applicationWillTerminate` 中移除观察者**

```swift
func applicationWillTerminate(_ aNotification: Notification) {
    let nc = NSWorkspace.shared.notificationCenter
    nc.removeObserver(self)
    let dnc = DistributedNotificationCenter.default
    dnc.removeObserver(self)
}
```

- [ ] **Step 2: 验证编译通过**

Run: `xcodebuild build -project BLEUnlock.xcodeproj -scheme BLEUnlock -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add BLEUnlock/AppDelegate.swift
git commit -m "chore: remove notification observers in applicationWillTerminate"
```

---

## Task 10: 废弃 API 迁移 — `AppDelegate.swift`

**问题：** 使用已废弃的 `NSWorkspace.shared.launchApplication(_:)`。

**Files:**
- Modify: `BLEUnlock/AppDelegate.swift:205-217`（lockOrSaveScreen）

- [ ] **Step 1: 替换废弃 API**

```swift
func lockOrSaveScreen() {
    if prefs.bool(forKey: "screensaver") {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.screensaver.ScreenSaverEngine") {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: config)
        }
    } else {
        if SACLockScreenImmediate() != 0 {
            print("Failed to lock screen")
        }
        if prefs.bool(forKey: "sleepDisplay") {
            print("sleep display")
            sleepDisplay()
        }
    }
}
```

- [ ] **Step 2: 验证编译通过**

Run: `xcodebuild build -project BLEUnlock.xcodeproj -scheme BLEUnlock -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add BLEUnlock/AppDelegate.swift
git commit -m "refactor: replace deprecated NSWorkspace.launchApplication with openApplication(at:configuration:)"
```

---

## Task 11: RSSI 均值计算优化 — `BLE.swift`

**问题：** 对最大 5 元素的数组使用 Accelerate vDSP 框架，开销高于简单循环。

**Files:**
- Modify: `BLEUnlock/BLE.swift:224-233`

- [ ] **Step 1: 替换 vDSP 为简单求和**

```swift
func getEstimatedRSSI(rssi: Int) -> Int {
    if latestRSSIs.count >= latestN {
        latestRSSIs.removeFirst()
    }
    latestRSSIs.append(Double(rssi))
    let sum = latestRSSIs.reduce(0, +)
    return Int(sum / Double(latestRSSIs.count))
}
```

- [ ] **Step 2: 移除 Accelerate 导入**

```swift
// 移除此行：
import Accelerate
```

- [ ] **Step 3: 验证编译通过**

Run: `xcodebuild build -project BLEUnlock.xcodeproj -scheme BLEUnlock -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add BLEUnlock/BLE.swift
git commit -m "perf: replace vDSP with simple sum for small RSSI averaging array"
```

---

## 执行摘要

| Task | 问题 | 文件 | 严重程度 |
|------|------|------|----------|
| 1 | 唤醒后解锁失败 | AppDelegate.swift | 🔴 必须 |
| 2 | 双禁用导致永不锁定 | AppDelegate.swift | 🔴 必须 |
| 3 | manualLock 语义错误 | AppDelegate.swift | 🟡 强烈建议 |
| 4 | BLE 主线程阻塞 | BLE.swift | 🟡 强烈建议 |
| 5 | Device.description I/O | BLE.swift | 🟡 建议 |
| 6 | nowPlaying 状态竞争 | AppDelegate.swift | 🟡 建议 |
| 7 | wakeTimer 退避 | AppDelegate.swift | 🟢 建议 |
| 8 | checkUpdate 重复请求 | checkUpdate.swift | 🟢 建议 |
| 9 | 通知观察者清理 | AppDelegate.swift | 🟢 建议 |
| 10 | 废弃 API 迁移 | AppDelegate.swift | 🟢 建议 |
| 11 | RSSI 均值优化 | BLE.swift | 🟢 建议 |
