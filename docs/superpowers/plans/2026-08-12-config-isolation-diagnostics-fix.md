# 配置独立化 + 诊断功能修复 实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 用独立 suite 域（`com.fuhahah.Funlock.config`）承载所有配置，使覆盖安装后配置不丢失；同时修复诊断 Tab 的 5 个显示/文案问题。

**架构：** 新建 `ConfigStore` 封装 `UserDefaults(suiteName:)` 固定域 + 一次性迁移逻辑（standard → suite）。所有 `@AppStorage` 加 `store:` 参数指向 suite，所有 `UserDefaults.standard` 调用改为 `ConfigStore.shared.defaults`。诊断修复涉及 `DiagnosticsView` 显示逻辑、`FUnManager` 记录节流、本地化文案。

**技术栈：** Swift 5.0、SwiftUI `@AppStorage`、UserDefaults suite、XCTest

**规格：** `docs/superpowers/specs/2026-08-12-config-isolation-diagnostics-fix-design.md`

---

## 文件结构

**新建：**
- `FUnlock/ConfigStore.swift` — 独立 suite 封装 + 迁移
- `FUnlockTests/ConfigStoreTests.swift` — 迁移幂等 / 读写 / 过滤测试
- `FUnlockTests/DiagnosticsViewTests.swift` — `timeString` / `screenLabel` 测试

**修改：**
- `FUnlock/AppDelegate.swift` — `prefs` 换 suite；启动调 `migrateIfNeeded()`
- `FUnlock/FUnManager.swift` — `prefs` 换 suite；`manualLockActive` 节流
- `FUnlock/FUn.swift` — `offsetSetting` / `lockOnIdle` 换 suite
- `FUnlock/ProfileManager.swift` — `UserDefaults.standard` 换 suite
- `FUnlock/iMessageNotifier.swift` — `Keys` 读取换 suite
- `FUnlock/BasicSettingsView.swift`、`LockSettingsView.swift`、`NetworkSettingsView.swift`、`UnlockSettingsView.swift`、`IMSettingsCard.swift`、`MenuBarPopover.swift`、`OverviewView.swift` — `@AppStorage` 加 `store:`
- `FUnlock/MainWindowView.swift`、`OnboardingView.swift` — onboarding 标记换 suite
- `FUnlock/DiagnosticsView.swift` — screen 显示、detail RSSI 去重、日期去重
- `FUnlock/Base.lproj/Localizable.strings`、`zh-Hans.lproj/Localizable.strings` — 新文案 key
- `FUnlockTests/FUnlockTests.swift` — manualLockActive 节流测试

---

### 任务 1：ConfigStore + 迁移逻辑

**文件：**
- 创建：`FUnlock/ConfigStore.swift`
- 测试：`FUnlockTests/ConfigStoreTests.swift`

- [ ] **步骤 1：编写失败的迁移测试**

```swift
// FUnlockTests/ConfigStoreTests.swift
import XCTest
@testable import FUnlock

final class ConfigStoreTests: XCTestCase {
    private var store: ConfigStore!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ConfigStoreTests-\(UUID().uuidString)"
        store = ConfigStore(suiteName: suiteName)
    }

    override func tearDown() {
        // 清理当前 suite 域的持久化文件（removePersistentDomain 按域名生效，与实例无关）
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        store = nil
        suiteName = nil
        super.tearDown()
    }

    /// 迁移：standard 有旧值 → 搬到 suite
    func testMigrateMovesLegacyValues() {
        // 准备旧值（用带前缀的 key，避免污染真实 standard）
        let legacyKey = "testMigrateMovesLegacyValues_key"
        UserDefaults.standard.set("legacy", forKey: legacyKey)
        defer { UserDefaults.standard.removeObject(forKey: legacyKey) }

        store.migrateIfNeeded(fromKeys: [legacyKey])

        XCTAssertEqual(store.defaults.string(forKey: legacyKey), "legacy",
                       "迁移后 suite 应包含旧值")
    }

    /// 幂等：第二次 migrateIfNeeded 不再覆盖
    func testMigrateIsIdempotent() {
        let legacyKey = "testMigrateIsIdempotent_key"
        UserDefaults.standard.set("v1", forKey: legacyKey)
        defer { UserDefaults.standard.removeObject(forKey: legacyKey) }

        store.migrateIfNeeded(fromKeys: [legacyKey])
        store.defaults.set("v2", forKey: legacyKey) // 用户在 suite 中改了值
        store.migrateIfNeeded(fromKeys: [legacyKey])

        XCTAssertEqual(store.defaults.string(forKey: legacyKey), "v2",
                       "已迁移后再次调用不应覆盖 suite 中用户新值")
    }

    /// 读写
    func testSetGet() {
        store.set(42, forKey: "intKey")
        XCTAssertEqual(store.get("intKey", fallback: 0), 42)
        store.set("hello", forKey: "strKey")
        XCTAssertEqual(store.get("strKey", fallback: ""), "hello")
    }
}
```

