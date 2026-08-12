# FUnlock 设计规格：配置独立化 + 诊断功能修复

> 状态：待批准（2026-08-12）
> 分支：feat/diagnostics-tab

## 目标

1. **配置独立化**：用户覆盖安装 app 后配置不丢失（当前 bundle 替换后新进程首启偏好域缓存未就绪导致配置读空、UI 回默认值）。
2. **诊断功能修复**：诊断 Tab 时间线的 5 个显示/文案问题。

## 背景与现状

### 配置存储现状

所有配置通过 `UserDefaults.standard` 存储（约 19 个业务 key）：

| key | 类型 | 说明 |
|---|---|---|
| device / deviceName | String | 监控设备 |
| enabled | Bool | 总开关 |
| lockRSSI / unlockRSSI | Int | 阈值 |
| launchAtLogin | Bool | 登录启动 |
| lockOnIdle | Bool | 空闲锁屏 |
| passiveMode | Bool | 被动模式 |
| wakeAdvance / preUnlockTrigger | Int | 唤醒提前量 |
| wakeOnProximity | Bool | 靠近唤醒 |
| wakeWithoutUnlocking | Bool | 仅唤醒不解锁 |
| sleepDisplay / screensaver | Bool | 锁屏方式 |
| pauseOnWiFi / pauseOnWiFiSSID | Bool/String | Wi-Fi 暂停 |
| iMessageNotify / iMessageNotifyRecipient | Bool/String | iMessage 通知 |

**问题根因**（`AppDelegate.swift:452-454` 注释已证实）：
> "bundle 替换后新进程首启时偏好域缓存可能未就绪，直接读取会返回空值导致恢复被跳过（阈值退回默认）"

即：`UserDefaults.standard` 的偏好域与 `Bundle.main.bundleIdentifier` 绑定。覆盖安装（`rm -rf` + `cp`）后，cfprefsd 缓存未就绪，启动时 `prefs.integer(forKey:)` 返回 0 → `if lockRSSI != 0` 跳过恢复 → UI 显示默认值。

另外，历史上 Bundle ID 多次变化（`jp.or.tsn.ts1.apps.BLEUnlock` → `com.fuhahah.BLEUnlock` → `com.fuhahah.FUnlock`），导致 Keychain service 对不上、密码需要重输。

### 诊断功能现状问题

1. **screen 字段未显示**：`DecisionEvent.screen` 记录了屏幕状态快照（`locked(away)`/`locked(manual)`/`unlocked`），但 `DiagnosticsView.itemRow` 从不显示。
2. **manualLockActive 刷屏**：手动锁屏期间心跳每 2 秒触发 `attemptAutoUnlock` → `manualLockActive`，3s 合并挡不住持续刷屏，日志中该原因 556 条（占 unlock 70%）。
3. **detail RSSI 重复**：detail 已含 `信号 X dBm（解锁阈值 Y dBm）`，UI 又单独显示 `Text("\(rssi) dBm")`，且两值不同（detail 用 effectiveRSSI，独立用 rssi）。
4. **日期重复显示**：按天分组（组标题显示今天/昨天/8月12日），组内每条又显示 `month().day().hour().minute()`，日期冗余。
5. **reason_screen_not_locked 文案歧义**：「屏幕已解锁」反直觉，且实际未被使用。

## 方案总览

### 方案 B：配置独立化（独立 suite 域）

**核心**：用 `UserDefaults(suiteName: "com.fuhahah.Funlock.config")` 固定域名承载所有配置，与 bundle id 解耦。suite 域名不随 bundle 替换变化，cfprefsd 始终命中同一偏好域文件，覆盖安装后配置稳定可读。

```
┌─ ConfigStore（新文件 FUnlock/ConfigStore.swift）──────────────┐
│  static let shared                                          │
│  let defaults = UserDefaults(suiteName: "com.fuhahah.Funlock.config")! │
│  // 迁移：standard → suite（一次性）                          │
│  func migrateIfNeeded()                                      │
│  // 读写辅助                                                  │
│  func get<T>(_ key: String, default: T) -> T                │
│  func set<T>(_ value: T, forKey key: String)                │
└─────────────────────────────────────────────────────────────┘
```

**迁移流程**（`AppDelegate.applicationDidFinishLaunching` 最先调用）：

```swift
ConfigStore.shared.migrateIfNeeded()
// 1. 若 suite 已有 didMigrate=true → 跳过（已迁移）
// 2. 若 standard 有旧配置 → 逐个搬到 suite，置 didMigrate=true
// 3. 之后所有读写走 suite
```

**key 映射**：所有现有 key 名不变，仅存储域从 `standard` 改为 `ConfigStore.shared.defaults`。`didMigrate` 是新增的内部标记 key。

**改动点清单**：

