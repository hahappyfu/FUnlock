# FUnlock Full Audit Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Execute all work in `/Volumes/傅哈哈的尿袋/fuhaha_workspace/FUnlock`.

**Goal:** Eliminate all 22 audited P0/P1/P2 defects in FUnlock (false locks, unlock livelock/stalls, screen state machine desync, security/credential leaks, SQLite UAF, broken auto-update, main-thread logging/alert stalls, and test pollution) across 4 incremental TDD batches.

**Architecture:** Preserve FUnlock's existing layered boundaries (`AppDelegate` UI shell → `@MainActor` `FUnManager`/`UnlockOrchestrator`/`FUnlockStateMachine` → `UnfairLock`-synchronized `FUn`/`BLEScanner`/`BLEPeripheralHandler`/`SignalPipeline` → `SystemInteractionService`/`lowlevel.c`). Add deterministic test injection hooks (`idleTimeProvider`, `sessionLockProvider`, `frontmostBundleIDProvider`, `screenLockVerifyDelay`) so every fix is pinned by fast, isolated unit tests without touching `project.pbxproj` unnecessarily (new tests live in the matching existing `FUnlockTests/*.swift` suites).

**Tech Stack:** Swift 5.0 (`SWIFT_VERSION=5.0`), macOS 14.0+, AppKit/SwiftUI/Observation/CoreBluetooth/CoreGraphics/IOKit/SQLite3, C (`lowlevel.c`), XCTest (`xcodebuild`).

**Spec:** `docs/superpowers/specs/2026-11-24-full-audit-remediation-design.md`

## Global Constraints

- Target repo: `/Volumes/傅哈哈的尿袋/fuhaha_workspace/FUnlock` (do not touch `NotchEvery` or `/Users/fupingguo/fuhaha_workspace/FUnlock`).
- macOS 14.0+, `LSUIElement = true`, Hardened Runtime, no App Sandbox.
- `FUnManager` / `UnlockOrchestrator` / `FUnlockStateMachine` stay `@MainActor`; `FUn` / `BLEScanner` / `BLEPeripheralHandler` share non-reentrant `UnfairLock` (never nest computed locked properties or perform blocking I/O inside `lock.withLock`).
- Never inject plaintext password when the system session is unlocked or when frontmost app is a known non-lockscreen app (anything other than `com.apple.loginwindow`, or `com.apple.ScreenSaver.Engine` during screensaver prelude).
- Preserve permanent-until-unlock `manualLock` security policy (never auto-expire after 24h while locked).
- Never let tests trigger real screen lock or write to `~/Library/Logs/FUnlock/`.
- Every batch must pass full `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` with 0 Swift warnings and 0 failures.

## Review Focus

- `CGEventSource.secondsSinceLastEventType` returning a negative/error value or `activityWindow <= 0` → `InputActivityMonitor.isActive` must return `false` (never permanently block locking). Covered in Task 1.
- `unbindDevice()` called while `passiveMode == true` → must clear `monitoredUUID` before stopping scan so `BLEScanner` actually calls `centralMgr.stopScan()`. Covered in Task 2.
- `onSystemScreenLocked()` arriving ~100ms before `CGSession` flips locked, then cancelled by `onUnlock()` within `0.3s` → `screenLockVerifyTask` must cancel cleanly and never overwrite `.unlocked` back to `.manualLock`. Covered in Task 13.
- `ConfigStore.importAllSettings()` given legacy pre-fix JSON (`"enabled": "1"`, `"pauseOnWiFiSSID": "123456"`, `"barkNotifyServer": "http://evil.com"`, `"barkNotifyKey": "leaked"`) → must keep `"123456"` as `String`, reject `http://` server, preserve existing local `barkNotifyKey`, and restore `enabled = true`. Covered in Task 14 & Task 17.
- `UpdateInstaller.makeInstallScript(appPath:)` with spaces, single quotes, or `$(...)` in path → POSIX single-quote escaping prevents injection, and non-zero `cp -R` exit code leaves `/Applications/FUnlock.app` untouched. Covered in Task 16.

---

## File Structure

- **Batch 1 (P0 False-Lock & Unlock Core)**: `AppDelegate.swift`, `BLEScanner.swift`, `BLEPeripheralHandler.swift`, `FUn.swift`, `FUnManager.swift`, `FUnManager+Events.swift`, `FUnLockCoordinator.swift`, `UnlockOrchestrator.swift`, `UnlockOrchestrator+AutoUnlock.swift`, `SystemInteractionService.swift`, `OverviewView.swift`
  - Tests: `PowerStateTests.swift`, `OrchestratorGatesTests.swift`, `InjectionAndUserInterventionTests.swift`, `IntegrationPipelineTests.swift`
- **Batch 2 (P1 State Machine, Concurrency & OS Primitives)**: `UnlockOrchestrator.swift`, `SystemInteractionService.swift`, `FUnManager.swift`, `FUnManager+Events.swift`, `FUnLockCoordinator.swift`, `FUnSignalProcessor.swift`, `SignalHysteresisEngine.swift`, `SignalPipeline.swift`, `SecurityService.swift`, `LockScreenState.swift`, `lowlevel.c`
  - Tests: `InjectionAndUserInterventionTests.swift`, `OrchestratorGatesTests.swift`, `HysteresisEngineTests.swift`, `SignalPipelineTests.swift`, `StateAndConfigTests.swift`, `SecurityServiceTests.swift`
- **Batch 3 (P0-P2 Security, Memory, Auto-Update & Config)**: `BarkNotifier.swift`, `BarkSettingsCard.swift`, `ConfigStore.swift`, `LEDeviceInfo.swift`, `UpdateDownloader.swift`, `UpdateInstaller.swift`, `ProfileManager.swift`, `CalibrationWizardView.swift`, `FUnManager.swift`, `AppDelegate.swift`
  - Tests: `BarkNotifierTests.swift`, `ConfigStoreTests.swift`, `UpdateChainTests.swift`, `StateAndConfigTests.swift`, `UIAndUtilityTests.swift`
- **Batch 4 (P2 Logging, Performance, Test Isolation, CI & Docs)**: `FUnlockUtils.swift`, `AppLog.swift`, `DebugLog.swift`, `TelemetryLogger.swift`, `ScriptRunner.swift`, `UnlockOrchestrator+AutoUnlock.swift`, `FUnManager+Events.swift`, `BLEScanner.swift`, `FUn.swift`, `AppDelegate.swift`, `FUnlockTests/TestSupport.swift`, `.github/workflows/test.yml` (delete), `README.md`
  - Tests: `LogRotationTests.swift`, `AppLogTests.swift`, `OrchestratorGatesTests.swift`, `UIAndUtilityTests.swift`

---

## Batch 1: False-Lock & Unlock Core (P0)

### Task 1: Replace broken IOHIDManager `InputActivityMonitor` with `CGEventSource` (Spec Item 1)

**Files:**
- Modify: `FUnlock/AppDelegate.swift:14-106`, `FUnlock/AppDelegate.swift:667-675`
- Test: `FUnlockTests/PowerStateTests.swift`

**Interfaces:**
- Consumes: `CoreGraphics.CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .anyInputEventType)`
- Produces:
  - `InputActivityMonitor.init(activityWindow: TimeInterval = 15, idleTimeProvider: @escaping () -> TimeInterval = ...)`
  - `InputActivityMonitor.isActive: Bool` (true iff `activityWindow > 0 && idle >= 0 && idle < activityWindow`)
  - `InputActivityMonitor.start()` / `stop()` (idempotent no-ops retained for API compatibility)

- [ ] **Step 1: Write failing tests in `FUnlockTests/PowerStateTests.swift`**

```swift
func testInputActivityMonitorActiveWithinWindow() {
    let monitor = InputActivityMonitor(activityWindow: 15, idleTimeProvider: { 4.2 })
    XCTAssertTrue(monitor.isActive)
}

func testInputActivityMonitorInactiveAtOrBeyondWindow() {
    let atBoundary = InputActivityMonitor(activityWindow: 15, idleTimeProvider: { 15.0 })
    XCTAssertFalse(atBoundary.isActive)
    let past = InputActivityMonitor(activityWindow: 15, idleTimeProvider: { 22.0 })
    XCTAssertFalse(past.isActive)
}

func testInputActivityMonitorRejectsNegativeIdleAndZeroWindow() {
    let negative = InputActivityMonitor(activityWindow: 15, idleTimeProvider: { -1.0 })
    XCTAssertFalse(negative.isActive)
    let zeroWin = InputActivityMonitor(activityWindow: 0, idleTimeProvider: { 0.5 })
    XCTAssertFalse(zeroWin.isActive)
}
```

- [ ] **Step 2: Run targeted test to verify it fails**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FUnlockTests/PowerStateTests`
Expected: FAIL (compile error: `InputActivityMonitor` has no `init(activityWindow:idleTimeProvider:)`).

- [ ] **Step 3: Refactor `InputActivityMonitor` and startup wiring in `FUnlock/AppDelegate.swift`**
  - Replace `IOHIDManager` + `inputCallback` (lines 21-106) with `InputActivityMonitor` backed by `idleTimeProvider` defaulting to `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .anyInputEventType)`.
  - Return `false` when `activityWindow <= 0`, `idle < 0`, or `!idle.isFinite`.
  - Remove `import IOKit.hid` if unused.
  - In `setupPermissionsAndPrivileges()` (lines 667-675), remove the `if isAccessibilityGranted { inputMonitor.start() }` gate so `inputMonitor` is always active regardless of unlock toggle or AX status.

- [ ] **Step 4: Run targeted test to verify it passes**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FUnlockTests/PowerStateTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add FUnlock/AppDelegate.swift FUnlockTests/PowerStateTests.swift
git commit -m "fix(lock): replace broken IOHIDManager filter with CGEventSource idle time"
```

---

### Task 2: Decouple UI device-discovery scan from monitored-device background scan (Spec Item 2)

**Files:**
- Modify: `FUnlock/BLEScanner.swift:121-133`
- Modify: `FUnlock/FUn.swift:155-162`
- Modify: `FUnlock/FUnManager.swift:233-252`
- Test: `FUnlockTests/IntegrationPipelineTests.swift`

**Interfaces:**
- Consumes: `BLEScanner.monitoredUUID`, `BLEScanner.passiveMode`, `BLEPeripheralHandler.activeModeTimer`
- Produces:
  - `BLEScanner.shouldStopCentralScanOnStopDiscovery() -> Bool` (pure lock-protected helper: returns `true` iff `monitoredUUID == nil` OR `(!passiveMode && handler.activeModeTimer != nil)`)
  - `BLEScanner.stopAllScanning()` (unconditional stop used by `unbindDevice`)

- [ ] **Step 1: Write failing tests in `FUnlockTests/IntegrationPipelineTests.swift`**

```swift
func testStopDiscoveryScanPreservesPassiveModeMonitoring() {
    let fun = FUn()
    let id = UUID()
    fun.lock.withLock {
        fun.scanner.monitoredUUID = id
        fun.scanner.passiveMode = true
        fun.scanner.scanMode = true
    }
    XCTAssertFalse(fun.scanner.shouldStopCentralScanOnStopDiscovery())
    fun.stopScanning()
    XCTAssertFalse(fun.lock.withLock { fun.scanner.scanMode })
}

func testStopDiscoveryScanPreservesActiveReconnectMonitoring() {
    let fun = FUn()
    fun.lock.withLock {
        fun.scanner.monitoredUUID = UUID()
        fun.scanner.passiveMode = false
        fun.scanner.handler.activeModeTimer = nil
    }
    XCTAssertFalse(fun.scanner.shouldStopCentralScanOnStopDiscovery())
}

func testStopDiscoveryScanStopsCentralWhenUnboundOrActiveConnected() {
    let fun = FUn()
    XCTAssertTrue(fun.scanner.shouldStopCentralScanOnStopDiscovery())
    fun.lock.withLock {
        fun.scanner.monitoredUUID = UUID()
        fun.scanner.passiveMode = false
        fun.scanner.handler.activeModeTimer = Timer(timeInterval: 10, repeats: false) { _ in }
    }
    XCTAssertTrue(fun.scanner.shouldStopCentralScanOnStopDiscovery())
}

func testUnbindDeviceClearsMonitoredUUIDBeforeStoppingScan() {
    let fun = FUn()
    let manager = FUnManager(fun: fun)
    fun.lock.withLock {
        fun.scanner.monitoredUUID = UUID()
        fun.scanner.passiveMode = true
    }
    manager.unbindDevice()
    XCTAssertNil(fun.monitoredUUID)
    XCTAssertTrue(fun.scanner.shouldStopCentralScanOnStopDiscovery())
}
```