> 注意：`ConfigStoreTests` 用独立 suite 名隔离，`tearDown` 用 `UserDefaults().removePersistentDomain`（新建临时实例）清理，避免污染测试进程的共享 suite 缓存。

- [ ] **步骤 2：运行测试验证失败**

运行：`xcodebuild test -scheme FUnlock -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath build/DerivedData -only-testing:FUnlockTests/ConfigStoreTests`
预期：FAIL — "cannot find 'ConfigStore' in scope"

- [ ] **步骤 3：编写 ConfigStore 实现**

```swift
// FUnlock/ConfigStore.swift
import Foundation

/// 配置存储：独立 suite 域，与 bundle id 解耦。
/// 覆盖安装 app 后配置不丢失（偏好域不随 bundle 替换而重建）。
/// 所有配置读写走这里，不再直接使用 UserDefaults.standard。
final class ConfigStore {
    static let shared = ConfigStore()

    /// 固定 suite 域名（不随 bundle id 变）
    static let suiteName = "com.fuhahah.Funlock.config"
    private static let didMigrateKey = "didMigrate"

    let defaults: UserDefaults

    /// 测试注入：允许指定 suite 名隔离
    init(suiteName: String = ConfigStore.suiteName) {
        // UserDefaults(suiteName:) 失败时回退 standard（理论不触发）
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    // MARK: - 迁移

    /// 一次性迁移：把旧 standard 的指定 key 搬到 suite。
    /// - Parameter keys: 需要迁移的业务 key 清单（不含系统 key）。
    func migrateIfNeeded(fromKeys keys: [String]) {
        guard !defaults.bool(forKey: ConfigStore.didMigrateKey) else { return }
        let standard = UserDefaults.standard
        for key in keys {
            if let value = standard.object(forKey: key) {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: ConfigStore.didMigrateKey)
    }

    // MARK: - 读写

    func get(_ key: String, fallback: Int) -> Int {
        defaults.object(forKey: key) as? Int ?? fallback
    }
    func get(_ key: String, fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }
    func get(_ key: String, fallback: String) -> String {
        defaults.object(forKey: key) as? String ?? fallback
    }
    func getData(_ key: String) -> Data? {
        defaults.data(forKey: key)
    }
    func set(_ value: Int, forKey key: String) { defaults.set(value, forKey: key) }
    func set(_ value: Bool, forKey key: String) { defaults.set(value, forKey: key) }
    func set(_ value: String, forKey key: String) { defaults.set(value, forKey: key) }
    func set(_ value: Data, forKey key: String) { defaults.set(value, forKey: key) }
    func removeObject(forKey key: String) { defaults.removeObject(forKey: key) }
    func object(forKey key: String) -> Any? { defaults.object(forKey: key) }
    func bool(forKey key: String) -> Bool { defaults.bool(forKey: key) }
    func string(forKey key: String) -> String? { defaults.string(forKey: key) }
}
```

- [ ] **步骤 4：把迁移测试改为使用全量 key 清单并确认通过**

新增一个 `ConfigStoreKeys` 常量供生产使用，测试也用它：

```swift
// FUnlock/ConfigStore.swift 追加
extension ConfigStore {
    /// 需要迁移的业务 key 全量清单（迁移时逐 key 搬迁）
    static let legacyKeys: [String] = [
        "device", "deviceName", "enabled", "launchAtLogin",
        "lockRSSI", "unlockRSSI", "wakeAdvance", "preUnlockTrigger",
        "lockOnIdle", "passiveMode", "wakeOnProximity", "wakeWithoutUnlocking",
        "sleepDisplay", "screensaver", "pauseOnWiFi", "pauseOnWiFiSSID",
        "pauseItunes", "iMessageNotify", "iMessageNotifyRecipient",
        "thresholdRSSI", "timeout", "lockDelay",
        "profiles", "activeProfileID",
        "hasCompletedOnboarding", "hasShownGuide", "hasCheckedAccessibility",
        "lastUpdateCheck", "manualLockNoAutoUnlock", "unlockMargin",
    ]
}
```