| 文件 | 改动 |
|---|---|
| `FUnlock/ConfigStore.swift`（新增） | suite 封装 + 迁移逻辑 |
| `FUnlock/BasicSettingsView.swift` | 2 个 `@AppStorage` → 加 `store:` |
| `FUnlock/LockSettingsView.swift` | 3 个 `@AppStorage` → 加 `store:` |
| `FUnlock/NetworkSettingsView.swift` | 3 个 `@AppStorage` → 加 `store:` |
| `FUnlock/UnlockSettingsView.swift` | `wakeOnProximity`/`wakeWithoutUnlocking` → 加 `store:` |
| `FUnlock/IMSettingsCard.swift` | 2 个 `@AppStorage` → 加 `store:` |
| `FUnlock/MenuBarPopover.swift` | `enabled` → 加 `store:` |
| `FUnlock/FUnManager.swift` | 全部 `UserDefaults.standard` → `ConfigStore.shared` |
| `FUnlock/FUn.swift` | `offsetSetting`/`lockOnIdle` → `ConfigStore.shared` |
| `FUnlock/AppDelegate.swift` | `prefs` → `ConfigStore.shared`；启动加 `migrateIfNeeded()` |
| `FUnlockTests/ConfigStoreTests.swift`（新增） | 迁移 / 读写 / 幂等测试 |

> 说明：`@AppStorage("key", store: ConfigStore.shared.defaults)` 是 SwiftUI 原生支持，无需自建绑定。

### 诊断功能修复

#### 1. screen 字段显示

`DecisionEvent.screen`（如 `locked(away)`）→ 本地化映射：

```swift
extension DecisionEvent {
    var screenLabel: String? {
        guard let screen else { return nil }
        switch screen {
        case "unlocked": return t("screen_unlocked")
        case "locked(away)": return t("screen_locked_away")
        case "locked(manual)": return t("screen_locked_manual")
        case "locked(lost)": return t("screen_locked_lost")
        case "locked(timeout)": return t("screen_locked_timeout")
        case "displaySleeping": return t("screen_display_sleeping")
        case "screensaver": return t("screen_screensaver")
        default: return screen
        }
    }
}
```

`DiagnosticsView.itemRow` 的 HStack 加 `Text(event.screenLabel ?? "")`，用 `.secondary` 小字。

#### 2. manualLockActive 刷屏 → 记录节流

`FUnManager` 加一个低频同因记录节流：30 秒内同一 reason 只记录一次。

```swift
// FUnManager 新增
private var lastRecordTime: [DecisionReason: Date] = [:]

private func recordUnlockThrottled(_ reason: DecisionReason, detail: String = "", throttle: TimeInterval = 30) {
    let now = Date()
    if let last = lastRecordTime[reason], now.timeIntervalSince(last) < throttle {
        return // 节流：丢弃重复
    }
    lastRecordTime[reason] = now
    recordUnlock(reason: reason, detail: detail)
}
```

`attemptAutoUnlock` 中 `manualLockActive` 分支改用 `recordUnlockThrottled(.manualLockActive)`。

> 仅对 `manualLockActive` 这类高频持续状态节流；`noPresence`/`lockBufferActive` 等保持原样（它们有真实信息变化）。

#### 3. detail RSSI 重复

`DiagnosticsView.itemRow` 移除独立的 `Text("\(rssi) dBm")` 显示，保留 detail（已含信号 + 阈值）。理由：detail 用 `effectiveRSSI` 更准确，且避免两处数值不一致造成困惑。

#### 4. 日期重复显示

`timeString` 改为始终只显示 `hour().minute()`（日期已由分组标题承担）：

```swift
static func timeString(_ date: Date) -> String {
    date.formatted(.dateTime.hour().minute())
}
```

#### 5. 文案修正

- `reason_screen_not_locked`：`屏幕已解锁` → `屏幕已解锁，无需操作`（Base：`Screen already unlocked` → `Screen already unlocked, no action needed`）

### 测试

| 测试文件 | 覆盖 |
|---|---|
| `ConfigStoreTests.swift`（新增） | 迁移幂等、读写、旧配置搬迁 |
| `DiagnosticsViewTests.swift`（新增，若可行） | `timeString` 只含时间；`screenLabel` 映射 |
| `FUnlockTests.swift` 扩展 | manualLockActive 节流：30s 内只记一次 |

## 关键规则

1. **迁移只做一次**：`didMigrate` 标记防重复搬迁，`standard` 旧数据保留不删（可回滚）。
2. **不改变默认值语义**：`ConfigStore.get` 的默认值与现有 `@AppStorage` 默认值完全一致（如 `enabled=true`、`lockOnIdle=true`）。
3. **suite 域名固定**：`com.fuhahah.Funlock.config` 不再随 bundle id 变。
4. **节流仅针对高频状态**：不影响 noPresence 等有信息量的记录。
5. **不污染既有日志口径**：`events.log`、`ScriptRunner`、`StatsView` 统计保持不变。

## 不在本次范围

- Keychain 密码的历史 bundle id 迁移（需额外一次性逻辑，本次仅确保新写入稳定）
- 诊断 Tab 其他 UI 重构
- 自定义 JSON 配置文件方案（已被 suite 域方案取代）

## 风险与降级

- **风险 1：迁移时 cfprefsd 仍未就绪** → `migrateIfNeeded` 在 `didFinishLaunching` 最早调用，`standard` 与 `suite` 同进程内直接读写，不依赖跨进程缓存；即使首读空，`standard` 旧值仍在磁盘，下次启动可补迁。
- **风险 2：@AppStorage 绑定 suite 后 UI 不同步** → `@AppStorage` 原生监听 suite store 变更，与 standard 行为一致。
- **风险 3：节流失真信息** → 仅 manualLockActive 节流，且 30s 窗口足够短，不影响"手动锁屏保护中"状态的可读性。