- [ ] **Step 2: Run targeted test to verify it fails**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FUnlockTests/IntegrationPipelineTests`
Expected: FAIL (`shouldStopCentralScanOnStopDiscovery` not defined).

- [ ] **Step 3: Implement scan separation in `BLEScanner.swift` and `FUnManager.swift`**
  - Add `shouldStopCentralScanOnStopDiscovery() -> Bool` and `stopAllScanning()` in `BLEScanner.swift`.
  - Update `BLEScanner.stopScanning()`: set `scanMode = false`; if `shouldStopCentralScanOnStopDiscovery()` is true, reset `currentScanAllowDuplicates = false` and call `centralMgr.stopScan()`; otherwise call `scanForPeripherals()` to preserve background monitoring.
  - Update `FUnManager.unbindDevice()`: call `fun.unbindAllState()` (clearing `monitoredUUID` first) before `fun.stopScanning()` (or call `fun.scanner.stopAllScanning()`), so passive-mode unbind always stops `centralMgr`.

- [ ] **Step 4: Run targeted test to verify it passes**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FUnlockTests/IntegrationPipelineTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add FUnlock/BLEScanner.swift FUnlock/FUn.swift FUnlock/FUnManager.swift FUnlockTests/IntegrationPipelineTests.swift
git commit -m "fix(ble): keep monitored BLE scan alive when closing settings or switching tabs"
```

---

### Task 3: Fix 8s poll disconnect, reconnect AllowDuplicates, poll-aware decay, UUID disconnect match & single-sample fast-lock guard (Spec Item 3)

**Files:**
- Modify: `FUnlock/BLEPeripheralHandler.swift:84-111`, `FUnlock/BLEPeripheralHandler.swift:173-186`
- Modify: `FUnlock/BLEScanner.swift:87-119`
- Modify: `FUnlock/FUn.swift:141-150`
- Modify: `FUnlock/FUnLockCoordinator.swift:48-93`, `FUnlock/FUnLockCoordinator.swift:320-384`
- Test: `FUnlockTests/SignalPipelineTests.swift`

**Interfaces:**
- Consumes: `BLEPeripheralHandler.activePollInterval`, `FUn.lastReceiveTime`
- Produces:
  - `BLEPeripheralHandler.fallbackTimeout(forPollInterval: TimeInterval) -> TimeInterval` (`max(12.0, pollInterval * 2.5)`)
  - `FUn.decayedEffectiveRSSI(effectiveRSSI: Double, elapsedSinceLastReceive: TimeInterval, lockThreshold: Int?, pollInterval: TimeInterval = 2.0) -> Double` (grace window `max(6.0, pollInterval + 2.0)`)
  - `FUn.staleLossDeadline(forPollInterval: TimeInterval) -> TimeInterval` (`max(10.0, pollInterval + 4.0)`)
  - `FUn.lockTimerSettlementAction(hasFreshSample: Bool, elapsed: TimeInterval, pollIntervalBeforeTimer: TimeInterval, alreadyExtended: Bool) -> LockTimerSettlement` (`.settleNow` | `.extend(TimeInterval)`)

- [ ] **Step 1: Write failing tests in `FUnlockTests/SignalPipelineTests.swift`**

```swift
func testFallbackTimeoutScalesWithPollInterval() {
    XCTAssertEqual(BLEPeripheralHandler.fallbackTimeout(forPollInterval: 0.5), 12.0)
    XCTAssertEqual(BLEPeripheralHandler.fallbackTimeout(forPollInterval: 2.0), 12.0)
    XCTAssertEqual(BLEPeripheralHandler.fallbackTimeout(forPollInterval: 8.0), 20.0)
}

func testDecayedEffectiveRSSIRespects8sPollGrace() {
    // 8s poll → grace = max(6, 8+2) = 10s; at 9s penalty must be 0
    let at9s = FUn.decayedEffectiveRSSI(effectiveRSSI: -65, elapsedSinceLastReceive: 9.0, lockThreshold: -80, pollInterval: 8.0)
    XCTAssertEqual(at9s, -65.0, accuracy: 0.01)
    // Existing 2-arg / 3-arg calls keep 6s grace
    let defaultAt8s = FUn.decayedEffectiveRSSI(effectiveRSSI: -65, elapsedSinceLastReceive: 8.0)
    XCTAssertLessThan(defaultAt8s, -65.0)
}

func testSingleSampleFastLockDefersUntilFreshSampleOrStaleDeadline() {
    // 8s poll → staleLossDeadline = 12s; at t=2.5s without fresh sample → extend by 9.5s
    let first = FUn.lockTimerSettlementAction(hasFreshSample: false, elapsed: 2.5, pollIntervalBeforeTimer: 8.0, alreadyExtended: false)
    XCTAssertEqual(first, .extend(9.5))
    // With fresh sample → settle immediately
    let fresh = FUn.lockTimerSettlementAction(hasFreshSample: true, elapsed: 2.5, pollIntervalBeforeTimer: 8.0, alreadyExtended: false)
    XCTAssertEqual(fresh, .settleNow)
    // At stale deadline (12s) → settle immediately
    let stale = FUn.lockTimerSettlementAction(hasFreshSample: false, elapsed: 12.0, pollIntervalBeforeTimer: 8.0, alreadyExtended: true)
    XCTAssertEqual(stale, .settleNow)
}

func testScanAllowDuplicatesEnabledDuringActiveReconnect() {
    let fun = FUn()
    fun.lock.withLock {
        fun.scanner.monitoredUUID = UUID()
        fun.scanner.passiveMode = false
        fun.scanner.handler.activeModeTimer = nil
    }
    XCTAssertTrue(fun.scanner.computeAllowDuplicatesLocked())
}
```

- [ ] **Step 2: Run targeted test to verify it fails**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FUnlockTests/SignalPipelineTests`
Expected: FAIL (missing helpers).

- [ ] **Step 3: Implement Task 3 changes**
  - `BLEPeripheralHandler.swift`:
    - Add `static func fallbackTimeout(forPollInterval pollInterval: TimeInterval) -> TimeInterval { max(12.0, pollInterval * 2.5) }` and use it in `restartActiveModeTimer` instead of `lastRead + 10`.
    - In `centralManager(_:didDisconnectPeripheral:error:)`, match by UUID: `peripheral.identifier == scanner.monitoredUUID || peripheral.identifier == scanner.monitoredPeripheral?.identifier`.
    - Add `func triggerImmediateRSSIProbe()` to request `monitoredPeripheral?.readRSSI()` and bump `activePollInterval` to `fastPollInterval` (`0.5s`) when connected.
  - `BLEScanner.swift`:
    - Extract `computeAllowDuplicatesLocked() -> Bool`: return `true` when `monitoredUUID != nil && (passiveMode || handler.activeModeTimer == nil)`, `false` otherwise; use inside `scanForPeripherals()`.
  - `FUn.swift` & `FUnLockCoordinator.swift`:
    - Add locked fields `lockTimerStartedAt: Date = .distantPast`, `pollIntervalBeforeLockTimer: TimeInterval = 2.0`, `lockTimerExtended: Bool = false`.
    - Add `LockTimerSettlement: Equatable { case settleNow; case extend(TimeInterval) }`, `staleLossDeadline(forPollInterval:)`, `lockTimerSettlementAction(...)`, and `pollInterval`-aware `decayedEffectiveRSSI(...)` (keeping existing overloads forwarding `pollInterval: 2.0`).
    - In `getEffectiveRSSI()`, pass `proximityTimer != nil ? pollIntervalBeforeLockTimer : scanner.handler.activePollInterval`.
    - In `startLockTimer()`, capture `lockTimerStartedAt = Date()`, `pollIntervalBeforeLockTimer = scanner.handler.activePollInterval`, `lockTimerExtended = false`, call `scanner.handler.triggerImmediateRSSIProbe()`, and in timer fire block evaluate `lockTimerSettlementAction`; on `.extend(rem)` schedule one extension timer for `max(1.0, rem)` with `lockTimerExtended = true` and re-probe `readRSSI()`. Reset these fields whenever `proximityTimer` is cleared.

- [ ] **Step 4: Run targeted test to verify it passes**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FUnlockTests/SignalPipelineTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add FUnlock/BLEPeripheralHandler.swift FUnlock/BLEScanner.swift FUnlock/FUn.swift FUnlock/FUnLockCoordinator.swift FUnlockTests/SignalPipelineTests.swift
git commit -m "fix(lock): scale BLE fallback/decay to 8s poll and guard fast-lock against single noisy sample"
```

---

### Task 4: Prevent `attemptAutoUnlock` from cancelling its own pending `unlockTask` under high-frequency BLE callbacks (Spec Item 4)

**Files:**
- Modify: `FUnlock/UnlockOrchestrator.swift:26-44`, `FUnlock/UnlockOrchestrator.swift:75-94`
- Modify: `FUnlock/UnlockOrchestrator+AutoUnlock.swift:105-156`
- Test: `FUnlockTests/OrchestratorGatesTests.swift`

**Interfaces:**
- Consumes: `UnlockOrchestrator.unlockTask`
- Produces:
  - `UnlockOrchestrator.unlockTaskGeneration: UInt64`
  - `UnlockOrchestrator.hasPendingUnlockTask: Bool` (`unlockTask != nil && !(unlockTask?.isCancelled ?? true)`)

- [ ] **Step 1: Write failing test in `FUnlockTests/OrchestratorGatesTests.swift`**

```swift
func testRepeatedAttemptAutoUnlockDoesNotCancelInFlightDelayedTask() {
    lockAsAutoLock()
    manager.fun.lock.withLock {
        manager.fun.presence = true
        manager.fun.effectiveRSSI = -50
    }
    manager.orchestrator.attemptAutoUnlock()
    let firstGen = manager.orchestrator.unlockTaskGeneration
    XCTAssertTrue(manager.orchestrator.hasPendingUnlockTask)

    // Second BLE packet arriving 100ms later must reuse the pending task instead of cancelling it
    manager.orchestrator.attemptAutoUnlock()
    XCTAssertEqual(manager.orchestrator.unlockTaskGeneration, firstGen)
    XCTAssertTrue(manager.orchestrator.hasPendingUnlockTask)
}
```

- [ ] **Step 2: Run targeted test to verify it fails**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FUnlockTests/OrchestratorGatesTests`
Expected: FAIL (`unlockTaskGeneration` / `hasPendingUnlockTask` not defined).

- [ ] **Step 3: Implement task reuse & generation cleanup in `UnlockOrchestrator.swift` and `UnlockOrchestrator+AutoUnlock.swift`**
  - Add `private(set) var unlockTaskGeneration: UInt64 = 0` and `var hasPendingUnlockTask: Bool { unlockTask != nil && !(unlockTask?.isCancelled ?? true) }`.
  - In both the `0.8s` parallel branch (`UnlockOrchestrator+AutoUnlock.swift:116`) and the `0.3s` delayed branch (`:143`): if `hasPendingUnlockTask` is true, log `unlockTaskAlreadyPending` and `return` without cancelling.
  - When scheduling a new `unlockTask`, increment `unlockTaskGeneration`, capture `let gen = unlockTaskGeneration`, and clear `if self.unlockTaskGeneration == gen { self.unlockTask = nil }` in `defer` when the scheduled task exits (note: inside `performInjectionAndVerify`, when replacing `unlockTask` with the verification task, bump `unlockTaskGeneration` as well and clear on completion).
  - In `cancelPendingTasks()`, bump `unlockTaskGeneration` and cancel/nil `unlockTask`.

- [ ] **Step 4: Run targeted test to verify it passes**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FUnlockTests/OrchestratorGatesTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add FUnlock/UnlockOrchestrator.swift FUnlock/UnlockOrchestrator+AutoUnlock.swift FUnlockTests/OrchestratorGatesTests.swift
git commit -m "fix(unlock): reuse in-flight unlockTask instead of cancelling on rapid BLE callbacks"
```