测试改用 `ConfigStore.legacyKeys` 的其中几个做验证（保持自包含，不依赖全部 key 都设置）。

- [ ] **步骤 5：Commit**

```bash
git add FUnlock/ConfigStore.swift FUnlockTests/ConfigStoreTests.swift
git commit -m "feat: ConfigStore 独立 suite 域封装 + 一次性迁移逻辑"
```

---

### 任务 2：AppDelegate 接入 suite + 启动迁移

**文件：**
- 修改：`FUnlock/AppDelegate.swift`

- [ ] **步骤 1：替换 prefs 定义并加启动迁移**

`AppDelegate.swift:183` `let prefs = UserDefaults.standard` → `let prefs = ConfigStore.shared.defaults`

`applicationDidFinishLaunching`（约 443 行）最开头加：

```swift
ConfigStore.shared.migrateIfNeeded(fromKeys: ConfigStore.legacyKeys)
```

放在 `restoreSettingsToFUn()` 之前（`restoreSettingsToFUn` 自身约 455 行调用 `prefs.synchronize()`，保持）。

- [ ] **步骤 2：编译验证**

运行：`xcodebuild -scheme FUnlock -configuration Debug -derivedDataPath build/DerivedData build 2>&1 | tail -3`
预期：BUILD SUCCEEDED

- [ ] **步骤 3：Commit**

```bash
git add FUnlock/AppDelegate.swift
git commit -m "feat: 启动时迁移配置到独立 suite 域"
```

---

### 任务 3：FUnManager / FUn / ProfileManager / iMessageNotifier / UpdateChecker 接入 suite

**文件：**
- 修改：`FUnlock/FUnManager.swift`、`FUnlock/FUn.swift`、`FUnlock/ProfileManager.swift`、`FUnlock/iMessageNotifier.swift`、`FUnlock/checkUpdate.swift`

- [ ] **步骤 1：FUnManager**

`FUnManager.swift:112` `let prefs = UserDefaults.standard` → `let prefs = ConfigStore.shared.defaults`

其余 `UserDefaults.standard.set(...)`（203/210/218/224 行）→ `ConfigStore.shared.set(...)`。

`FUnManager.swift:109` `private let updateChecker = UpdateChecker()` → `private let updateChecker = UpdateChecker(defaults: ConfigStore.shared.defaults)`

- [ ] **步骤 2：FUn.swift**

`offsetSetting`（181 行）：`UserDefaults.standard.object` → `ConfigStore.shared.object(forKey:)`

三处 `lockOnIdle`（337/569/766 行）：`UserDefaults.standard.object/bool` → `ConfigStore.shared.object/bool`

- [ ] **步骤 3：ProfileManager**

`ProfileManager.swift` 的 `save()`/`load()`（114/116/120/128 行）`UserDefaults.standard` → `ConfigStore.shared`：

```swift
private func save() {
    if let data = try? JSONEncoder().encode(profiles) {
        ConfigStore.shared.set(data, forKey: profilesKey)
    }
    ConfigStore.shared.set(activeProfileID, forKey: activeKey)
}

private func load() {
    if let data = ConfigStore.shared.getData(forKey: profilesKey),
       let decoded = try? JSONDecoder().decode([Profile].self, from: data) {
        profiles = decoded
    }
    if !profiles.contains(where: { $0.id == "default" }) {
        profiles.insert(.default, at: 0)
    }
    activeProfileID = ConfigStore.shared.string(forKey: activeKey) ?? "default"
}
```

- [ ] **步骤 4：iMessageNotifier**

`iMessageNotifier.swift:40,43` 的 `enabled`/`recipient` 计算属性 → `ConfigStore.shared.defaults.bool/string`：

```swift
private var enabled: Bool {
    ConfigStore.shared.bool(forKey: Keys.enabled)
}
private var recipient: String? {
    ConfigStore.shared.string(forKey: Keys.recipient)
}
```

`IMSettingsCard.swift:123` `UserDefaults.standard.set(normalizedRecipient, ...)` → `ConfigStore.shared.set(normalizedRecipient, forKey: "iMessageNotifyRecipient")`

- [ ] **步骤 5：编译 + 全量测试验证**

运行：`xcodebuild test -scheme FUnlock -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath build/DerivedData`
预期：全部 PASS

- [ ] **步骤 6：Commit**