---

### Task 5: Fix display-sleep wake state wedge and tighten `isScreenLocked` / `isSecureToInject` (Spec Item 5)

**Files:**
- Modify: `FUnlock/SystemInteractionService.swift:29-82`
- Modify: `FUnlock/FUnManager+Events.swift:25-49`
- Test: `FUnlockTests/InjectionAndUserInterventionTests.swift`, `FUnlockTests/PowerStateTests.swift`

**Interfaces:**
- Consumes: `CGSessionCopyCurrentDictionary()`, `ScreenSaver.Engine` running check
- Produces:
  - `SystemInteractionService.sessionDictProvider: (() -> [String: Any]?)?` (test hook, nil = real `CGSessionCopyCurrentDictionary()`)
  - `SystemInteractionService.screensaverRunningProvider: (() -> Bool)?` (test hook, nil = real `NSRunningApplication`)
  - `SystemInteractionService.frontmostBundleIDProvider: (() -> String?)?` (test hook, nil = real `NSWorkspace.shared.frontmostApplication?.bundleIdentifier`)
  - `SystemInteractionService.isSystemSessionLocked() -> Bool` (external OS fact only: `CGSSessionScreenIsLocked == 1` OR screensaver running)
  - `SystemInteractionService.isSecureToInject(screenState: ScreenState?, allowScreensaver: Bool = true) -> Bool`

- [ ] **Step 1: Write failing tests in `FUnlockTests/InjectionAndUserInterventionTests.swift` and `FUnlockTests/PowerStateTests.swift`**

```swift
func testDisplayWakeWithoutActualLockRestoresUnlockedState() {
    SystemInteractionService.sessionDictProvider = { ["CGSSessionScreenIsLocked": 0] }
    SystemInteractionService.screensaverRunningProvider = { false }
    defer {
        SystemInteractionService.sessionDictProvider = nil
        SystemInteractionService.screensaverRunningProvider = nil
    }
    let manager = FUnManager(fun: FUn())
    manager.onDisplaySleep()
    XCTAssertEqual(manager.state.screen, .displaySleeping)
    manager.onDisplayWake()
    XCTAssertEqual(manager.state.screen, .unlocked)
}

func testIsScreenLockedDoesNotTrustStaleScreenStateWhenSessionUnlocked() {
    SystemInteractionService.sessionDictProvider = { ["CGSSessionScreenIsLocked": 0] }
    SystemInteractionService.screensaverRunningProvider = { false }
    defer {
        SystemInteractionService.sessionDictProvider = nil
        SystemInteractionService.screensaverRunningProvider = nil
    }
    XCTAssertFalse(SystemInteractionService.shared.isScreenLocked(screenState: .locked(reason: .away)))
}

func testIsSecureToInjectBlocksNilFrontmostUnlessCGSessionLockedAndAllowsScreensaverOnlyInPrelude() {
    defer {
        SystemInteractionService.sessionDictProvider = nil
        SystemInteractionService.screensaverRunningProvider = nil
        SystemInteractionService.frontmostBundleIDProvider = nil
    }
    // Unlocked session + nil frontmost → MUST REJECT
    SystemInteractionService.sessionDictProvider = { ["CGSSessionScreenIsLocked": 0] }
    SystemInteractionService.screensaverRunningProvider = { false }
    SystemInteractionService.frontmostBundleIDProvider = { nil }
    XCTAssertFalse(SystemInteractionService.shared.isSecureToInject(screenState: .locked(reason: .away)))

    // CGSession locked + nil frontmost (macOS 14+ LSUIElement lock screen) → ALLOW
    SystemInteractionService.sessionDictProvider = { ["CGSSessionScreenIsLocked": 1] }
    XCTAssertTrue(SystemInteractionService.shared.isSecureToInject(screenState: .locked(reason: .away)))

    // Locked session + non-lockscreen frontmost app → MUST REJECT
    SystemInteractionService.frontmostBundleIDProvider = { "com.apple.Safari" }
    XCTAssertFalse(SystemInteractionService.shared.isSecureToInject(screenState: .locked(reason: .away)))

    // Screensaver running + CGSession unlocked: prelude allows ScreenSaver.Engine, keystroke stage rejects
    SystemInteractionService.sessionDictProvider = { ["CGSSessionScreenIsLocked": 0] }
    SystemInteractionService.screensaverRunningProvider = { true }
    SystemInteractionService.frontmostBundleIDProvider = { "com.apple.ScreenSaver.Engine" }
    XCTAssertTrue(SystemInteractionService.shared.isSecureToInject(screenState: .screensaver, allowScreensaver: true))
    XCTAssertFalse(SystemInteractionService.shared.isSecureToInject(screenState: .screensaver, allowScreensaver: false))
}
```

- [ ] **Step 2: Run targeted tests to verify they fail**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FUnlockTests/InjectionAndUserInterventionTests -only-testing:FUnlockTests/PowerStateTests`
Expected: FAIL (`sessionDictProvider` / `isSystemSessionLocked` not defined).

- [ ] **Step 3: Implement `SystemInteractionService.swift` and `FUnManager+Events.swift` changes**
  - Add `sessionDictProvider`, `screensaverRunningProvider`, `frontmostBundleIDProvider`, and `isSystemSessionLocked()` to `SystemInteractionService`.
  - Update `isScreenLocked(screenState:)`: if `sessionDict` is non-nil, return `cgLocked || screensaverRunning` directly (do NOT fall back to `screenState`); only fall back to `screenState != .unlocked` when `sessionDict == nil` and `!screensaverRunning`.
  - Update `isSecureToInject(screenState:allowScreensaver:)`: require `isSystemSessionLocked() == true`; if `frontmostBundleID` is non-nil, accept `com.apple.loginwindow` or (`allowScreensaver && id == "com.apple.ScreenSaver.Engine"`); if `frontmostBundleID == nil`, accept ONLY when `cgLocked == true`. Pass `allowScreensaver: false` inside `fakeKeyStrokes` check after Shift prelude (in `UnlockOrchestrator.performInjectionAndVerify` / `injectPasswordWithPrelude`).
  - Update `FUnManager.onDisplayWake()`: when `state.screen == .displaySleeping`, set `state.screen = SystemInteractionService.shared.isSystemSessionLocked() ? .locked(reason: .away) : .unlocked`.

- [ ] **Step 4: Run full Batch 1 regression test suite**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
Expected: ALL tests PASS (update any legacy test that implicitly relied on `isScreenLocked` falling back to `screenState` without mocking `sessionDictProvider`).

- [ ] **Step 5: Commit Batch 1**

```bash
git add FUnlock/SystemInteractionService.swift FUnlock/FUnManager+Events.swift FUnlockTests/
git commit -m "fix(state): verify real OS lock state on display wake and tighten isSecureToInject"
```

---

## Batch 2: State Machine, Concurrency & OS Primitives (P1)

### Task 6: Cancelled verification must not count as password failure; prelude must not swallow cancellation (Spec Item 6)

**Files:**
- Modify: `FUnlock/UnlockOrchestrator.swift:198-277`
- Modify: `FUnlock/SystemInteractionService.swift:123-129`, `FUnlock/SystemInteractionService.swift:338-384`
- Test: `FUnlockTests/InjectionAndUserInterventionTests.swift`

**Interfaces:**
- Consumes: `Task.isCancelled`, `FUnlockStateMachine.transition(to: .active)`
- Produces:
  - `SystemInteractionService.injectPasswordOverride: ((String) async -> Bool)?` (test hook so `performInjectionAndVerify` can be tested without posting real CGEvents)
  - `SystemInteractionService.verifyUnlockOverride: ((TimeInterval, TimeInterval) async -> SystemInteractionService.UnlockNotification)?` (test hook)
  - Cancellation-safe `verifyUnlock` consumer and `injectPasswordWithPrelude`

- [ ] **Step 1: Write failing tests in `FUnlockTests/InjectionAndUserInterventionTests.swift`**

```swift
@MainActor
func testCancelledPreludeReturnsFalseImmediatelyWithoutBlindInjection() async {
    SystemInteractionService.displayPoweredOnProvider = { true }
    defer { SystemInteractionService.displayPoweredOnProvider = nil }
    let task = Task { @MainActor in
        await SystemInteractionService.shared.injectPasswordWithPrelude("secret") { true }
    }
    task.cancel()
    let posted = await task.value
    XCTAssertFalse(posted)
}

@MainActor
func testCancelledVerifyUnlockDoesNotIncrementFailureCountOrDegrade() async {
    SystemInteractionService.sessionDictProvider = { ["CGSSessionScreenIsLocked": 1] }
    SystemInteractionService.displayPoweredOnProvider = { true }
    SystemInteractionService.injectPasswordOverride = { _ in true }
    SystemInteractionService.verifyUnlockOverride = { _, _ in
        try? await Task.sleep(nanoseconds: 500_000_000)
        return .init(unlock: false)
    }
    defer {
        SystemInteractionService.sessionDictProvider = nil
        SystemInteractionService.displayPoweredOnProvider = nil
        SystemInteractionService.injectPasswordOverride = nil
        SystemInteractionService.verifyUnlockOverride = nil
    }
    let manager = FUnManager(fun: FUn())
    _ = manager.stateMachine.attemptUnlock()
    await manager.orchestrator.performInjectionAndVerify(password: "pw")
    manager.orchestrator.cancelPendingTasks()
    try? await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(manager.orchestrator.consecutiveUnlockAttempts, 0)
    XCTAssertEqual(manager.stateMachine.consecutiveFailures, 0)
    XCTAssertEqual(manager.stateMachine.currentState, .active)
    XCTAssertFalse(manager.orchestrator.isAutoUnlocking)
}
```

- [ ] **Step 2: Run targeted test to verify it fails**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FUnlockTests/InjectionAndUserInterventionTests`
Expected: FAIL.

- [ ] **Step 3: Implement cancellation guards**
  - In `UnlockOrchestrator.swift` right after `let verification = await sys.verifyUnlock(...)`: check `if Task.isCancelled { self.manager.stateMachine.transition(to: .active); return }` before inspecting `verification.unlock`.
  - In `SystemInteractionService.swift` `wakeDisplay()` and `injectPasswordWithPrelude`: check `guard !Task.isCancelled` at entry and replace `try? await Task.sleep(...)` with `do { try await Task.sleep(...) } catch { return false }` (and return early in `wakeDisplay` when cancelled).