```bash
git add FUnlock/FUnManager.swift FUnlock/FUn.swift FUnlock/ProfileManager.swift FUnlock/iMessageNotifier.swift FUnlock/IMSettingsCard.swift FUnlock/checkUpdate.swift
git commit -m "feat: 核心逻辑接入 ConfigStore 独立配置域"
```

---

### 任务 4：@AppStorage 视图接入 suite

**文件：**
- 修改：`FUnlock/BasicSettingsView.swift`、`LockSettingsView.swift`、`NetworkSettingsView.swift`、`UnlockSettingsView.swift`、`IMSettingsCard.swift`、`MenuBarPopover.swift`、`OverviewView.swift`

- [ ] **步骤 1：逐文件给 @AppStorage 加 store 参数**

模式统一为 `@AppStorage("key", store: ConfigStore.shared.defaults)`：

- `BasicSettingsView.swift:6-7`：`enabled`、`launchAtLogin`
- `LockSettingsView.swift:5-7`：`pauseItunes`、`sleepDisplay`、`lockOnIdle`
- `NetworkSettingsView.swift:6-8`：`pauseOnWiFi`、`pauseOnWiFiSSID`、`passiveMode`
- `UnlockSettingsView.swift:5-7`：`wakeOnProximity`、`wakeWithoutUnlocking`、`screensaver`
- `IMSettingsCard.swift:7-8`：`iMessageNotify`、`iMessageNotifyRecipient`
- `MenuBarPopover.swift:14`：`enabled`
- `OverviewView.swift:12`：`enabled`

- [ ] **步骤 2：OverviewView thresholdSettingValue 换 suite**

`OverviewView.swift:51` `UserDefaults.standard.object` → `ConfigStore.shared.object(forKey:)`

- [ ] **步骤 3：MainWindowView / OnboardingView onboarding 标记换 suite**

`MainWindowView.swift:101`、`OnboardingView.swift:60,77` 的 `hasCompletedOnboarding` → `ConfigStore.shared.defaults`。

- [ ] **步骤 4：编译 + 全量测试**

运行：`xcodebuild test -scheme FUnlock -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath build/DerivedData`
预期：全部 PASS

- [ ] **步骤 5：Commit**

```bash
git add FUnlock/BasicSettingsView.swift FUnlock/LockSettingsView.swift FUnlock/NetworkSettingsView.swift FUnlock/UnlockSettingsView.swift FUnlock/IMSettingsCard.swift FUnlock/MenuBarPopover.swift FUnlock/OverviewView.swift FUnlock/MainWindowView.swift FUnlock/OnboardingView.swift
git commit -m "feat: 所有 @AppStorage 视图接入 ConfigStore 独立配置域"
```

---

### 任务 5：诊断修复 — screen 字段显示

**文件：**
- 修改：`FUnlock/FUnlockUtils.swift`（`screenLabel` 扩展）、`FUnlock/DiagnosticsView.swift`
- 修改：`FUnlock/Base.lproj/Localizable.strings`、`zh-Hans.lproj/Localizable.strings`
- 测试：`FUnlockTests/DiagnosticsViewTests.swift`（新建）

- [ ] **步骤 1：编写失败的 screenLabel 测试**

```swift
// FUnlockTests/DiagnosticsViewTests.swift
import XCTest
@testable import FUnlock

final class DiagnosticsViewTests: XCTestCase {
    func testScreenLabelMapsKnownStates() {
        XCTAssertEqual(DecisionEvent.screenLabel("locked(away)"), "screen_locked_away")
        XCTAssertEqual(DecisionEvent.screenLabel("locked(manual)"), "screen_locked_manual")
        XCTAssertEqual(DecisionEvent.screenLabel("unlocked"), "screen_unlocked")
        XCTAssertEqual(DecisionEvent.screenLabel("displaySleeping"), "screen_display_sleeping")
    }

    func testScreenLabelFallsBackToRaw() {
        XCTAssertEqual(DecisionEvent.screenLabel("unknown"), "unknown")
        XCTAssertNil(DecisionEvent.screenLabel(nil))
    }

    func testTimeStringContainsOnlyTime() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let s = DiagnosticsView.timeString(date)
        // 不含 "/" 或 "月"（日期分隔符），只含 HH:mm
        XCTAssertFalse(s.contains("/"))
        XCTAssertFalse(s.contains("月"))
    }
}
```

- [ ] **步骤 2：运行测试验证失败**

运行：`xcodebuild test -scheme FUnlock -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath build/DerivedData -only-testing:FUnlockTests/DiagnosticsViewTests`
预期：FAIL — "cannot find 'screenLabel' in scope" 和 timeString 含日期

- [ ] **步骤 3：实现 screenLabel 静态映射 + timeString 只含时间**

```swift
// FUnlockUtils.swift 追加
extension DecisionEvent {
    /// 屏幕状态 → 本地化 key（静态，便于测试）
    static func screenLabel(_ screen: String?) -> String? {
        guard let screen else { return nil }
        switch screen {
        case "unlocked": return "screen_unlocked"
        case "locked(away)": return "screen_locked_away"
        case "locked(manual)": return "screen_locked_manual"
        case "locked(lost)": return "screen_locked_lost"
        case "locked(timeout)": return "screen_locked_timeout"
        case "displaySleeping": return "screen_display_sleeping"
        case "screensaver": return "screen_screensaver"
        default: return screen
        }
    }
}
```

`DiagnosticsView.timeString` 改为只显示时间：

```swift
static func timeString(_ date: Date) -> String {
    date.formatted(.dateTime.hour().minute())
}
```

- [ ] **步骤 4：DiagnosticsView.itemRow 显示 screenLabel**

在 `itemRow` 的 RSSI/设备 HStack 前加一行：

```swift
if let screenKey = DecisionEvent.screenLabel(event.screen) {
    Text(t(screenKey))
        .font(.system(size: 11))
        .foregroundColor(.secondary)
}
```

- [ ] **步骤 5：本地化文件加 key**

Base.lproj：
```swift
"screen_unlocked" = "Unlocked";
"screen_locked_away" = "Locked - device away";
"screen_locked_manual" = "Locked - manually";
"screen_locked_lost" = "Locked - signal lost";
"screen_locked_timeout" = "Locked - timeout";
"screen_display_sleeping" = "Display sleeping";
"screen_screensaver" = "Screensaver";
```

zh-Hans.lproj：
```swift
"screen_unlocked" = "已解锁";
"screen_locked_away" = "已锁定 — 设备离开";
"screen_locked_manual" = "已锁定 — 手动锁屏";
"screen_locked_lost" = "已锁定 — 信号丢失";
"screen_locked_timeout" = "已锁定 — 超时";
"screen_display_sleeping" = "显示器休眠";
"screen_screensaver" = "屏幕保护";
```

- [ ] **步骤 6：运行测试验证通过**

运行：`xcodebuild test -scheme FUnlock -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath build/DerivedData -only-testing:FUnlockTests/DiagnosticsViewTests`
预期：PASS

- [ ] **步骤 7：Commit**

```bash
git add FUnlock/FUnlockUtils.swift FUnlock/DiagnosticsView.swift FUnlock/Base.lproj/Localizable.strings FUnlock/zh-Hans.lproj/Localizable.strings FUnlockTests/DiagnosticsViewTests.swift
git commit -m "feat: 诊断时间线显示屏幕状态 + 时间只显示 HH:mm"
```

---

### 任务 6：诊断修复 — manualLockActive 节流

**文件：**
- 修改：`FUnlock/FUnManager.swift`
- 测试：`FUnlockTests/FUnlockTests.swift`

- [ ] **步骤 1：编写失败的节流测试**

```swift
// FUnlockTests/FUnlockTests.swift（新增类）
@MainActor
final class ManualLockThrottleTests: XCTestCase {
    private var logger: DecisionLogger!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThrottleTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        logger = DecisionLogger(testLogDirectory: tempDir)
    }

    override func tearDown() {
        logger.clear()
        logger = nil
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    func testManualLockActiveThrottled30s() {
        let fun = FUn()
        let manager = FUnManager(fun: fun, nowProvider: { Date() }, decisionLogger: logger)

        // 通过系统锁屏通知进入手动锁屏状态（state.intent = .manualLock）
        manager.isSelfLocking = false
        manager.onSystemScreenLocked()
        // onSystemScreenLocked 设置了 lastLockTime = now，会先命中 lockBufferActive 分支；
        // 手动拨回过去，确保走到 manualLockActive 分支
        manager.lastLockTime = .distantPast
        fun.presence = true

        // 两次 attemptAutoUnlock：第一次记录，第二次（30s 内）应被节流
        manager.attemptAutoUnlock()
        manager.attemptAutoUnlock()

        let count = logger.events.filter { $0.reason == .manualLockActive }.count
        XCTAssertEqual(count, 1, "30 秒内 manualLockActive 只记录一次")
    }
}
```