- [ ] **Step 4: Run targeted test to verify it passes**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FUnlockTests/InjectionAndUserInterventionTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add FUnlock/UnlockOrchestrator.swift FUnlock/SystemInteractionService.swift FUnlockTests/InjectionAndUserInterventionTests.swift
git commit -m "fix(unlock): respect Task cancellation in prelude and dual verification"
```

---

### Task 7: Replace one-shot `isSelfLocking` with instance window + generation-guarded lock verification (Spec Item 7)

**Files:**
- Modify: `FUnlock/FUnManager.swift:40`, `FUnlock/FUnManager.swift:192-203`
- Modify: `FUnlock/FUnManager+Events.swift:9-15`, `FUnlock/FUnManager+Events.swift:86-185`, `FUnlock/FUnManager+Events.swift:258-305`
- Test: `FUnlockTests/OrchestratorGatesTests.swift`

**Interfaces:**
- Consumes: `FUnManager.now`
- Produces:
  - `@ObservationIgnored var selfLockWindowDeadline: Date?` (instance property on `FUnManager`, replacing global `selfLockingStartedAt`)
  - `var isWithinSelfLockWindow: Bool` (`selfLockWindowDeadline.map { now <= $0 } ?? false`)
  - `@ObservationIgnored var lockVerificationGeneration: UInt64`
  - `func scheduleLockVerification(delayNanoseconds: UInt64 = 2_000_000_000)` shared by `onDeviceLeft` and `lockNow`

- [ ] **Step 1: Write failing tests in `FUnlockTests/OrchestratorGatesTests.swift`**

```swift
func testSelfLockHandlesScreenLockedBeforeScreensaverStartWithoutFalseManualLock() {
    SystemInteractionService.sessionDictProvider = { ["CGSSessionScreenIsLocked": 1] }
    defer { SystemInteractionService.sessionDictProvider = nil }
    manager.beginSelfLockWindow()
    manager.onSystemScreenLocked()
    XCTAssertEqual(manager.state.intent, .autoLock)
    // Screensaver notification arriving 2s later within the 10s window must stay autoLock
    currentTime = currentTime.addingTimeInterval(2)
    manager.onScreensaverStart()
    XCTAssertEqual(manager.state.intent, .autoLock)
}

func testUnlockClearsSelfLockWindowSoSubsequentManualLockIsManual() {
    SystemInteractionService.sessionDictProvider = { ["CGSSessionScreenIsLocked": 0] }
    defer { SystemInteractionService.sessionDictProvider = nil }
    manager.beginSelfLockWindow()
    manager.onUnlock()
    SystemInteractionService.sessionDictProvider = { ["CGSSessionScreenIsLocked": 1] }
    manager.onSystemScreenLocked()
    XCTAssertTrue(manager.state.intent.isManualLockActive)
}
```

- [ ] **Step 2: Run targeted test to verify it fails**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FUnlockTests/OrchestratorGatesTests`
Expected: FAIL.