> 注意：`state` 是 `private(set)`，不能直接赋值。用 `onSystemScreenLocked()`（isSelfLocking=false → 走 manualLock 分支）进入手动锁屏状态。`onSystemScreenLocked` 会设置 `lastLockTime = now`，为避免 `attemptAutoUnlock` 先命中 `lockBufferActive` 分支，测试需把 `lastLockTime` 拨回 `.distantPast`（该属性为 internal，测试可访问）。

- [ ] **步骤 2：运行测试验证失败**

运行：`xcodebuild test -scheme FUnlock -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath build/DerivedData -only-testing:FUnlockTests/ManualLockThrottleTests`
预期：FAIL — 记录了 2 次（无节流）

- [ ] **步骤 3：实现节流**

```swift
// FUnManager 新增属性
private var lastRecordTime: [DecisionReason: Date] = [:]

// FUnManager 新增方法
private func recordUnlockThrottled(_ reason: DecisionReason, detail: String = "", throttle: TimeInterval = 30) {
    let now = Date()
    if let last = lastRecordTime[reason], now.timeIntervalSince(last) < throttle {
        return
    }
    lastRecordTime[reason] = now
    recordUnlock(reason: reason, detail: detail)
}
```

`attemptAutoUnlock` 中 `manualLockActive` 分支（约 588-592 行）改为：

```swift
if state.intent.isManualLockActive {
    Log.sm.debug("SKIP: manualLock active, waiting for manual unlock")
    recordUnlockThrottled(.manualLockActive)
    return
}
```

- [ ] **步骤 4：运行测试验证通过**

运行：`xcodebuild test -scheme FUnlock -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath build/DerivedData -only-testing:FUnlockTests/ManualLockThrottleTests`
预期：PASS

- [ ] **步骤 5：全量测试回归**

运行：`xcodebuild test -scheme FUnlock -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath build/DerivedData`
预期：全部 PASS

- [ ] **步骤 6：Commit**

```bash
git add FUnlock/FUnManager.swift FUnlockTests/FUnlockTests.swift
git commit -m "feat: manualLockActive 30s 节流，防止诊断时间线刷屏"
```

---

### 任务 7：诊断修复 — detail RSSI 去重 + 文案修正

**文件：**
- 修改：`FUnlock/DiagnosticsView.swift`（移除独立 RSSI 显示）
- 修改：`FUnlock/Base.lproj/Localizable.strings`、`zh-Hans.lproj/Localizable.strings`（文案）

- [ ] **步骤 1：移除独立 RSSI 显示**

`DiagnosticsView.itemRow` 中 `if let rssi = event.rssi { Text("\(rssi) dBm") }` 移除（detail 已含信号 + 阈值信息）。

- [ ] **步骤 2：修正文案**

Base.lproj：
```swift
"reason_screen_not_locked" = "Screen already unlocked, no action needed";
```

zh-Hans.lproj：
```swift
"reason_screen_not_locked" = "屏幕已解锁，无需操作";
```

- [ ] **步骤 3：编译验证**

运行：`xcodebuild -scheme FUnlock -configuration Debug -derivedDataPath build/DerivedData build 2>&1 | tail -3`
预期：BUILD SUCCEEDED

- [ ] **步骤 4：Commit**

```bash
git add FUnlock/DiagnosticsView.swift FUnlock/Base.lproj/Localizable.strings FUnlock/zh-Hans.lproj/Localizable.strings
git commit -m "fix: 诊断时间线去掉重复 RSSI 显示 + 修正文案歧义"
```

---

## 自检

**1. 规格覆盖度：**
- ✅ 配置独立化（suite 域 + 迁移）：任务 1-4
- ✅ #1 screen 显示：任务 5
- ✅ #2 manualLockActive 节流：任务 6
- ✅ #3 detail RSSI 重复：任务 7
- ✅ #4 日期重复：任务 5（timeString 改动）
- ✅ #5 文案歧义：任务 7

**2. 占位符扫描：** 所有步骤含具体代码，无 TODO/待定。

**3. 类型一致性：**
- `ConfigStore.shared.defaults` 在任务 2/3/4 一致使用
- `ConfigStore.shared.get/set` 签名在任务 1 定义、任务 3/4 引用一致
- `DecisionEvent.screenLabel(_:)` 静态方法在任务 5 定义、UI 调用一致
- `recordUnlockThrottled(_:detail:throttle:)` 在任务 6 定义并唯一使用