- [ ] **Step 3: Implement window & generation token in `FUnManager.swift` and `FUnManager+Events.swift`**
  - Remove global `selfLockingStartedAt`; add instance `selfLockWindowDeadline: Date?`, `beginSelfLockWindow(duration: TimeInterval = 10)` (sets `selfLockWindowDeadline = now.addingTimeInterval(duration)` and `isSelfLocking = true`), and `clearSelfLockWindow()`.
  - `onDeviceLeft` calls `beginSelfLockWindow()` and `scheduleLockVerification()`; `lockNow()` calls `clearSelfLockWindow()`, sets manual lock, and calls `scheduleLockVerification()`.
  - `onScreensaverStart()` and `onSystemScreenLocked()` both read `isWithinSelfLockWindow` without clearing each other; `onUnlock()` and `lockNow()` call `clearSelfLockWindow()`.
  - `scheduleLockVerification` increments `lockVerificationGeneration`, sleeps 2s, checks `self.lockVerificationGeneration == gen`, and rolls back `state.screen = .unlocked` if `!SystemInteractionService.shared.isSystemSessionLocked()`. (Keep backward compat for tests that directly set `manager.isSelfLocking = true`: `isSelfLocking`'s `didSet` sets `selfLockWindowDeadline = isSelfLocking ? now.addingTimeInterval(10) : nil`.)

- [ ] **Step 4: Run targeted test to verify it passes**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FUnlockTests/OrchestratorGatesTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add FUnlock/FUnManager.swift FUnlock/FUnManager+Events.swift FUnlockTests/OrchestratorGatesTests.swift
git commit -m "fix(state): replace one-shot isSelfLocking with instance window and generation-guarded lock verify"
```

---

### Task 8: Cancellable `systemWakeTask`, post-unlock `refreshProximityGrace`, heartbeat `lockOnIdle`, and deferred-lock retry (Spec Item 8)

**Files:**
- Modify: `FUnlock/FUnManager.swift:45-55`, `FUnlock/FUnManager.swift:123-127`, `FUnlock/FUnManager.swift:286-298`
- Modify: `FUnlock/FUnManager+Events.swift:51-75`, `FUnlock/FUnManager+Events.swift:223-267`
- Modify: `FUnlock/UnlockOrchestrator.swift:205-236`, `FUnlock/UnlockOrchestrator.swift:269-276`
- Modify: `FUnlock/FUnLockCoordinator.swift:255-266`, `FUnlock/FUnLockCoordinator.swift:360-374`
- Test: `FUnlockTests/PowerStateTests.swift`, `FUnlockTests/OrchestratorGatesTests.swift`

**Interfaces:**
- Consumes: `FUn.refreshProximityGrace()`, `WiFiMonitor.shared.currentSSID`
- Produces:
  - `FUnManager.systemWakeTask: Task<Void, Never>?`
  - `FUnManager.deferredLockTask: Task<Void, Never>?`
  - `FUnManager.trustedWiFiRecheckInterval: TimeInterval = 10.0` (test-injectable)

- [ ] **Step 1: Write failing tests in `FUnlockTests/PowerStateTests.swift` and `FUnlockTests/OrchestratorGatesTests.swift`**

```swift
func testSecondSleepCancelsPendingSystemWakeTask() async {
    let manager = FUnManager(fun: FUn())
    manager.systemWakeDelay = 0.2
    manager.onSystemSleep()
    manager.onSystemWake()
    manager.onSystemSleep() // rapid re-sleep before 0.2s expires
    try? await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertEqual(manager.state.system, .sleeping)
}

func testDeferredLockRetriesAfterLeavingTrustedWiFi() async {
    snapshotKeys(["enabled", "pauseOnWiFi", "pauseOnWiFiSSID", "sleepDisplay"])
    ConfigStore.shared.set(true, forKey: "enabled")
    ConfigStore.shared.set(true, forKey: "pauseOnWiFi")
    ConfigStore.shared.set("Office", forKey: "pauseOnWiFiSSID")
    var lockCalls = 0
    SystemInteractionService.lockActionOverride = { lockCalls += 1 }
    WiFiMonitor.ssidProvider = { "Office" }
    defer { WiFiMonitor.ssidProvider = nil }

    manager.trustedWiFiRecheckInterval = 0.05
    manager.state.screen = .unlocked
    manager.fun.lock.withLock {
        manager.fun.presence = false
        manager.fun.effectiveRSSI = -90
    }
    manager.onDeviceLeft(reason: "away")
    XCTAssertEqual(lockCalls, 0)

    WiFiMonitor.ssidProvider = { "Cafe" }
    try? await Task.sleep(nanoseconds: 150_000_000)
    XCTAssertEqual(lockCalls, 1)
}
```

- [ ] **Step 2: Run targeted tests to verify they fail**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FUnlockTests/PowerStateTests -only-testing:FUnlockTests/OrchestratorGatesTests`
Expected: FAIL.

- [ ] **Step 3: Implement Task 8 fixes**
  - `FUnManager`: add `@ObservationIgnored var systemWakeTask: Task<Void, Never>?` and `@ObservationIgnored var deferredLockTask: Task<Void, Never>?`; cancel both in `deinit` and `cleanup()`.
  - `onSystemSleep()` cancels `systemWakeTask`; `onSystemWake()` cancels any previous `systemWakeTask`, assigns new task, and verifies `self.state.system == .sleeping` before flipping to `.awake`.
  - `UnlockOrchestrator.performInjectionAndVerify`: on both `verification.unlock` AND `dualVerifyTimeoutCGSessionUnlocked`, set `state.screen = .unlocked`, `state.unlockedAt = now`, `lastUnlockTime = now`, and call `fun.refreshProximityGrace()`.
  - `FUnLockCoordinator.swift:256`: gate heartbeat input deferral by `let lockOnIdle = ConfigStore.shared.bool(forKey: "lockOnIdle", default: true); if lockOnIdle && inputActive { ... }`.
  - Move `SignalDataStore.shared.record(..., event: .locked)` from `FUnLockCoordinator.startLockTimer` to `FUnManager.onDeviceLeft` (only when locking actually executes).
  - In `FUnManager.onDeviceLeft`:
    - When blocked by `trustedWiFi`: schedule cancellable `deferredLockTask` polling every `trustedWiFiRecheckInterval` (default 10s); if screen locks or `fun.signalSnapshot().presence` turns `true`, exit; once `currentSSID != targetSSID` and device still away (`effectiveRSSI < lockThreshold`), re-invoke `onDeviceLeft(reason:)`.
    - When blocked by `withinUnlockGracePeriod`: schedule `deferredLockTask` for remaining grace seconds (<= 5s); on wake re-check `!presence && effectiveRSSI < lockThreshold` and re-invoke `onDeviceLeft(reason:)`.
    - Cancel `deferredLockTask` in `onDeviceApproached()` / `onSystemScreenLocked()` / `lockNow()`.

- [ ] **Step 4: Run targeted tests to verify they pass**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FUnlockTests/PowerStateTests -only-testing:FUnlockTests/OrchestratorGatesTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add FUnlock/FUnManager.swift FUnlock/FUnManager+Events.swift FUnlock/UnlockOrchestrator.swift FUnlock/FUnLockCoordinator.swift FUnlockTests/PowerStateTests.swift FUnlockTests/OrchestratorGatesTests.swift
git commit -m "fix(state): cancel systemWakeTask on re-sleep, refresh grace on verify, align lockOnIdle and deferred lock retry"
```

---

### Task 9: Unify `LOCK_DISABLED (-100)` sentinel semantics (Spec Item 9)

**Files:**
- Modify: `FUnlock/SignalHysteresisEngine.swift:98-115`
- Modify: `FUnlock/FUn.swift:293-313`
- Modify: `FUnlock/FUnLockCoordinator.swift:388-434`
- Test: `FUnlockTests/HysteresisEngineTests.swift`

**Interfaces:**
- Produces: `SignalHysteresisEngine.checkProximity`: when `lockRSSI == lockDisabled`, `isAway` is always `false`.

- [ ] **Step 1: Write/update failing test in `FUnlockTests/HysteresisEngineTests.swift`**

```swift
func testLockDisabledSentinelNeverReportsAway() {
    let d = SignalHysteresisEngine.checkProximity(
        effectiveRSSI: -95, unlockRSSI: -60, lockRSSI: SignalHysteresisEngine.lockDisabled)
    XCTAssertFalse(d.isAway, "LOCK_DISABLED means auto-lock is disabled and must never report isAway")
    XCTAssertFalse(d.isClose)
}
```

- [ ] **Step 2: Run targeted test to verify it fails**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FUnlockTests/HysteresisEngineTests`
Expected: FAIL (`isAway` currently returns `true` by falling back to `unlockRSSI`).

- [ ] **Step 3: Unify `LOCK_DISABLED` in `SignalHysteresisEngine.swift`, `FUn.swift`, and `FUnLockCoordinator.swift`**
  - In `SignalHysteresisEngine.checkProximity`: `let isAway = (lockRSSI == lockDisabled) ? false : effectiveRSSI < Double(lockThreshold)`.
  - In `FUn.scannerPollingContext`: when `_lockRSSI == Self.LOCK_DISABLED`, skip `nearLock` check (only check `nearClimb` if `_unlockRSSI != Self.UNLOCK_DISABLED`).
  - In `FUnLockCoordinator.applyLockTimer`: if `lRSSI == Self.LOCK_DISABLED`, cancel any `proximityTimer` and return early.
  - Update any existing test in `HysteresisEngineTests.swift` that asserted the old contradictory fallback behavior.

- [ ] **Step 4: Run targeted test to verify it passes**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FUnlockTests/HysteresisEngineTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add FUnlock/SignalHysteresisEngine.swift FUnlock/FUn.swift FUnlock/FUnLockCoordinator.swift FUnlockTests/HysteresisEngineTests.swift
git commit -m "fix(hysteresis): unify LOCK_DISABLED (-100) sentinel to disable away detection consistently"
```

---

### Task 10: Defer modal alerts while screen is locked (Spec Item 10)

**Files:**
- Modify: `FUnlock/SystemInteractionService.swift:566-626`
- Modify: `FUnlock/SecurityService.swift:55-82`
- Modify: `FUnlock/FUnManager+Events.swift:105-111`
- Test: `FUnlockTests/SecurityServiceTests.swift`

**Interfaces:**
- Consumes: `SystemInteractionService.isSystemSessionLocked()`
- Produces:
  - `enum DeferredAlertKind: Hashable { case noPassword, axRevoked, passwordMismatch, abnormalUnlock(count: Int, window: Int) }`
  - `SystemInteractionService.pendingAlerts: [DeferredAlertKind]` (MainActor, deduplicated)
  - `SystemInteractionService.enqueueOrPresentAlert(_ kind: DeferredAlertKind)` (defers + posts local notification if `isSystemSessionLocked()`, presents immediately if unlocked)
  - `SystemInteractionService.flushPendingAlerts()` (called in `FUnManager.onUnlock()`)

- [ ] **Step 1: Write failing test in `FUnlockTests/SecurityServiceTests.swift`**

```swift
@MainActor
func testAlertsAreDeferredWhileScreenLockedAndFlushedOnUnlock() {
    SystemInteractionService.sessionDictProvider = { ["CGSSessionScreenIsLocked": 1] }
    var presented: [DeferredAlertKind] = []
    SystemInteractionService.alertPresenterOverride = { presented.append($0) }
    defer {
        SystemInteractionService.sessionDictProvider = nil
        SystemInteractionService.alertPresenterOverride = nil
        SystemInteractionService.shared.clearPendingAlertsForTesting()
    }
    SystemInteractionService.shared.enqueueOrPresentAlert(.passwordMismatch)
    SystemInteractionService.shared.enqueueOrPresentAlert(.passwordMismatch) // dedup
    XCTAssertTrue(presented.isEmpty)
    XCTAssertEqual(SystemInteractionService.shared.pendingAlertsCount, 1)

    SystemInteractionService.sessionDictProvider = { ["CGSSessionScreenIsLocked": 0] }
    SystemInteractionService.shared.flushPendingAlerts()
    XCTAssertEqual(presented, [.passwordMismatch])
    XCTAssertEqual(SystemInteractionService.shared.pendingAlertsCount, 0)
}
```

- [ ] **Step 2: Run targeted test to verify it fails**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FUnlockTests/SecurityServiceTests`
Expected: FAIL (`DeferredAlertKind` not defined).

- [ ] **Step 3: Implement non-blocking lock-screen alert deferral**
  - Add `DeferredAlertKind`, `alertPresenterOverride` (for tests), `enqueueOrPresentAlert(_:)`, `flushPendingAlerts()`, and `clearPendingAlertsForTesting()` to `SystemInteractionService`.
  - Route `showAXRevokedAlertIfNeeded`, `showPasswordMismatchAlert`, `showAbnormalUnlockAlert`, and `SecurityService.fetchPassword(warn: true)` (no-password branch) through `enqueueOrPresentAlert(_:)`.
  - Call `SystemInteractionService.shared.flushPendingAlerts()` in `FUnManager.onUnlock()` right after handling `hasPendingPasswordChange`.

- [ ] **Step 4: Run targeted test to verify it passes**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FUnlockTests/SecurityServiceTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add FUnlock/SystemInteractionService.swift FUnlock/SecurityService.swift FUnlock/FUnManager+Events.swift FUnlockTests/SecurityServiceTests.swift
git commit -m "fix(ui): defer modal NSAlerts while screen is locked to prevent MainActor freeze"
```

---

### Task 11: Use real `login.framework` `SACLockScreenImmediate` and release `wakeDisplay` IOPMAssertion (Spec Item 11)

**Files:**
- Modify: `FUnlock/lowlevel.c:1-123`
- Modify: `FUnlock/SystemInteractionService.swift:338-384`
- Test: `FUnlockTests/PowerStateTests.swift`

**Interfaces:**
- Consumes: `/System/Library/PrivateFrameworks/login.framework/Versions/Current/login` (`SACLockScreenImmediate`), `os_unfair_lock`
- Produces: thread-safe `funlock_wakeDisplay` / `funlock_releaseWakeAssertion`, `dlopen`/`dlsym`-backed `SACLockScreenImmediate` with `IORequestIdle` fallback, and `wakeAssertionReleaser` hook for testing assertion release in `injectPasswordWithPrelude`.

- [ ] **Step 1: Write failing test in `FUnlockTests/PowerStateTests.swift`**

```swift
@MainActor
func testInjectPreludeReleasesWakeAssertionAfterWakingDisplay() async {
    var released = 0
    SystemInteractionService.displayPoweredOnProvider = { false }
    SystemInteractionService.wakeAssertionReleaseOverride = { released += 1 }
    defer {
        SystemInteractionService.displayPoweredOnProvider = nil
        SystemInteractionService.wakeAssertionReleaseOverride = nil
    }
    _ = await SystemInteractionService.shared.injectPasswordWithPrelude("pw") { false }
    XCTAssertEqual(released, 1)
}
```

- [ ] **Step 2: Run targeted test to verify it fails**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FUnlockTests/PowerStateTests`
Expected: FAIL (`wakeAssertionReleaseOverride` not defined).

- [ ] **Step 3: Update `lowlevel.c` and `SystemInteractionService.swift`**
  - In `lowlevel.c`:
    - Protect `wakeAssertionID` and `preventSleepAssertionID` with `static os_unfair_lock assertionLock = OS_UNFAIR_LOCK_INIT;`.
    - Replace CGEvent `Ctrl+Cmd+Q` simulation in `SACLockScreenImmediate(void)` with `dispatch_once` loading of `void (*fn)(void)` from `dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY)` + `dlsym(handle, "SACLockScreenImmediate")`. Call `fn()` and return `0` when found; fall back to `IORequestIdle` only if unavailable.
  - In `SystemInteractionService.swift`:
    - Add `nonisolated(unsafe) static var wakeAssertionReleaseOverride: (() -> Void)?`.
    - In `injectPasswordWithPrelude`: when `displayWasOff == true`, register `defer { Self.wakeAssertionReleaseOverride?() ?? funlock_releaseWakeAssertion() }` so the `kIOPMAssertionTypePreventUserIdleDisplaySleep` assertion created by `await wakeDisplay()` is always released.

- [ ] **Step 4: Run targeted test to verify it passes**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FUnlockTests/PowerStateTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add FUnlock/lowlevel.c FUnlock/SystemInteractionService.swift FUnlockTests/PowerStateTests.swift
git commit -m "fix(system): invoke login.framework SACLockScreenImmediate and release wake IOPMAssertion"
```

---

### Task 12: Fix `SignalPipeline` interruption reset and zero-IQR anomaly handling (Spec Item 12)

**Files:**
- Modify: `FUnlock/SignalPipeline.swift:80-154`, `FUnlock/SignalPipeline.swift:181-213`
- Test: `FUnlockTests/SignalPipelineTests.swift`

**Interfaces:**
- Consumes: `SignalPipeline.process(rssi:source:now:)`
- Produces: clean reset of `kalmanEstimate` and `smoothedSlope` on >30s interruption; minimum physical IQR floor (`2.0`) and non-contradictory anomaly weighting in `computeKalman`.

- [ ] **Step 1: Write failing tests in `FUnlockTests/SignalPipelineTests.swift`**

```swift
func testInterruptionOver30sResetsKalmanEstimateAndStaleNegativeSlope() {
    var p = SignalPipeline()
    let t0 = Date(timeIntervalSince1970: 1000)
    // Simulate steep walk-away leaving stale negative slope and low estimate
    for i in 0..<6 {
        let t = t0.addingTimeInterval(Double(i) * 0.5)
        let r = -55 - i * 6
        p.latestRSSIs.append(Double(r))
        p.rssiTimestamps.append(t)
        _ = p.process(rssi: r, source: .connected, now: t)
    }
    XCTAssertLessThan(p.smoothedSlope, -2.0)

    // 45s gap, then device returns strong at -50
    let tReturn = t0.addingTimeInterval(50)
    p.latestRSSIs.append(-50)
    p.rssiTimestamps.append(tReturn)
    let d = p.process(rssi: -50, source: .connected, now: tReturn)
    XCTAssertEqual(d.kalmanEstimate, -50.0, accuracy: 0.5)
    XCTAssertGreaterThanOrEqual(d.slope, -0.5)
}

func testZeroIQRWindowDoesNotFlag1dBmJitterAsAnomalous() {
    var p = SignalPipeline()
    let t0 = Date(timeIntervalSince1970: 2000)
    for i in 0..<8 {
        let t = t0.addingTimeInterval(Double(i))
        p.latestRSSIs.append(-65)
        p.rssiTimestamps.append(t)
        _ = p.process(rssi: -65, source: .connected, now: t)
    }
    let tNext = t0.addingTimeInterval(9)
    p.latestRSSIs.append(-66)
    p.rssiTimestamps.append(tNext)
    let d = p.process(rssi: -66, source: .connected, now: tNext)
    XCTAssertFalse(d.isAnomalous)
}
```

- [ ] **Step 2: Run targeted test to verify it fails**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FUnlockTests/SignalPipelineTests`
Expected: FAIL.

- [ ] **Step 3: Implement `SignalPipeline.swift` fixes**
  - In `S-1` (>30s gap): reset `kalmanEstimate = Double(rssi)`, `kalmanP = 1.0`, `kalmanSampleCount = 0`, `smoothedSlope = 0.0`, and prune `latestRSSIs`/`rssiTimestamps` to keep only the current sample so old timestamps don't distort EWLR slope.
  - In `applyIQR`: compute IQR on historical samples excluding the just-appended current sample (when `rawWindow.count > 1`, use `rawWindow.dropLast().suffix(iqrSampleCount)`), clamp `let effectiveIQR = max(iqr, 2.0)`, and compare `abs(rssi - (q1 + q3) / 2.0) > iqrMultiplier * effectiveIQR`.
  - In `computeKalman`: remove `anomTerm` from `q` amplification so anomalous spikes only halve `kalmanGain` without simultaneously inflating process noise.

- [ ] **Step 4: Run targeted test to verify it passes**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FUnlockTests/SignalPipelineTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add FUnlock/SignalPipeline.swift FUnlockTests/SignalPipelineTests.swift
git commit -m "fix(signal): reset estimate/slope after >30s gap and add IQR floor for flat windows"
```

---

### Task 13: Verify distributed lock/unlock notifications via CGSession & self-heal missed unlocks while keeping manualLock permanent (Spec Item 13)

**Files:**
- Modify: `FUnlock/FUnManager.swift:45-78`, `FUnlock/FUnManager.swift:123-126`, `FUnlock/FUnManager.swift:286-298`
- Modify: `FUnlock/FUnManager+Events.swift:25-186`, `FUnlock/FUnManager+Events.swift:189-221`
- Test: `FUnlockTests/OrchestratorGatesTests.swift`, `FUnlockTests/StateAndConfigTests.swift`

**Interfaces:**
- Consumes: `SystemInteractionService.shared.isSystemSessionLocked()`
- Produces:
  - `SystemInteractionService.isExplicitlyUnlockedSession() -> Bool` (`sessionDict != nil && !cgLocked && !screensaverRunning`)
  - `FUnManager.screenLockVerifyDelay: TimeInterval = 0.3` (test-injectable)
  - `@ObservationIgnored var screenLockVerifyTask: Task<Void, Never>?`
  - `FUnManager.reconcileUnlockedSessionIfNeeded()` (clears stale `.locked`/`.manualLock` ONLY when `isExplicitlyUnlockedSession()` is `true`)

- [ ] **Step 1: Write failing tests in `FUnlockTests/OrchestratorGatesTests.swift`**

```swift
func testSpoofedUnlockNotificationIgnoredWhenSessionStillLocked() {
    SystemInteractionService.sessionDictProvider = { ["CGSSessionScreenIsLocked": 1] }
    defer { SystemInteractionService.sessionDictProvider = nil }
    manager.onSystemScreenLocked()
    XCTAssertTrue(manager.state.intent.isManualLockActive)
    // Spoofed distributed notification while CGSession is still locked
    manager.onUnlock()
    XCTAssertTrue(manager.state.intent.isManualLockActive)
    XCTAssertNotEqual(manager.state.screen, .unlocked)
}

func testSpoofedLockNotificationDroppedAfterVerifyDelayWhenSessionUnlocked() async {
    SystemInteractionService.sessionDictProvider = { ["CGSSessionScreenIsLocked": 0] }
    SystemInteractionService.screensaverRunningProvider = { false }
    defer {
        SystemInteractionService.sessionDictProvider = nil
        SystemInteractionService.screensaverRunningProvider = nil
    }
    manager.screenLockVerifyDelay = 0.05
    manager.onSystemScreenLocked()
    XCTAssertFalse(manager.state.intent.isManualLockActive)
    try? await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(manager.state.screen, .unlocked)
    XCTAssertFalse(manager.state.intent.isManualLockActive)
}

func testScreenLockVerifyTaskCancelledByUnlockWithinWindow() async {
    SystemInteractionService.sessionDictProvider = { ["CGSSessionScreenIsLocked": 0] }
    SystemInteractionService.screensaverRunningProvider = { false }
    defer {
        SystemInteractionService.sessionDictProvider = nil
        SystemInteractionService.screensaverRunningProvider = nil
    }
    manager.screenLockVerifyDelay = 0.15
    manager.onSystemScreenLocked()
    manager.onUnlock()
    // Even if CGSession briefly flips later, cancelled task must not fire
    SystemInteractionService.sessionDictProvider = { ["CGSSessionScreenIsLocked": 1] }
    try? await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertEqual(manager.state.screen, .unlocked)
}

func testMissedUnlockNotificationSelfHealsOnDeviceApproachedWhenSessionUnlocked() {
    SystemInteractionService.sessionDictProvider = { ["CGSSessionScreenIsLocked": 1] }
    defer { SystemInteractionService.sessionDictProvider = nil }
    manager.onSystemScreenLocked()
    XCTAssertTrue(manager.state.intent.isManualLockActive)
    // User unlocked manually, but com.apple.screenIsUnlocked was dropped
    SystemInteractionService.sessionDictProvider = { ["CGSSessionScreenIsLocked": 0] }
    manager.onDeviceApproached()
    XCTAssertEqual(manager.state.screen, .unlocked)
    XCTAssertEqual(manager.state.intent, .autoLock)
}
```

- [ ] **Step 2: Run targeted tests to verify they fail**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FUnlockTests/OrchestratorGatesTests`
Expected: FAIL.

- [ ] **Step 3: Implement CGSession verification & self-healing**
  - Change `FUnManager.markManualLock()` to use `now.addingTimeInterval(FUnManager.manualLockIntentDuration)` (keep `LockIntent.isManualLockActive` permanent per spec & existing 4 security tests).
  - In `onUnlock()`: cancel `screenLockVerifyTask`; if `SystemInteractionService.shared.isSystemSessionLocked()` is `true`, log `spoofedUnlockIgnored` and return.
  - In `onSystemScreenLocked()`: if `SystemInteractionService.shared.isSystemSessionLocked()` is `true`, execute `applySystemScreenLocked()` synchronously immediately; if `false`, cancel previous `screenLockVerifyTask` and schedule a new task sleeping `screenLockVerifyDelay` (`0.3s`), then re-checking `isSystemSessionLocked()` — only apply if `true`, otherwise discard.
  - Add `reconcileUnlockedSessionIfNeeded()` and invoke it in `onDisplayWake()`, `onSystemWake()`, and `onDeviceApproached()`: when `state.screen != .unlocked || state.intent.isManualLockActive`, if `SystemInteractionService.shared.isExplicitlyUnlockedSession()` (CGSession dict non-nil, `CGSSessionScreenIsLocked != 1`, and no screensaver), align `state.screen = .unlocked` and `state.intent = .autoLock`.

- [ ] **Step 4: Run full Batch 2 regression test suite**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
Expected: ALL tests PASS (ensure existing tests that call `onSystemScreenLocked()` / `onUnlock()` without mocking `sessionDictProvider` are updated cleanly via `setUp` or explicit helper).

- [ ] **Step 5: Commit Batch 2**

```bash
git add FUnlock/FUnManager.swift FUnlock/FUnManager+Events.swift FUnlock/SystemInteractionService.swift FUnlockTests/
git commit -m "fix(security): verify distributed lock/unlock notifications via CGSession and self-heal missed unlocks"
```

---

## Batch 3: Security, Memory Safety, Auto-Update & Config (P0–P2)

### Task 14: Remove hardcoded Bark default key, redact key from export, enforce HTTPS (Spec Item 14)

**Files:**
- Modify: `FUnlock/BarkNotifier.swift:27-88`, `FUnlock/BarkNotifier.swift:91-150`
- Modify: `FUnlock/BarkSettingsCard.swift:6-34`
- Modify: `FUnlock/ConfigStore.swift:91-167`
- Test: `FUnlockTests/BarkNotifierTests.swift`, `FUnlockTests/ConfigStoreTests.swift`

**Interfaces:**
- Produces:
  - `BarkNotifier.Defaults.key = ""`
  - `BarkNotifier.buildURL(server:key:) -> URL?` returns `nil` if `key.isEmpty` OR `!base.hasPrefix("https://")`
  - `ConfigStore.sensitiveKeys: Set<String> = ["barkNotifyKey"]` (excluded on export, preserved on import)

- [ ] **Step 1: Write/update failing tests in `FUnlockTests/BarkNotifierTests.swift` and `FUnlockTests/ConfigStoreTests.swift`**

```swift
// BarkNotifierTests.swift
func testEmptyKeySkipsSendAndFailsTestNotification() {
    XCTAssertEqual(BarkNotifier.Defaults.key, "")
    enableBark()
    installSender()
    BarkNotifier.shared.send(.test)
    drainQueue()
    XCTAssertTrue(capturedRequests.isEmpty)
}

func testBuildURLRejectsNonHTTPSServer() {
    XCTAssertNil(BarkNotifier.buildURL(server: "http://api.day.app", key: "secret"))
    XCTAssertNil(BarkNotifier.buildURL(server: "ftp://api.day.app", key: "secret"))
    XCTAssertNotNil(BarkNotifier.buildURL(server: "https://api.day.app", key: "secret"))
}

// ConfigStoreTests.swift
func testExportRedactsBarkKeyAndImportRejectsHTTPServerWhilePreservingLocalKey() {
    store.set("my-secret-key", forKey: "barkNotifyKey")
    store.set("https://api.day.app", forKey: "barkNotifyServer")
    let json = store.exportAllSettings()!
    XCTAssertFalse(json.contains("my-secret-key"))

    let malicious = """
    {"enabled":"true","barkNotifyKey":"attacker","barkNotifyServer":"http://evil.com","_exportedKeys":"enabled,barkNotifyKey,barkNotifyServer"}
    """
    _ = store.importAllSettings(json: malicious)
    XCTAssertEqual(store.string(forKey: "barkNotifyKey"), "my-secret-key")
    XCTAssertNotEqual(store.string(forKey: "barkNotifyServer"), "http://evil.com")
}
```

- [ ] **Step 2: Run targeted tests to verify they fail**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FUnlockTests/BarkNotifierTests -only-testing:FUnlockTests/ConfigStoreTests`
Expected: FAIL.

- [ ] **Step 3: Implement Bark security hardening and ConfigStore redaction**
  - `BarkNotifier.swift`: set `Defaults.key = ""`; update `barkKey` to return `Self.normalizeKey(configStore.string(forKey: Keys.key) ?? "")` (no fallback); in `send(_:)`, `guard !barkKey.isEmpty else { return }`; in `sendTestNotification`, return `.failure` when `barkKey.isEmpty`; in `buildURL(server:key:)`, require `base.lowercased().hasPrefix("https://")`.
  - `BarkSettingsCard.swift`: default `@AppStorage("barkNotifyKey")` to `""`.
  - `ConfigStore.swift`: define `static let sensitiveKeys: Set<String> = ["barkNotifyKey"]`; skip `sensitiveKeys` during `exportAllSettings()` (both values and `_exportedKeys`) and during removal/application in `importAllSettings()`; during `importAllSettings()`, if `key == "barkNotifyServer"` and non-empty string does not start with `"https://"`, log error and skip writing it.
  - Update old `BarkNotifierTests.testEmptyKeyFallsBackToDefault` to assert the new empty-key rejection behavior.

- [ ] **Step 4: Run targeted tests to verify they pass**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FUnlockTests/BarkNotifierTests -only-testing:FUnlockTests/ConfigStoreTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add FUnlock/BarkNotifier.swift FUnlock/BarkSettingsCard.swift FUnlock/ConfigStore.swift FUnlockTests/BarkNotifierTests.swift FUnlockTests/ConfigStoreTests.swift
git commit -m "fix(security): remove hardcoded Bark key, redact from export, enforce HTTPS"
```

---

### Task 15: Fix SQLite `SQLITE_TRANSIENT` use-after-free and read-only DB opening (Spec Item 15)

**Files:**
- Modify: `FUnlock/LEDeviceInfo.swift:15-97`
- Test: `FUnlockTests/UIAndUtilityTests.swift`

**Interfaces:**
- Produces: `private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)` and testable `queryLEDeviceInfo(fromDB:table:columns:uuid:)` helper.

- [ ] **Step 1: Write failing test in `FUnlockTests/UIAndUtilityTests.swift`**

```swift
func testLEDeviceSQLiteQueryReadsTempDBReadOnlyAndBindsTransientSafely() throws {
    // Create a temporary SQLite DB with PairedDevices(Uuid, Name, Address, ResolvedAddress),
    // insert a row, query it via read-only open + SQLITE_TRANSIENT with a dynamically built UUID string,
    // and assert Name + parsed MAC address match.
}
```

- [ ] **Step 2: Run targeted test to verify it fails**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FUnlockTests/UIAndUtilityTests`
Expected: FAIL.

- [ ] **Step 3: Fix `FUnlock/LEDeviceInfo.swift`**
  - Replace `sqlite3_open(path, &db)` with `sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)`; on failure, call `if let d = db { sqlite3_close(d); db = nil }`.
  - Define `private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)` and pass it as the 5th argument to both `sqlite3_bind_text` calls (lines 55 & 82).
  - Expose an internal `openReadOnlyAndQueryPairedDevice(dbPath:uuid:) -> LEDeviceInfo?` helper used by both production and unit test.

- [ ] **Step 4: Run targeted test to verify it passes**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FUnlockTests/UIAndUtilityTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add FUnlock/LEDeviceInfo.swift FUnlockTests/UIAndUtilityTests.swift
git commit -m "fix(memory): use SQLITE_TRANSIENT and SQLITE_OPEN_READONLY in LEDeviceInfo"
```

---

### Task 16: Fix `UpdateDownloader` temp-file race and `UpdateInstaller` TeamID/shell safety (Spec Item 16)

**Files:**
- Modify: `FUnlock/UpdateDownloader.swift:80-127`
- Modify: `FUnlock/UpdateInstaller.swift:20-44`, `FUnlock/UpdateInstaller.swift:94-108`
- Test: `FUnlockTests/UpdateChainTests.swift`

**Interfaces:**
- Produces:
  - `UpdateInstaller.shellQuote(_ s: String) -> String` (POSIX single-quote escaping: `'...'` with `'` → `'\''`)
  - `UpdateInstaller.parseTeamId(fromOutput:) -> String?` (returns `nil` for `"not set"`, case-insensitive)

- [ ] **Step 1: Write failing tests in `FUnlockTests/UpdateChainTests.swift`**

```swift
func testParseTeamIdRejectsAdHocNotSet() {
    XCTAssertNil(UpdateInstaller.parseTeamId(fromOutput: "TeamIdentifier=not set\n"))
    XCTAssertNil(UpdateInstaller.parseTeamId(fromOutput: "TeamIdentifier=NOT SET\n"))
    XCTAssertEqual(UpdateInstaller.parseTeamId(fromOutput: "TeamIdentifier=JJYCS98SHK\n"), "JJYCS98SHK")
}

func testInstallScriptEscapesMetacharactersAndChecksCpExitStatus() {
    let weirdURL = URL(fileURLWithPath: "/tmp/it's $(rm -rf /)/FUnlock.app")
    let script = UpdateInstaller.makeInstallScript(appPath: weirdURL)
    XCTAssertTrue(script.contains("if cp -R \"$UPDATE\" \"$STAGING\"; then"))
    XCTAssertTrue(script.contains("it'\\''s $(rm -rf /)"))
    XCTAssertFalse(script.contains("UPDATE=\"/tmp/it's $(rm -rf /)/FUnlock.app\""))
}

func testDownloaderMovesLocationSynchronouslyBeforeCallbackReturns() throws {
    // Create a temp file simulating URLSession's ephemeral location,
    // invoke didFinishDownloadingTo, and immediately delete the original location path
    // on the next line (simulating URLSession cleanup) — assert zipPath exists in tempDir.
}
```

- [ ] **Step 2: Run targeted test to verify it fails**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FUnlockTests/UpdateChainTests`
Expected: FAIL.

- [ ] **Step 3: Implement `UpdateDownloader.swift` and `UpdateInstaller.swift` fixes**
  - `UpdateDownloader.swift`: inside `urlSession(_:downloadTask:didFinishDownloadingTo:)`, synchronously create `tempDir` if needed and call `try FileManager.default.moveItem(at: location, to: zipPath)` BEFORE dispatching `unzip` + verification to `DispatchQueue.global(qos: .userInitiated)`. On sync move failure, clean `tempDir` and report `.failed(...)`.
  - `UpdateInstaller.swift`:
    - In `parseTeamId`: reject `teamId.caseInsensitiveCompare("not set") == .orderedSame`.
    - Add `static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }`.
    - In `makeInstallScript`: assign `UPDATE=\(shellQuote(appPath.path))`, `UPDATE_DIR=\(shellQuote(updateDir.path))`, and replace `[ -d "$STAGING" ]` with `if cp -R "$UPDATE" "$STAGING"; then ... else rm -rf "$STAGING"; fi`.

- [ ] **Step 4: Run targeted test to verify it passes**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FUnlockTests/UpdateChainTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add FUnlock/UpdateDownloader.swift FUnlock/UpdateInstaller.swift FUnlockTests/UpdateChainTests.swift
git commit -m "fix(update): sync-move downloaded zip, reject ad-hoc TeamID, shell-quote and check cp status"
```

---

### Task 17: Fix `ConfigStore` type round-trip, `ProfileManager` sentinel preservation, `CalibrationWizardView` safety, and threshold/0-value config bounds (Spec Item 17)

**Files:**
- Modify: `FUnlock/ConfigStore.swift:99-183`
- Modify: `FUnlock/ProfileManager.swift:91-119`
- Modify: `FUnlock/CalibrationWizardView.swift:256-375`
- Modify: `FUnlock/FUnManager.swift:40`, `FUnlock/FUnManager.swift:142-154`
- Modify: `FUnlock/FUnManager+Events.swift:237-246`
- Modify: `FUnlock/AppDelegate.swift:501-509`
- Test: `FUnlockTests/ConfigStoreTests.swift`, `FUnlockTests/StateAndConfigTests.swift`

**Interfaces:**
- Produces:
  - `ConfigStore` schema-aware encode/decode preserving `String` vs `Int` vs `Bool` vs `Data` (and backward-compatible with legacy `"1"`/`"0"`/`"true"`/`"false"` JSON)
  - `FUnManager.isCalibrating: Bool` (blocks auto-lock while calibrating; resetting refreshes proximity grace)
  - `CalibrationWizardView.computeFinalThresholds(avgUnlock:avgLock:) -> (unlock: Int, lock: Int)` (pure static helper, clamped to `SignalHysteresisEngine.rssiRange` with `lock < unlock`)

- [ ] **Step 1: Write failing tests in `FUnlockTests/ConfigStoreTests.swift` and `FUnlockTests/StateAndConfigTests.swift`**

```swift
// ConfigStoreTests.swift
func testExportImportPreservesNumericStringsAndBooleans() {
    store.set("123456", forKey: "pauseOnWiFiSSID")
    store.set("13800138000", forKey: "iMessageNotifyRecipient")
    store.set(true, forKey: "enabled")
    store.set(false, forKey: "passiveMode")
    store.set(-65, forKey: "unlockRSSI")

    let json = store.exportAllSettings()!
    let roundtripSuite = "com.fuhahah.FUnlock.test-roundtrip-\(UUID().uuidString)"
    let imported = ConfigStore(suiteName: roundtripSuite)
    defer { imported.defaults.removePersistentDomain(forName: roundtripSuite) }
    _ = imported.importAllSettings(json: json)

    XCTAssertTrue(imported.object(forKey: "pauseOnWiFiSSID") is String)
    XCTAssertEqual(imported.string(forKey: "pauseOnWiFiSSID"), "123456")
    XCTAssertTrue(imported.object(forKey: "iMessageNotifyRecipient") is String)
    XCTAssertEqual(imported.bool(forKey: "enabled"), true)
    XCTAssertEqual(imported.bool(forKey: "passiveMode"), false)
    XCTAssertEqual(imported.object(forKey: "unlockRSSI") as? Int, -65)
}

// StateAndConfigTests.swift
func testProfileImportPreservesDisabledSentinels() {
    let json = """
    [{"id":"p1","name":"LockOnly","lockRSSI":-80,"unlockRSSI":1,"enabled":true},
     {"id":"p2","name":"UnlockOnly","lockRSSI":-100,"unlockRSSI":-60,"enabled":true}]
    """
    let pm = ProfileManager()
    _ = pm.importFrom(json: json)
    XCTAssertEqual(pm.profiles.first(where: { $0.id == "p1" })?.unlockRSSI, FUn.UNLOCK_DISABLED)
    XCTAssertEqual(pm.profiles.first(where: { $0.id == "p2" })?.lockRSSI, FUn.LOCK_DISABLED)
}

func testCalibrationFinalThresholdsAreClampedWithinRange() {
    let result = CalibrationWizardView.computeFinalThresholds(avgUnlock: -30, avgLock: -30)
    XCTAssertLessThanOrEqual(result.unlock, SignalHysteresisEngine.rssiRange.upperBound)
    XCTAssertLessThan(result.lock, result.unlock)
}

func testCalibrationBlocksAutoLockAndSetUnlockPreservesValidCustomLock() {
    let manager = FUnManager(fun: FUn())
    manager.setUnlockRSSI(-60)
    manager.setLockRSSI(-85)
    // Changing unlockRSSI to -65 keeps valid custom lockRSSI (-85 < -65)
    manager.setUnlockRSSI(-65)
    XCTAssertEqual(manager.lockRSSI, -85)
}
```

- [ ] **Step 2: Run targeted tests to verify they fail**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FUnlockTests/ConfigStoreTests -only-testing:FUnlockTests/StateAndConfigTests`
Expected: FAIL.

- [ ] **Step 3: Implement Task 17 fixes**
  - `ConfigStore.swift`: define explicit key-type sets (`boolKeys`, `intKeys`, `stringKeys`, `dataKeys`) so `exportAllSettings()` encodes `Bool` as `"true"`/`"false"` (using `CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()`), and `importAllSettings()` decodes each key by its declared type (with legacy `"1"`/`"0"` → `Bool` support for `boolKeys`, keeping `stringKeys` strictly `String`).
  - `ProfileManager.swift`: in `importFrom(json:)`, exempt `SignalHysteresisEngine.unlockDisabled` and `SignalHysteresisEngine.lockDisabled` from `clampRSSI` and `lock < unlock` clamping.
  - `CalibrationWizardView.swift`: extract `static func computeFinalThresholds(avgUnlock: Int, avgLock: Int) -> (unlock: Int, lock: Int)` (clamp both, apply `lockUnlockDelayGap`, re-clamp `unlock` to `rssiRange`, ensure `lock = min(lock, unlock - 1)`); display `finalThresholds.unlock`/`lock` in Step 5 so preview matches applied values; set `manager.isCalibrating = true` on `startUnlockCalibration()` and reset to `false` (calling `manager.fun.refreshProximityGrace()`) on `applyValues()`, `cancelAndClose()`, `abortCalibration()`, and `.onDisappear`; during sampling always read `snap.effectiveRSSI` when `manager.rssi != nil || snap.presence`.
  - `FUnManager.swift` & `FUnManager+Events.swift`: add `var isCalibrating = false` and guard `!isCalibrating` in `onDeviceLeft`; in `setUnlockRSSI(_:)`, only adjust `lockRSSI` when `lockRSSI != FUn.LOCK_DISABLED && lockRSSI >= value` (instead of blindly overwriting valid custom `lockRSSI`).
  - `AppDelegate.swift`: in `restoreSettingsToFUn()`, use `if let timeout = prefs.object(forKey: "timeout") as? Int, timeout > 0` and `if let lockDelay = prefs.object(forKey: "lockDelay") as? Int, lockDelay > 0`.

- [ ] **Step 4: Run full Batch 3 regression test suite**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
Expected: ALL tests PASS (if any existing test explicitly tested `setUnlockRSSI` forcing `lock = unlock - 10` even when custom lock was already `< unlock`, inspect and align with spec §5 Item 17 while preserving `OverviewView`'s UI slider auto-link).

- [ ] **Step 5: Commit Batch 3**

```bash
git add FUnlock/ConfigStore.swift FUnlock/ProfileManager.swift FUnlock/CalibrationWizardView.swift FUnlock/FUnManager.swift FUnlock/FUnManager+Events.swift FUnlock/AppDelegate.swift FUnlockTests/
git commit -m "fix(config): preserve export types, profile sentinels, calibration safety, and custom lock threshold"
```

---

## Batch 4: Logging, Performance, Test Isolation, CI & Docs (P2)

### Task 18: Make `timingLog` asynchronous, rate-limited by event name, with bounded cache (Spec Item 18)

**Files:**
- Modify: `FUnlock/FUnlockUtils.swift:42-114`
- Test: `FUnlockTests/LogRotationTests.swift`

**Interfaces:**
- Produces:
  - `timingLogEventKey(_ msg: String) -> String` (extracts `event=<name>` if present, else first whitespace-delimited token)
  - `flushTimingLogForTesting()` (drains `com.funlock.timingLog` serial queue)
  - Bounded `lastTimingWriteByType` (evicts entries > 60s when `count > 256`)

- [ ] **Step 1: Write failing tests in `FUnlockTests/LogRotationTests.swift`**

```swift
func testTimingLogThrottlesByEventNameIgnoringDynamicRSSI() {
    XCTAssertEqual(timingLogEventKey("event=attemptAutoUnlock rssi=-60.1"), "attemptAutoUnlock")
    // Write two lines within 1s differing only in rssi; flushTimingLogForTesting();
    // assert only 1 line was written to timing.log.
}
```

- [ ] **Step 2: Run targeted test to verify it fails**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FUnlockTests/LogRotationTests`
Expected: FAIL (`timingLogEventKey` not defined).

- [ ] **Step 3: Refactor `timingLog` in `FUnlock/FUnlockUtils.swift`**
  - Add `private let timingLogQueue = DispatchQueue(label: "com.funlock.timingLog", qos: .utility)`.
  - Implement `timingLogEventKey(_:)`, rate-limit by event key inside `timingLock`, prune stale entries when `lastTimingWriteByType.count > 256`, and dispatch file creation/rotation/write asynchronously onto `timingLogQueue`.
  - Add `flushTimingLogForTesting()` (`timingLogQueue.sync {}`).

- [ ] **Step 4: Run targeted test to verify it passes**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FUnlockTests/LogRotationTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add FUnlock/FUnlockUtils.swift FUnlockTests/LogRotationTests.swift
git commit -m "perf(log): make timingLog async with event-name throttling and bounded cache"
```

---

### Task 19: Put cheap gates first, handle unauthorized/unsupported BT state, fix lock decision screen label & 15s `connected` liveness (Spec Item 19)

**Files:**
- Modify: `FUnlock/UnlockOrchestrator+AutoUnlock.swift:42-104`
- Modify: `FUnlock/FUnManager+Events.swift:189-221`, `FUnlock/FUnManager+Events.swift:258-285`
- Modify: `FUnlock/BLEScanner.swift:218-238`
- Modify: `FUnlock/FUn.swift:268-285`
- Modify: `FUnlock/AppDelegate.swift:241-262`
- Test: `FUnlockTests/OrchestratorGatesTests.swift`

**Interfaces:**
- Consumes: `FUn.lastReceiveTime`, `SystemInteractionService.isSystemSessionLocked()`
- Produces:
  - `BLEScannerHost.scannerDidReportUnavailable(_:state:)` (default empty impl or implemented on `FUn` to log warning)
  - `FUn.isDeviceSignalAlive(now: Date = Date(), maxAge: TimeInterval = 15.0) -> Bool`

- [ ] **Step 1: Write failing tests in `FUnlockTests/OrchestratorGatesTests.swift`**

```swift
func testOnDeviceLeftRecordsLockedAwayScreenNotDisplaySleepingWhenSleepDisplayOff() {
    snapshotKeys(["enabled", "sleepDisplay", "pauseOnWiFi"])
    ConfigStore.shared.set(true, forKey: "enabled")
    ConfigStore.shared.set(false, forKey: "sleepDisplay")
    ConfigStore.shared.set(false, forKey: "pauseOnWiFi")
    manager.state.screen = .unlocked
    manager.onDeviceLeft(reason: "away")
    XCTAssertEqual(manager.state.screen, .locked(reason: .away))
    let lockEvent = logger.events.last { $0.category == .lock }
    XCTAssertEqual(lockEvent?.screen, "locked(away)")
}

func testIsDeviceSignalAliveExpiresAfter15SecondsWithoutActiveConnection() {
    let fun = FUn()
    let t0 = Date(timeIntervalSince1970: 5000)
    fun.lock.withLock { fun.lastReceiveTime = t0 }
    XCTAssertTrue(fun.isDeviceSignalAlive(now: t0.addingTimeInterval(10)))
    XCTAssertFalse(fun.isDeviceSignalAlive(now: t0.addingTimeInterval(16)))
}
```

- [ ] **Step 2: Run targeted test to verify it fails**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FUnlockTests/OrchestratorGatesTests`
Expected: FAIL.

- [ ] **Step 3: Implement Task 19 improvements**
  - `UnlockOrchestrator+AutoUnlock.swift`: move `sys.isScreenLocked(...)` call AFTER the cheap in-memory guards (`presence`, `unlockDisabled`, `effectiveRSSI >= unlockRSSI`, `canAttemptUnlock`, `lockBuffer`, `unlockCooldown`, `manualLock`, `pauseOnWiFi`), keeping all SKIP decision-logging order intact.
  - `FUnManager+Events.swift`: in `onDeviceApproached()`, early-return when `state.screen == .unlocked && !SystemInteractionService.shared.isSystemSessionLocked()` (after `reconcileUnlockedSessionIfNeeded()`); in `onDeviceLeft()`, set `state.screen = sleepDisplay ? .displaySleeping : .locked(reason: reason == "lost" ? .lost : .away)` and record `recordLock(lockReason)` with that accurate state.
  - `BLEScanner.swift` & `FUn.swift`: handle `.unauthorized` and `.unsupported` in `centralManagerDidUpdateState` with `AppLog.error`; reset `powerWarn = true` in `scannerDidPowerOn` (throttling repeat alerts to >= 60s); add `isDeviceSignalAlive(now:maxAge:)` and update `AppDelegate.connected` in `updatePresence` / `updateRSSI` accordingly.

- [ ] **Step 4: Run targeted test to verify it passes**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FUnlockTests/OrchestratorGatesTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add FUnlock/UnlockOrchestrator+AutoUnlock.swift FUnlock/FUnManager+Events.swift FUnlock/BLEScanner.swift FUnlock/FUn.swift FUnlock/AppDelegate.swift FUnlockTests/OrchestratorGatesTests.swift
git commit -m "perf(unlock): defer expensive OS lock queries behind cheap gates and fix lock observability"
```

---

### Task 20: Redact sensitive fields in `AppLog` and restrict `os_log` privacy (Spec Item 20)

**Files:**
- Modify: `FUnlock/AppLog.swift:32-70`
- Test: `FUnlockTests/AppLogTests.swift`

**Interfaces:**
- Produces: `AppLog.redactedValue(forKey key: String, value: String) -> String` (masks keys in `["ssid", "recipient", "key", "password", "barkKey"]`, e.g., first 2 chars + `"***"` or `"***"` for short values <= 3 chars).

- [ ] **Step 1: Write failing test in `FUnlockTests/AppLogTests.swift`**

```swift
func testAppLogRedactsSensitiveKeys() {
    let msg = AppLog.message("deviceLeftSkipped", [("reason", "trustedWiFi"), ("ssid", "MySecretOfficeWiFi")])
    XCTAssertFalse(msg.contains("MySecretOfficeWiFi"))
    XCTAssertTrue(msg.contains("ssid=My***"))
}
```

- [ ] **Step 2: Run targeted test to verify it fails**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FUnlockTests/AppLogTests`
Expected: FAIL.

- [ ] **Step 3: Implement redaction and `os_log` privacy in `FUnlock/AppLog.swift`**
  - Apply `redactedValue(forKey:value:)` inside `AppLog.message(_:_:)`.
  - Use `privacy: .private` in `os_log` when any sensitive key was present in `fields` (preserving `privacy: .public` for non-sensitive diagnostic events).

- [ ] **Step 4: Run targeted test to verify it passes**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FUnlockTests/AppLogTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add FUnlock/AppLog.swift FUnlockTests/AppLogTests.swift
git commit -m "fix(privacy): redact sensitive keys in AppLog and mark sensitive os_log entries private"
```

---

### Task 21: Auto-isolate all log writers under XCTest and install global `lockActionOverride` in `TestSupport` (Spec Item 21)

**Files:**
- Modify: `FUnlock/DebugLog.swift:11-16`
- Modify: `FUnlock/FUnlockUtils.swift:53-58`
- Modify: `FUnlock/TelemetryLogger.swift:43-49`, `FUnlock/TelemetryLogger.swift:84-89`
- Modify: `FUnlock/ScriptRunner.swift:22-28`
- Modify: `FUnlock/SystemInteractionService.swift:133-151`
- Modify: `FUnlockTests/TestSupport.swift`
- Modify: `FUnlockTests/Info.plist`
- Test: `FUnlockTests/LogRotationTests.swift`

**Interfaces:**
- Produces: automatic `NSClassFromString("XCTestCase") != nil` temp-dir redirection in `DebugLog`, `timingLog`, `TelemetryLogger`, and `ScriptRunner`; defense-in-depth XCTest guard in `lockOrSaveScreen`; `TestBundleGuard` registered via `NSPrincipalClass` in `FUnlockTests/Info.plist` installing `SystemInteractionService.lockActionOverride = {}`.

- [ ] **Step 1: Write failing test in `FUnlockTests/LogRotationTests.swift`**

```swift
func testAllLogWritersAutoIsolateFromProductionLogsUnderXCTest() {
    DebugLog.testLogDirectory = nil
    configureTimingLogForTesting(directory: nil)
    TelemetryLogger.shared.testLogDirectory = nil
    ScriptRunner.shared.testLogDirectory = nil
    let prodLogs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/FUnlock").path
    XCTAssertFalse(DebugLog.logDirectory.path.hasPrefix(prodLogs))
    XCTAssertFalse(timingLogDirectory.path.hasPrefix(prodLogs))
    XCTAssertFalse(TelemetryLogger.shared.testLogFile.path.hasPrefix(prodLogs))
    XCTAssertTrue(ScriptRunner.shared.eventsLogURL?.path.contains(FileManager.default.temporaryDirectory.path) == true)
}
```

- [ ] **Step 2: Run targeted test to verify it fails**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FUnlockTests/LogRotationTests`
Expected: FAIL.

- [ ] **Step 3: Implement XCTest isolation across log writers and `TestSupport.swift`**
  - Add `if NSClassFromString("XCTestCase") != nil` temp-dir redirect in `DebugLog.logDirectory`, `timingLogDirectory`, `TelemetryLogger.testLogFile`/`logDirectory`, and `ScriptRunner.eventsLogURL` (matching `DecisionLogger.swift:136`).
  - In `FUnlockTests/TestSupport.swift`, add an `XCTestObservation` class registered via a Swift `@objc` principal/observer or `XCTestCase` base/global installer so `SystemInteractionService.lockActionOverride = {}` is always active unless a test explicitly overrides it.

- [ ] **Step 4: Run targeted test to verify it passes**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FUnlockTests/LogRotationTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add FUnlock/DebugLog.swift FUnlock/FUnlockUtils.swift FUnlock/TelemetryLogger.swift FUnlock/ScriptRunner.swift FUnlockTests/TestSupport.swift FUnlockTests/LogRotationTests.swift
git commit -m "test(isolation): redirect all log writers to temp dir under XCTest and guard lockActionOverride globally"
```

---

### Task 22: Remove duplicate CI workflow `test.yml`, fix `README.md` inaccuracies, and run final Release verification (Spec Item 22)

**Files:**
- Delete: `.github/workflows/test.yml`
- Modify: `README.md:107-126`

- [ ] **Step 1: Delete `.github/workflows/test.yml` and update `README.md`**
  - Delete `.github/workflows/test.yml` (redundant with `.github/workflows/ci.yml` and missing `CODE_SIGNING_ALLOWED=NO`).
  - In `README.md`:
    - Update Keychain accessibility bullet to `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (noting why lock-screen auto-unlock requires readability after first unlock).
    - Update user script path to `~/Library/Application Scripts/com.fuhahah.FUnlock/event` (noting it follows the app's Bundle ID).

- [ ] **Step 2: Run full Debug test suite**

Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -derivedDataPath /tmp/FUnlock-dd CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
Expected: `** TEST SUCCEEDED **` with 0 failures and 0 Swift compiler warnings.

- [ ] **Step 3: Run Release team-signed build verification**

Run: `xcodebuild build -project FUnlock.xcodeproj -scheme FUnlock -configuration Release`
Expected: `** BUILD SUCCEEDED **`, and `codesign -dv` on the built `FUnlock.app` confirms `Identifier=com.fuhahah.FUnlock`, `TeamIdentifier=JJYCS98SHK`, `Signature=Apple Development`.

- [ ] **Step 4: Commit**

```bash
git rm .github/workflows/test.yml
git add README.md
git commit -m "chore(ci,docs): remove duplicate unsigned test.yml workflow and align README with implementation"
```
