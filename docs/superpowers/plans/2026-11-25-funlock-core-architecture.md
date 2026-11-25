# FUnlock Core Architecture (Plan A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor FUnlock into a single-process architecture powered by a zero-UI-dependency `FUnlockCore` pure-function state engine, a single `LiveDeadlineScheduler` replacing all 9 scattered timers, three-stage progressive unlock (`L0` bounded keep-alive → `L1` self-learning zero-injection → `L2` `memset_s` `CGEvent` injection), and three visibility-gated CQRS UI projections.

**Architecture:** Extract pure domain models, signal math, `DeadlineTable`, and `EngineReducer` into a local Swift Package (`Packages/FUnlockCore`, `Foundation` only) re-exported via `@_exported import FUnlockCore` so existing tests remain source-compatible. Replace scattered `RunLoop` timers and `SignalDataStore`'s background 1Hz copy loop with a single `LiveDeadlineScheduler` and `TimelineView`-driven chart snapshots, while layering `PowerKeepAliveAdapter` (`L0`), `L1` native Watch unlock cooperation, `SecretUTF16Buffer` (`L2`), and `NegativeSignalAdapter` behind the proven `NSStatusItem` shell. Execution splits work between **Antigravity** (core `EngineReducer`, security-critical `L0/L1/L2` & `SecretUTF16Buffer`, code review) and **Claude Desktop via `agent-hud`** (mechanical package extraction, `project.pbxproj` wiring, UI projection plumbing, cleanup, and CLI `swift test` / `xcodebuild` runs in `/Volumes/SSD/fuhaha_workspace/FUnlock`).

**Tech Stack:** Swift 5.9+ (`SWIFT_STRICT_CONCURRENCY = complete`), SwiftPM local package (`FUnlockCore`), AppKit (`NSStatusItem`, `NSPopover`, `NSWindow`), SwiftUI (`@Observable`, `TimelineView`, Swift Charts), CoreBluetooth, IOKit (`IOPMAssertion`), CoreAudio, Network (`NWPathMonitor`), Security (`SecItemCopyMatching`, `memset_s`).

**Spec:** `docs/superpowers/specs/2026-11-25-funlock-core-architecture-design.md`

## Global Constraints

- Target macOS 14.0+, `SWIFT_STRICT_CONCURRENCY = complete` with zero concurrency warnings; Release builds must retain team `JJYCS98SHK` (`Apple Development`) automatic signing so TCC `Accessibility` trust persists across restarts.
- `Packages/FUnlockCore` may ONLY `import Foundation` (zero AppKit, SwiftUI, CoreBluetooth, IOKit, or `ConfigStore` imports).
- Preserve all 22 safety and correctness invariants from `2026-11-24`: two-phase `isSecureToInject` (`allowScreensaver: true` in prelude, `false` in keystrokes; `nil` frontmost requires `CGSSessionScreenIsLocked == 1`), display-off blind-typing abort, `10s` `selfLockWindow`, `2.0s` `lockVerify` rollback, `0.3s`/`0.4s` distributed notification `CGSession` verification, single-sample drop `staleLossDeadline` guard, `XCTestCase` no-real-lock guard, and `com.fuhahah.Funlock.config.xctest` suite isolation.
- Never replace `NSStatusItem` + `NSPopover`/`NSWindow` with SwiftUI `MenuBarExtra`.
- Keep new source files focused on a single responsibility (target ≤ 300–350 lines per file).
- Preserve `com.fuhahah.Funlock.config` keys, Keychain item schema, `decisions.jsonl` schema, and user script CLI arguments (`away` / `lost` / `unlocked` / `intruded`).

## Review Focus

1. **Rapid sleep/wake bounce (`systemSleep` → `systemWake` → `systemSleep` within 0.4s before the 1.0s `systemWakeReady` deadline fires)**: The second `systemSleep` must cancel `.systemWakeReady` so the engine never flips `systemPower` to `.awake` or initiates unlock while the Mac is asleep (pinned in Task 2: `testRapidSecondSleepCancelsPendingSystemWakeReady`).
2. **Stale deadline delivery (`LiveDeadlineScheduler` delivers `.deadlineFired(id, scheduledAt)` after `deadlines[id]` was already cleared or pushed forward)**: Reducer must verify `state.deadlines.matches(id, scheduledAt: scheduledAt)` and ignore stale fires with zero state mutation or side effects (pinned in Task 1: `testMatchesRejectsReplacedOrClearedDeadline` and Task 2: `testStaleLockConfirmDeadlineIsIgnoredAfterReset`).
3. **Non-BMP / Emoji / CJK UTF-16 surrogate pairs in Keychain password (`SecretUTF16Buffer`)**: Multi-byte UTF-8 passwords (e.g. `"Päss🔑12345678901234567890"`) must decode into exact UTF-16 `UniChar` units without `0xFEFF` BOM, step back from 20 to 19 units whenever index `offset + 19` is a high surrogate (`0xD800...0xDBFF`) so surrogate pairs are never torn across `CGEvent` batches, and zero memory via `memset_s` on `wipe()` (pinned in Task 5: `testSurrogatePairTranscodingBatchSplitAndZeroing`).
4. **Phone left on desk overnight (`wakeOnProximity = true`, `keepAliveWhilePresent = true`, `idleSeconds >= 900`)**: Once 15 minutes of zero HID input elapses, L0 must release keep-alive and latch `idleSleepLatched = true` on `displaySleep`, blocking all subsequent strong RSSI samples from re-waking the screen until `presence` flips `false` or `idleSeconds < 2.0` (pinned in Task 3: `testPhoneLeftOnDeskAfter15MinIdleLatchesWakeUntilDepartureOrInput`).
5. **Unbinding or switching monitored device mid-unlock (`.waitingNativeUnlock` / `.wakingDisplay`) or mid-lock countdown (`.lockConfirm`)**: `unbindDevice` / `selectDevice` must atomically emit `.setKeepAlive(false)`, reset `unlockPhase` to `.idle`, clear `lockConfirmContext`, and cancel all device-scoped deadlines (pinned in Task 3: `testUnbindMidUnlockCancelsPhaseReleasesKeepAliveAndClearsDeadlines`).

---

### Task 1: Bootstrap `Packages/FUnlockCore` Pure Domain, Signal Math & `DeadlineTable`
**Owner:** Claude Desktop via `agent-hud` (Reviewed by Antigravity)

**Files:**
- Create: `Packages/FUnlockCore/Package.swift`
- Create: `Packages/FUnlockCore/Sources/FUnlockCore/Domain/LockScreenState.swift`
- Create: `Packages/FUnlockCore/Sources/FUnlockCore/Domain/DeviceSnapshot.swift`
- Create: `Packages/FUnlockCore/Sources/FUnlockCore/Signal/RingBuffer.swift`
- Create: `Packages/FUnlockCore/Sources/FUnlockCore/Signal/SignalSample.swift`
- Create: `Packages/FUnlockCore/Sources/FUnlockCore/Signal/SignalPipeline.swift`
- Create: `Packages/FUnlockCore/Sources/FUnlockCore/Signal/SignalHysteresisEngine.swift`
- Create: `Packages/FUnlockCore/Sources/FUnlockCore/Scheduler/DeadlineTable.swift`
- Create: `Packages/FUnlockCore/Tests/FUnlockCoreTests/DeadlineTableTests.swift`
- Create: `FUnlock/CoreBridge.swift`
- Delete: `FUnlock/LockScreenState.swift`, `FUnlock/DeviceSnapshot.swift`, `FUnlock/RingBuffer.swift`, `FUnlock/SignalPipeline.swift`, `FUnlock/SignalHysteresisEngine.swift`, `docs/antigravity-architecture-reply.md`
- Modify: `FUnlock/SignalDataStore.swift:1-30` (remove moved `SignalSampleEvent` / `SignalSample` declarations)
- Modify: `FUnlock/FUn.swift:37-47` (remove moved global constants now in `FUnlockCore`)
- Modify: `FUnlock.xcodeproj/project.pbxproj` (add local package `Packages/FUnlockCore` dependency to `FUnlock` and `FUnlockTests`, register `CoreBridge.swift`, remove deleted file refs)
- Modify: `README.md:1-7` (remove `NotchEvery` archive notice block)

**Interfaces:**
- Consumes: Existing pure logic in `LockScreenState.swift`, `DeviceSnapshot.swift`, `RingBuffer.swift`, `SignalPipeline.swift`, `SignalHysteresisEngine.swift`, `SignalDataStore.swift`.
- Produces:
  - `FUnlockCore` module (`@_exported import FUnlockCore` in `FUnlock/CoreBridge.swift` + `extension SignalHysteresisEngine { static func offsetSetting(_ key: String, default dft: Int) -> Int }` kept in `CoreBridge.swift` so `FUnlockCore` has zero `ConfigStore` dependency).
  - `public enum DeadlineID: Hashable, Sendable` with cases: `.activePoll`, `.peripheralConnectTimeout`, `.heartbeat`, `.signalTimeout`, `.lockConfirm`, `.deferredLockRecheck`, `.lockVerify`, `.screenLockConfirm`, `.screenUnlockConfirm`, `.systemWakeReady`, `.wakeRetry`, `.unlockDelay`, `.l1NativeCheck`, `.intrudeCheck`, `.keepAliveRenew`, `.uiDiscoveryFlush`, `.deviceExpiry(UUID)`.
  - `public struct DeadlineTable: Equatable, Sendable` with `public init()`, `public subscript(_ id: DeadlineID) -> Date?`, `public mutating func set(_ id: DeadlineID, at date: Date)`, `public mutating func cancel(_ id: DeadlineID)`, `public mutating func cancelMonitorDeadlines()`, `public mutating func cancelAllDeviceExpiries()`, `public func earliest() -> (id: DeadlineID, date: Date)?`, `public func matches(_ id: DeadlineID, scheduledAt: Date) -> Bool`.

- [ ] **Step 1: Create `Packages/FUnlockCore` and write failing `DeadlineTableTests`**

```swift
import XCTest
import FUnlockCore

final class DeadlineTableTests: XCTestCase {
    func testEarliestReturnsMinimumDeadlineAcrossKinds() {
        var table = DeadlineTable()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        table.set(.heartbeat, at: t0.addingTimeInterval(8))
        table.set(.lockConfirm, at: t0.addingTimeInterval(2.5))
        table.set(.deviceExpiry(UUID()), at: t0.addingTimeInterval(60))

        let earliest = table.earliest()
        XCTAssertEqual(earliest?.id, .lockConfirm)
        XCTAssertEqual(earliest?.date, t0.addingTimeInterval(2.5))
    }

    func testMatchesRejectsReplacedOrClearedDeadline() {
        var table = DeadlineTable()
        let t1 = Date(timeIntervalSince1970: 1_700_000_010)
        let t2 = t1.addingTimeInterval(5)
        table.set(.lockConfirm, at: t1)
        XCTAssertTrue(table.matches(.lockConfirm, scheduledAt: t1))

        table.set(.lockConfirm, at: t2)
        XCTAssertFalse(table.matches(.lockConfirm, scheduledAt: t1))
        XCTAssertTrue(table.matches(.lockConfirm, scheduledAt: t2))

        table.cancel(.lockConfirm)
        XCTAssertFalse(table.matches(.lockConfirm, scheduledAt: t2))
        XCTAssertNil(table.earliest())
    }
}
```

- [ ] **Step 2: Run package test to verify failure before `DeadlineTable` implementation**

Run: `swift test --package-path Packages/FUnlockCore`
Expected: FAIL (`DeadlineTable` / `DeadlineID` unresolved)

- [ ] **Step 3: Implement `FUnlockCore` public types, `DeadlineTable`, `CoreBridge.swift`, Xcode local package link, and repository cleanup**

Add `public` access modifiers to all moved types/members/initializers in `Packages/FUnlockCore/Sources/FUnlockCore/` so `@_exported import FUnlockCore` in `FUnlock/CoreBridge.swift` exposes identical symbols to `FUnlock` and `@testable import FUnlock` in `FUnlockTests`. Remove `README.md` lines 3–6 (`NotchEvery` notice) and delete `docs/antigravity-architecture-reply.md`.

- [ ] **Step 4: Run `FUnlockCore` tests and full `FUnlockTests` suite**

Run: `swift test --package-path Packages/FUnlockCore && xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' test`
Expected: PASS on both test suites with zero warnings.

- [ ] **Step 5: Commit**

```bash
git add Packages/FUnlockCore FUnlock FUnlock.xcodeproj README.md
git rm -f docs/antigravity-architecture-reply.md
git commit -m "refactor(core): extract pure FUnlockCore package, add DeadlineTable, and clean repo"
```

---

### Task 2: Implement Pure `EngineState` & `EngineReducer` (BLE, Session, Lock & Deadlines)
**Owner:** Antigravity (CLI test execution & commit via Claude Desktop)

**Files:**
- Create: `Packages/FUnlockCore/Sources/FUnlockCore/Engine/EngineModel.swift`
- Create: `Packages/FUnlockCore/Sources/FUnlockCore/Engine/EngineReducer.swift`
- Create: `Packages/FUnlockCore/Sources/FUnlockCore/Engine/EngineReducer+LockAndSession.swift`
- Create: `Packages/FUnlockCore/Tests/FUnlockCoreTests/EngineReducerLockAndSessionTests.swift`

**Interfaces:**
- Consumes: `DeadlineID`, `DeadlineTable`, `SignalPipeline`, `SignalHysteresisEngine`, `ScreenState`, `SystemPowerState`, `LockIntent`, `DeviceSnapshot`.
- Produces:
  - `public struct EngineConfig: Equatable, Sendable` (`enabled: Bool`, `unlockRSSI: Int`, `lockRSSI: Int`, `proximityTimeout: TimeInterval`, `signalTimeout: TimeInterval`, `wakeAdvance: Int`, `preUnlockTrigger: Int`, `wakeOnProximity: Bool`, `wakeWithoutUnlocking: Bool`, `useScreensaver: Bool`, `sleepDisplay: Bool`, `lockOnIdle: Bool`, `keepAliveWhilePresent: Bool`, `preferNativeWatchUnlock: Bool`, `pauseOnWiFi: Bool`, `pauseOnWiFiSSID: String`, `passiveMode: Bool`, `isKnownIPhone: Bool`)
  - `public enum L1TriggerReason: Equatable, Sendable { case watchObserved, coldBoot }`
  - `public enum UnlockPhase: Equatable, Sendable { case idle, wakingDisplay(attempt: Int, parallelUnlockScheduled: Bool), waitingDelay, waitingNativeUnlock(startedAt: Date, reason: L1TriggerReason), injecting, cooldown(until: Date), degraded }`
  - `public enum NegativeHintSource: String, Equatable, Sendable { case audioOutputDisconnected, networkChanged }`
  - `public struct LockConfirmContext: Equatable, Sendable` (`startedAt: Date`, `pollIntervalBefore: TimeInterval`, `extendedOnce: Bool`)
  - `public struct EngineState: Equatable, Sendable` (all fields defined in Spec §5.2.1, including `idleSleepLatched: Bool`, `selfWakeStartedAt: Date?`, `watchAutoUnlockObserved: Bool`, `consecutiveL1Timeouts: Int`, `keepAliveActive: Bool`, `deadlines: DeadlineTable`)
  - `public enum EngineEvent: Equatable, Sendable` & `public enum EngineEffect: Equatable, Sendable`
  - `public enum EngineReducer { public static func reduce(state: inout EngineState, event: EngineEvent, config: EngineConfig, now: Date) -> [EngineEffect] }`

- [ ] **Step 1: Write failing `EngineReducerLockAndSessionTests` in `Packages/FUnlockCore/Tests/FUnlockCoreTests/EngineReducerLockAndSessionTests.swift`**

```swift
import XCTest
import FUnlockCore

final class EngineReducerLockAndSessionTests: XCTestCase {
    func testSingleSampleDropExtendsOnceBeforeLocking() {
        var state = EngineState()
        let config = EngineConfig.defaultForTesting(unlockRSSI: -60, lockRSSI: -80)
        var now = Date(timeIntervalSince1970: 1_700_000_000)

        _ = EngineReducer.reduce(state: &state, event: .bindDevice(uuid: UUID(), name: "Watch"), config: config, now: now)
        _ = EngineReducer.reduce(state: &state, event: .bleSample(rssi: -52, source: .connected, idleSeconds: 30), config: config, now: now)
        XCTAssertTrue(state.presence)

        // Sharp single-sample drop with 8s prior poll interval -> starts lockConfirm, probes RSSI, extends once if no sample by 2.5s
        state.activePollInterval = 8.0
        now.addTimeInterval(8.0)
        let dropEffects = EngineReducer.reduce(state: &state, event: .bleSample(rssi: -88, source: .connected, idleSeconds: 30), config: config, now: now)
        XCTAssertTrue(dropEffects.contains(.probeRSSIImmediately))
        guard let firstDeadline = state.deadlines[.lockConfirm] else { return XCTFail("Missing lockConfirm") }

        // Fire at firstDeadline with NO new sample -> extends to staleLossDeadline (12s total) instead of locking immediately
        let extendEffects = EngineReducer.reduce(
            state: &state,
            event: .deadlineFired(.lockConfirm, scheduledAt: firstDeadline, idleSeconds: 40, currentSSID: nil, sessionLocked: false),
            config: config,
            now: firstDeadline
        )
        XCTAssertFalse(extendEffects.contains(where: { if case .performLock = $0 { return true }; return false }))
        guard let secondDeadline = state.deadlines[.lockConfirm] else { return XCTFail("Expected extended deadline") }
        XCTAssertGreaterThan(secondDeadline, firstDeadline)

        // Second fire reaches staleLossDeadline -> settles and locks
        let settleEffects = EngineReducer.reduce(
            state: &state,
            event: .deadlineFired(.lockConfirm, scheduledAt: secondDeadline, idleSeconds: 50, currentSSID: nil, sessionLocked: false),
            config: config,
            now: secondDeadline
        )
        XCTAssertTrue(settleEffects.contains(.performLock(reason: "away", useScreensaver: false, sleepDisplay: false)))
    }

    func testStaleLockConfirmDeadlineIsIgnoredAfterReset() {
        var state = EngineState()
        let config = EngineConfig.defaultForTesting(unlockRSSI: -60, lockRSSI: -80)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let staleTime = now.addingTimeInterval(5.0)
        state.presence = true
        state.deadlines.set(.lockConfirm, at: staleTime)
        state.deadlines.cancel(.lockConfirm)

        let effects = EngineReducer.reduce(
            state: &state,
            event: .deadlineFired(.lockConfirm, scheduledAt: staleTime, idleSeconds: 60, currentSSID: nil, sessionLocked: false),
            config: config,
            now: staleTime
        )
        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(state.screen, .unlocked)
    }

    func testRapidSecondSleepCancelsPendingSystemWakeReady() {
        var state = EngineState()
        let config = EngineConfig.defaultForTesting()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        _ = EngineReducer.reduce(state: &state, event: .systemWillSleep, config: config, now: t0)
        _ = EngineReducer.reduce(state: &state, event: .systemDidWake, config: config, now: t0.addingTimeInterval(0.2))
        guard let wakeDeadline = state.deadlines[.systemWakeReady] else { return XCTFail("Expected systemWakeReady") }

        // Second sleep arrives 0.4s later before 1.0s wake deadline
        _ = EngineReducer.reduce(state: &state, event: .systemWillSleep, config: config, now: t0.addingTimeInterval(0.6))
        XCTAssertNil(state.deadlines[.systemWakeReady])

        // Even if stale timer fires at wakeDeadline, systemPower stays .sleeping
        let effects = EngineReducer.reduce(
            state: &state,
            event: .deadlineFired(.systemWakeReady, scheduledAt: wakeDeadline, idleSeconds: 10, currentSSID: nil, sessionLocked: true),
            config: config,
            now: wakeDeadline
        )
        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(state.systemPower, .sleeping)
    }
}
```

- [ ] **Step 2: Run `swift test` to confirm failure**

Run: `swift test --package-path Packages/FUnlockCore`
Expected: FAIL (`EngineState` / `EngineReducer` undefined)

- [ ] **Step 3: Implement `EngineModel.swift`, `EngineReducer.swift`, and `EngineReducer+LockAndSession.swift`**

Implement pure `decayedEffectiveRSSI`, `LockTimerSettlement`, 3-strike `.signalTimeout` (`lost`), adaptive `.heartbeat` (`8s/3s/2s`) and `.activePoll` (`0.5s/2.0s/8.0s`), `selfLockWindow` (`10s`), `.screenLockConfirm` (`0.3s`), `.screenUnlockConfirm` (`0.4s`), `.lockVerify` (`2.0s` rollback), and `.systemWakeReady` (`1.0s`).

- [ ] **Step 4: Run `swift test` to verify all lock/session reducer tests pass**

Run: `swift test --package-path Packages/FUnlockCore`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Packages/FUnlockCore
git commit -m "feat(core): implement pure EngineState and EngineReducer for BLE, lock, and session flows"
```

---

### Task 3: Implement Three-Stage Progressive Unlock (`L0 → L1 → L2`) & Negative Hints in `EngineReducer`
**Owner:** Antigravity (CLI test execution & commit via Claude Desktop)

**Files:**
- Create: `Packages/FUnlockCore/Sources/FUnlockCore/Engine/EngineReducer+Unlock.swift`
- Create: `Packages/FUnlockCore/Tests/FUnlockCoreTests/EngineReducerUnlockTests.swift`
- Modify: `Packages/FUnlockCore/Sources/FUnlockCore/Engine/EngineReducer.swift` (wire unlock, keep-alive, unbind, and negative hint branches)

**Interfaces:**
- Consumes: `EngineState`, `EngineEvent`, `EngineEffect`, `EngineConfig`, `DeadlineTable` from Task 2.
- Produces:
  - Complete `EngineEffect` outputs for unlock/keep-alive: `.setKeepAlive(Bool)`, `.wakeDisplay`, `.releaseWakeAssertion`, `.checkPasswordStatus`, `.pollSessionUnlocked`, `.injectPassword`, `.persistWatchAutoUnlockObserved(Bool)`, `.recordDecision(...)`, `.runScript(...)`, `.probeRSSIImmediately`.

- [ ] **Step 1: Write failing `EngineReducerUnlockTests` covering L0 cap/latch, L1 Touch ID exclusion & 3-timeout decay, and unbind safety**

```swift
import XCTest
import FUnlockCore

final class EngineReducerUnlockTests: XCTestCase {
    func testPhoneLeftOnDeskAfter15MinIdleLatchesWakeUntilDepartureOrInput() {
        var state = EngineState()
        let config = EngineConfig.defaultForTesting(wakeOnProximity: true, keepAliveWhilePresent: true)
        var now = Date(timeIntervalSince1970: 1_700_000_000)

        _ = EngineReducer.reduce(state: &state, event: .bindDevice(uuid: UUID(), name: "iPhone"), config: config, now: now)
        let rssiEffects = EngineReducer.reduce(state: &state, event: .bleSample(rssi: -50, source: .connected, idleSeconds: 10), config: config, now: now)
        XCTAssertTrue(state.keepAliveActive)
        XCTAssertTrue(rssiEffects.contains(.setKeepAlive(true)))

        // At 900s idle, keep-alive renew releases assertion
        now.addTimeInterval(900)
        guard let renewAt = state.deadlines[.keepAliveRenew] else { return XCTFail("Missing keepAliveRenew") }
        let capEffects = EngineReducer.reduce(
            state: &state,
            event: .deadlineFired(.keepAliveRenew, scheduledAt: renewAt, idleSeconds: 900, currentSSID: nil, sessionLocked: false),
            config: config,
            now: now
        )
        XCTAssertFalse(state.keepAliveActive)
        XCTAssertTrue(capEffects.contains(.setKeepAlive(false)))

        // Display goes to sleep with phone still present and idle >= 900 -> latches wakeOnProximity
        _ = EngineReducer.reduce(state: &state, event: .displayDidSleep(idleSeconds: 905), config: config, now: now.addingTimeInterval(5))
        XCTAssertTrue(state.idleSleepLatched)

        // Strong BLE packet arrives while phone sits on desk -> must NOT wake display
        let suppressed = EngineReducer.reduce(state: &state, event: .bleSample(rssi: -48, source: .connected, idleSeconds: 910), config: config, now: now.addingTimeInterval(10))
        XCTAssertFalse(suppressed.contains(.wakeDisplay))

        // Real HID input (< 2.0s) clears latch
        _ = EngineReducer.reduce(state: &state, event: .bleSample(rssi: -48, source: .connected, idleSeconds: 0.5), config: config, now: now.addingTimeInterval(15))
        XCTAssertFalse(state.idleSleepLatched)
    }

    func testManualWakeTouchIDNeverTriggersWatchSelfLearning() {
        var state = EngineState()
        let config = EngineConfig.defaultForTesting(isKnownIPhone: false)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        state.presence = true
        state.effectiveRSSI = -50
        state.screen = .displaySleeping
        // User opens lid / manual wake (selfWakeStartedAt == nil) + unlocks via Touch ID (idleSeconds == 10)
        _ = EngineReducer.reduce(state: &state, event: .displayDidWake(systemLocked: true), config: config, now: now)
        _ = EngineReducer.reduce(state: &state, event: .sessionUnlockedConfirmed(idleSeconds: 10), config: config, now: now.addingTimeInterval(0.8))
        XCTAssertFalse(state.watchAutoUnlockObserved)
    }

    func testSelfWakeNativeUnlockLearnsAndThreeTimeoutsDecayBackToDirectL2() {
        var state = EngineState()
        let config = EngineConfig.defaultForTesting(wakeOnProximity: true, isKnownIPhone: false)
        var now = Date(timeIntervalSince1970: 1_700_000_000)

        state.screen = .displaySleeping
        _ = EngineReducer.reduce(state: &state, event: .bindDevice(uuid: UUID(), name: "Apple Watch"), config: config, now: now)
        _ = EngineReducer.reduce(state: &state, event: .bleSample(rssi: -52, source: .scanning, idleSeconds: 30), config: config, now: now)
        XCTAssertNotNil(state.selfWakeStartedAt)

        // Native Watch unlock completes 0.9s after FUnlock self-wake without L2 injection
        now.addTimeInterval(0.9)
        let effects = EngineReducer.reduce(state: &state, event: .sessionUnlockedConfirmed(idleSeconds: 30), config: config, now: now)
        XCTAssertTrue(state.watchAutoUnlockObserved)
        XCTAssertTrue(effects.contains(.persistWatchAutoUnlockObserved(true)))

        // Simulate 3 consecutive L1 1.2s timeouts -> auto-resets watchAutoUnlockObserved to false
        for _ in 0..<3 {
            now.addTimeInterval(10)
            state.screen = .locked(reason: .away)
            state.unlockPhase = .waitingNativeUnlock(startedAt: now, reason: .watchObserved)
            let checkAt = now.addingTimeInterval(1.2)
            state.deadlines.set(.l1NativeCheck, at: checkAt)
            _ = EngineReducer.reduce(
                state: &state,
                event: .deadlineFired(.l1NativeCheck, scheduledAt: checkAt, idleSeconds: 30, currentSSID: nil, sessionLocked: true),
                config: config,
                now: checkAt
            )
            state.unlockPhase = .idle
        }
        XCTAssertFalse(state.watchAutoUnlockObserved)
    }

    func testUnbindMidUnlockCancelsPhaseReleasesKeepAliveAndClearsDeadlines() {
        var state = EngineState()
        let config = EngineConfig.defaultForTesting()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        state.presence = true
        state.keepAliveActive = true
        state.unlockPhase = .waitingNativeUnlock(startedAt: now, reason: .watchObserved)
        state.deadlines.set(.l1NativeCheck, at: now.addingTimeInterval(0.15))
        state.deadlines.set(.lockConfirm, at: now.addingTimeInterval(3.0))

        let effects = EngineReducer.reduce(state: &state, event: .unbindDevice, config: config, now: now)
        XCTAssertFalse(state.presence)
        XCTAssertFalse(state.keepAliveActive)
        XCTAssertEqual(state.unlockPhase, .idle)
        XCTAssertNil(state.deadlines[.l1NativeCheck])
        XCTAssertNil(state.deadlines[.lockConfirm])
        XCTAssertTrue(effects.contains(.setKeepAlive(false)))
    }
}
```

- [ ] **Step 2: Run `swift test` to confirm failure**

Run: `swift test --package-path Packages/FUnlockCore`
Expected: FAIL

- [ ] **Step 3: Implement `EngineReducer+Unlock.swift` and negative hint acceleration**

Implement full gate order (`presence` → `unlockDisabled` → `signalBelowThreshold` → `unlockPhase`/cooldown/degraded → `lockBuffer` `0.8s` → `unlockCooldown` `5.0s` → `pauseOnWiFi` → `manualLock` → parallel wake / `0.3s` delayed unlock → L1 `150ms`/`1.2s` window → L2 `.injecting`), L0 `30s` renewal / `900s` idle cap / `idleSleepLatched`, `.negativeHintReceived` cutting `activePollInterval` to `0.5s` + `.probeRSSIImmediately`, and atomic `.unbindDevice`.

- [ ] **Step 4: Run `swift test` to verify all `FUnlockCoreTests` pass**

Run: `swift test --package-path Packages/FUnlockCore`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Packages/FUnlockCore
git commit -m "feat(core): implement L0/L1/L2 progressive unlock, idle latch, and negative hint reducer rules"
```

---

### Task 4: Implement `LiveDeadlineScheduler` & Replace Scattered BLE / Lock `Timer`s
**Owner:** Antigravity (scheduler design) + Claude Desktop (`FUn`/`BLEScanner`/`BLEPeripheralHandler` wiring & test run)

**Files:**
- Create: `FUnlock/Runtime/LiveDeadlineScheduler.swift`
- Create: `FUnlockTests/LiveDeadlineSchedulerTests.swift`
- Modify: `FUnlock/FUn.swift:143-250`
- Modify: `FUnlock/FUnLockCoordinator.swift:135-450`
- Modify: `FUnlock/BLEScanner.swift:190-255`
- Modify: `FUnlock/BLEPeripheralHandler.swift:26-146`
- Modify: `FUnlock/Device.swift` (remove `var scanTimer: Timer?`)
- Modify: `FUnlock.xcodeproj/project.pbxproj` (register `LiveDeadlineScheduler.swift` and `LiveDeadlineSchedulerTests.swift`)

**Interfaces:**
- Consumes: `DeadlineID`, `DeadlineTable` from `FUnlockCore`.
- Produces:
  - `final class LiveDeadlineScheduler: @unchecked Sendable` with `init(nowProvider: @escaping @Sendable () -> Date = { Date() }, onFire: @escaping @Sendable (DeadlineID, Date) -> Void)`, `func schedule(_ id: DeadlineID, at date: Date)`, `func scheduleAfter(_ id: DeadlineID, interval: TimeInterval)`, `func cancel(_ id: DeadlineID)`, `func cancelWhere(_ predicate: (DeadlineID) -> Bool)`, `func cancelAll()`, `func isScheduled(_ id: DeadlineID) -> Bool`.
  - Internally owns a single `DispatchSourceTimer` on a private serial queue protected by `UnfairLock`, re-arming only when `table.earliest()` changes.

- [ ] **Step 1: Write failing `LiveDeadlineSchedulerTests` in `FUnlockTests/LiveDeadlineSchedulerTests.swift`**

```swift
import XCTest
@testable import FUnlock

final class LiveDeadlineSchedulerTests: XCTestCase {
    func testFiresInChronologicalOrderAndIgnoresCancelledDeadline() {
        let exp = expectation(description: "ordered deadlines")
        exp.expectedFulfillmentCount = 2
        var fired: [DeadlineID] = []
        let lock = NSLock()

        let scheduler = LiveDeadlineScheduler { id, _ in
            lock.lock()
            fired.append(id)
            lock.unlock()
            exp.fulfill()
        }
        let now = Date()
        scheduler.schedule(.heartbeat, at: now.addingTimeInterval(0.12))
        scheduler.schedule(.lockConfirm, at: now.addingTimeInterval(0.04))
        scheduler.schedule(.signalTimeout, at: now.addingTimeInterval(0.08))
        scheduler.cancel(.signalTimeout)

        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(fired, [.lockConfirm, .heartbeat])
        scheduler.cancelAll()
    }
}
```

- [ ] **Step 2: Run `LiveDeadlineSchedulerTests` to confirm failure**

Run: `xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -only-testing:FUnlockTests/LiveDeadlineSchedulerTests test`
Expected: FAIL (`LiveDeadlineScheduler` unresolved)

- [ ] **Step 3: Implement `LiveDeadlineScheduler` and replace all 6 `Timer` sites in `FUn`, `FUnLockCoordinator`, `BLEScanner`, and `BLEPeripheralHandler`**

Replace `signalTimer`, `heartbeatTimer`, `proximityTimer` (+ extension timer), `activeModeTimer`, `connectionTimer`, and `device.scanTimer` with `FUn.scheduler: LiveDeadlineScheduler` (`isActiveModeActive` checks `scheduler.isScheduled(.activePoll)`). Remove `invalidateOnMain` helper once unused.

- [ ] **Step 4: Run `FUnlockTests` to verify all scheduler & BLE/lock tests pass**

Run: `xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add FUnlock FUnlockTests FUnlock.xcodeproj
git commit -m "refactor(ble): replace 6 scattered RunLoop timers with single LiveDeadlineScheduler"
```

---

### Task 5: Implement `SecretUTF16Buffer` (`memset_s`), Remove `NSAppleScript` L3, Add Key Preemption & `lowlevel.c` Keep-Alive Assertion
**Owner:** Antigravity (security-critical implementation) + Claude Desktop (`pbxproj` & test run)

**Files:**
- Create: `FUnlock/SecretUTF16Buffer.swift`
- Create: `FUnlockTests/SecretUTF16BufferTests.swift`
- Modify: `FUnlock/lowlevel.h:1-10`
- Modify: `FUnlock/lowlevel.c:1-108`
- Modify: `FUnlock/SecurityService.swift:52-99`
- Modify: `FUnlock/SystemInteractionService.swift:240-530`
- Modify: `FUnlock.xcodeproj/project.pbxproj` (register `SecretUTF16Buffer.swift` and `SecretUTF16BufferTests.swift`)

**Interfaces:**
- Consumes: `SecItemCopyMatching`, Darwin `memset_s`, `CGEvent`, `IOPMAssertionDeclareUserActivity`.
- Produces:
  - C functions in `lowlevel.h`: `void funlock_renewPresenceKeepAlive(void);` and `void funlock_releasePresenceKeepAlive(void);` using dedicated static `IOPMAssertionID keepAliveAssertionID` protected by `assertionLock`.
  - `final class SecretUTF16Buffer`:
    - `init?(utf8Data: inout Data)` (transcodes UTF-8 bytes directly via `Unicode.UTF8` → `UTF16` into `UnsafeMutableBufferPointer<UniChar>`, wipes `utf8Data` bytes in place via `resetBytes(in:)` / `memset_s`, returns `nil` on invalid UTF-8 or empty input)
    - `var count: Int { get }`
    - `var isWiped: Bool { get }`
    - `func forEachCGEventBatch(maxUnits: Int = 20, _ body: (UnsafeMutablePointer<UniChar>, Int) -> Bool) -> Bool` (splits at `maxUnits - 1` whenever `buffer[offset + maxUnits - 1]` is in `0xD800...0xDBFF` so UTF-16 surrogate pairs are never torn)
    - `func wipe()` (calls `memset_s` to zero all `UniChar` bytes and deallocates; called automatically in `deinit`)
  - `SecurityService.fetchPasswordBuffer(warn: Bool = false) -> Result<SecretUTF16Buffer?, KeychainError>`
  - `SystemInteractionService.physicalKeyActiveProvider: (() -> Bool)?` (default checks `CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown) < 0.15` prior to FUnlock's own event batch)
  - `SystemInteractionService.injectPasswordBufferWithPrelude(_ buffer: SecretUTF16Buffer, isSecureCheck: @escaping () -> Bool, keystrokeSecureCheck: (() -> Bool)?) async -> Bool` (wipes `buffer` in `defer`; Level-3 `injectWithAppleScript` deleted).

- [ ] **Step 1: Write failing `SecretUTF16BufferTests` in `FUnlockTests/SecretUTF16BufferTests.swift`**

```swift
import XCTest
@testable import FUnlock

final class SecretUTF16BufferTests: XCTestCase {
    func testSurrogatePairTranscodingBatchSplitAndZeroing() {
        // 19 ASCII chars + "🔑" (2 UTF-16 code units: 0xD83D, 0xDD11) + "Z" = 22 UTF-16 units
        // Naive stride(by: 20) would split 0xD83D and 0xDD11 across batches!
        let original = "1234567890123456789🔑Z"
        var raw = Data(original.utf8)
        guard let secret = SecretUTF16Buffer(utf8Data: &raw) else {
            return XCTFail("Expected valid SecretUTF16Buffer")
        }
        XCTAssertEqual(secret.count, 22)

        var reconstructed = ""
        var batchLengths: [Int] = []
        let completed = secret.forEachCGEventBatch(maxUnits: 20) { ptr, len in
            batchLengths.append(len)
            let str = String(utf16CodeUnits: ptr, count: len)
            reconstructed.append(str)
            return true
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(batchLengths, [19, 3], "Must step back to 19 to avoid tearing surrogate pair at index 19")
        XCTAssertEqual(reconstructed, original)

        secret.wipe()
        XCTAssertTrue(secret.isWiped)
        XCTAssertEqual(secret.count, 0)
    }

    func testPhysicalKeyPreemptionAbortsCGEventInjection() {
        SystemInteractionService.sessionDictProvider = { ["CGSSessionScreenIsLocked": 1] }
        SystemInteractionService.frontmostBundleIDProvider = { "com.apple.loginwindow" }
        SystemInteractionService.physicalKeyActiveProvider = { true }
        defer {
            SystemInteractionService.sessionDictProvider = nil
            SystemInteractionService.frontmostBundleIDProvider = nil
            SystemInteractionService.physicalKeyActiveProvider = nil
        }

        var data = Data("SecretPass123".utf8)
        let buf = SecretUTF16Buffer(utf8Data: &data)!
        let posted = SystemInteractionService.shared.injectKeyStrokes(buf, isSecureCheck: { true })
        XCTAssertFalse(posted, "Active physical keydown must preempt synthetic injection before posting")
    }
}
```

- [ ] **Step 2: Run `SecretUTF16BufferTests` to confirm failure**

Run: `xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -only-testing:FUnlockTests/SecretUTF16BufferTests test`
Expected: FAIL (`SecretUTF16Buffer` unresolved)

- [ ] **Step 3: Implement `lowlevel.c` keep-alive assertion, `SecretUTF16Buffer`, `SecurityService.fetchPasswordBuffer`, and `SystemInteractionService` updates (deleting `injectWithAppleScript`)**

Ensure `UnlockOrchestrator.guardFetchPassword` / `performInjectionAndVerify` uses `SecretUTF16Buffer` with `defer { buffer.wipe() }` when `SystemInteractionService.injectPasswordOverride == nil` (preserving `injectPasswordOverride` hook for existing unit tests).

- [ ] **Step 4: Run full `FUnlockTests` suite**

Run: `xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add FUnlock FUnlockTests FUnlock.xcodeproj
git commit -m "feat(security): add memset_s SecretUTF16Buffer, remove AppleScript L3, and add L0 keep-alive assertion"
```

---

### Task 6: Wire L0 Keep-Alive, L1 Zero-Injection & `NegativeSignalAdapter` into Runtime & Settings
**Owner:** Antigravity (L0/L1 orchestration) + Claude Desktop (`NegativeSignalAdapter`, `ConfigStore`, `BehaviorSettingsView`, `Localizable.strings`, test run)

**Files:**
- Create: `FUnlock/Runtime/PowerKeepAliveAdapter.swift`
- Create: `FUnlock/Runtime/NegativeSignalAdapter.swift`
- Create: `FUnlockTests/ThreeStageUnlockIntegrationTests.swift`
- Modify: `FUnlock/ConfigStore.swift:71-225` (register `keepAliveWhilePresent` default `true`, `preferNativeWatchUnlock` default `true`, `watchAutoUnlockObserved` default `false` in `defaultBool` / `boolKeys` / `exportableKeys`)
- Modify: `FUnlock/FUnManager.swift` & `FUnlock/FUnManager+Events.swift` & `FUnlock/UnlockOrchestrator.swift` & `FUnlock/UnlockOrchestrator+AutoUnlock.swift` (wire `PowerKeepAliveAdapter`, `idleSleepLatched` wake guard, `selfWakeStartedAt` L1 self-learning & `1.2s` zero-injection poll, and `NegativeSignalAdapter`)
- Modify: `FUnlock/BehaviorSettingsView.swift:48-86` (add `keepAliveWhilePresent` and `preferNativeWatchUnlock` `PrecisionToggleRow`s)
- Modify: `FUnlock/*.lproj/Localizable.strings` (add localized keys `keep_alive_present`, `keep_alive_present_desc`, `prefer_watch_unlock`, `prefer_watch_unlock_desc` across Base + 7 locales)
- Modify: `FUnlock.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `EngineReducer` rules (Task 3), `LiveDeadlineScheduler` (Task 4), `funlock_renewPresenceKeepAlive` / `funlock_releasePresenceKeepAlive` (Task 5).
- Produces:
  - `final class PowerKeepAliveAdapter: @unchecked Sendable` (`nonisolated(unsafe) static var renewOverride: (() -> Void)?`, `nonisolated(unsafe) static var releaseOverride: (() -> Void)?`, `func setKeepAlive(_ active: Bool)`).
  - `final class NegativeSignalAdapter` (listens to `AudioObjectAddPropertyListenerBlock` on `kAudioObjectSystemObject` / `kAudioHardwarePropertyDefaultOutputDevice` and `NWPathMonitor`, invoking `onNegativeHint: @Sendable (NegativeHintSource) -> Void`).

- [ ] **Step 1: Write failing `ThreeStageUnlockIntegrationTests` in `FUnlockTests/ThreeStageUnlockIntegrationTests.swift`**

```swift
import XCTest
@testable import FUnlock

@MainActor
final class ThreeStageUnlockIntegrationTests: XCTestCase {
    func testL0RenewsWhenPresentAndReleasesImmediatelyOnAwayOr15MinIdle() {
        let snapshot = ConfigKeySnapshot(keys: ["enabled", "keepAliveWhilePresent"])
        addTeardownBlock { snapshot.restore() }
        ConfigStore.shared.set(true, forKey: "enabled")
        ConfigStore.shared.set(true, forKey: "keepAliveWhilePresent")

        var activeStates: [Bool] = []
        PowerKeepAliveAdapter.renewOverride = { activeStates.append(true) }
        PowerKeepAliveAdapter.releaseOverride = { activeStates.append(false) }
        SystemInteractionService.lockActionOverride = {}
        defer {
            PowerKeepAliveAdapter.renewOverride = nil
            PowerKeepAliveAdapter.releaseOverride = nil
            SystemInteractionService.lockActionOverride = nil
        }

        var idle: TimeInterval = 5
        let fun = FUn()
        let manager = FUnManager(fun: fun)
        let monitor = InputActivityMonitor(activityWindow: 15, idleTimeProvider: { idle })
        manager.inputMonitor = monitor
        fun.inputMonitor = monitor

        fun.presence = true
        fun.effectiveRSSI = -50
        manager.evaluatePresenceKeepAlive()
        XCTAssertEqual(activeStates.last, true)

        // Reaching 900s idle immediately releases keep-alive
        idle = 905
        manager.evaluatePresenceKeepAlive()
        XCTAssertEqual(activeStates.last, false)
    }

    func testL1NativeWatchCooperationSkipsKeystrokeInjectionWhenSessionUnlocksDuringGraceWindow() async {
        let snapshot = ConfigKeySnapshot(keys: ["enabled", "preferNativeWatchUnlock", "watchAutoUnlockObserved", "wakeWithoutUnlocking"])
        addTeardownBlock { snapshot.restore() }
        ConfigStore.shared.set(true, forKey: "enabled")
        ConfigStore.shared.set(true, forKey: "preferNativeWatchUnlock")
        ConfigStore.shared.set(true, forKey: "watchAutoUnlockObserved")
        ConfigStore.shared.set(false, forKey: "wakeWithoutUnlocking")

        var injectedCount = 0
        SystemInteractionService.injectPasswordOverride = { _ in injectedCount += 1; return true }
        var locked = true
        SystemInteractionService.sessionDictProvider = { ["CGSSessionScreenIsLocked": locked ? 1 : 0] }
        SystemInteractionService.screensaverRunningProvider = { false }
        defer {
            SystemInteractionService.injectPasswordOverride = nil
            SystemInteractionService.sessionDictProvider = nil
            SystemInteractionService.screensaverRunningProvider = nil
        }

        let fun = FUn()
        fun.presence = true
        fun.effectiveRSSI = -50
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fut-l1-\(UUID().uuidString)")
        let logger = DecisionLogger(testLogDirectory: tmp)
        let manager = FUnManager(fun: fun, decisionLogger: logger)
        manager.lockBufferDuration = 0
        manager.isSelfLocking = true
        manager.onSystemScreenLocked()

        // Session unlocks natively (Apple Watch) 200ms after L1 starts
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            locked = false
        }
        manager.attemptAutoUnlock()
        try? await Task.sleep(nanoseconds: 800_000_000)

        XCTAssertEqual(injectedCount, 0, "L1 native unlock must complete without calling L2 password injection")
        XCTAssertEqual(manager.state.screen, .unlocked)
        XCTAssertTrue(logger.events.contains { $0.reason == .unlockSuccess })
    }
}
```

- [ ] **Step 2: Run `ThreeStageUnlockIntegrationTests` to confirm failure**

Run: `xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -only-testing:FUnlockTests/ThreeStageUnlockIntegrationTests test`
Expected: FAIL

- [ ] **Step 3: Implement `PowerKeepAliveAdapter`, `NegativeSignalAdapter`, L0/L1 wiring in `FUnManager`/`UnlockOrchestrator`, and `BehaviorSettingsView` toggles + localizations**

Wire `NegativeSignalAdapter` in `AppDelegate` (skipped under `XCTestConfigurationFilePath`) to call `fun.handleNegativeHint(_:)`.

- [ ] **Step 4: Run full `FUnlockTests` suite**

Run: `xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add FUnlock FUnlockTests FUnlock.xcodeproj
git commit -m "feat(unlock): wire L0 bounded keep-alive, L1 self-learning Watch unlock, and negative-signal fast probe"
```

---

### Task 7: Implement CQRS Three Projections, `TimelineView` Charts & Release Verification
**Owner:** Claude Desktop via `agent-hud` (Reviewed by Antigravity)

**Files:**
- Create: `FUnlock/Projections/StatusProjection.swift`
- Create: `FUnlock/Projections/LiveSignalProjection.swift`
- Create: `FUnlockTests/ProjectionsAndVisibilityTests.swift`
- Modify: `FUnlock/SignalDataStore.swift` (remove `Combine` 1s `Timer.publish` & `@Observable samples`; expose thread-safe `snapshot() -> [SignalSample]`)
- Modify: `FUnlock/DiagnosticsView.swift:133-185` (wrap chart section in `TimelineView(.periodic(from: .now, by: 1.0))` reading `dataStore.snapshot()`)
- Modify: `FUnlock/OverviewView.swift` (remove `@State scanTimer` and `@State frozenDevices`; consume `manager.liveSignal.candidateDevices` flushed via `LiveDeadlineScheduler` `.uiDiscoveryFlush` only while window visible & list expanded)
- Modify: `FUnlock/MainWindowView.swift:62-129,255-282` (replace `permissionPollCancellable` Combine timer with `.task(id: !axGranted || !btGranted)` structured loop)
- Modify: `FUnlock/SidebarView.swift`, `FUnlock/MenuBarPopover.swift`, `FUnlock/RangeRailView.swift`, `FUnlock/AppDelegate.swift` (bind low-frequency views to `manager.status: StatusProjection`, high-frequency readouts to `manager.liveSignal: LiveSignalProjection`, and toggle `manager.setWindowVisible(_:)` on settings window & popover show/close)
- Modify: `README.md:147-235` (update project structure & architecture diagram to match `FUnlockCore` + `LiveDeadlineScheduler` + `L0/L1/L2` + CQRS projections)
- Modify: `FUnlock.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `FUnManager`, `LiveDeadlineScheduler`, `SignalSample`, `DeviceSnapshot`.
- Produces:
  - `@Observable @MainActor final class StatusProjection` (`screen`, `connected`, `monitoredDeviceName`, `lockRSSI`, `unlockRSSI`, `thresholdVersion`, `isDegraded`, `keepAliveActive`, `updateState`)
  - `@Observable @MainActor final class LiveSignalProjection` (`displayRSSI: Int?`, `effectiveRSSI: Double`, `isWindowVisible: Bool`, `isDiscoveryExpanded: Bool`, `candidateDevices: [DeviceSnapshot]`)
  - `SignalDataStore` (`internal init(capacity: Int = 600)` + `static let shared`, `func snapshot() -> [SignalSample]`, zero background timers)

- [ ] **Step 1: Write failing `ProjectionsAndVisibilityTests` in `FUnlockTests/ProjectionsAndVisibilityTests.swift`**

```swift
import XCTest
@testable import FUnlock

@MainActor
final class ProjectionsAndVisibilityTests: XCTestCase {
    func testLiveSignalProjectionSuppressesUpdatesWhileWindowHiddenAndFlushesOnShow() {
        let fun = FUn()
        let manager = FUnManager(fun: fun)
        manager.setWindowVisible(false)

        manager.onRSSIUpdated(rssi: -54, active: true)
        XCTAssertNil(manager.liveSignal.displayRSSI, "Hidden window must not receive high-frequency RSSI projection updates")

        manager.setWindowVisible(true)
        XCTAssertEqual(manager.liveSignal.displayRSSI, -54, "Becoming visible must immediately hydrate latest RSSI")
    }

    func testSignalDataStoreRecordsAndSnapshotsWithoutBackgroundTimer() {
        let store = SignalDataStore()
        store.record(rawRSSI: -55, kalmanEstimate: -56, effectiveRSSI: -56.5, slope: -0.2, isAnomalous: false)
        let snap = store.snapshot()
        XCTAssertEqual(snap.count, 1)
        XCTAssertEqual(snap.first?.rawRSSI, -55)
    }
}
```

- [ ] **Step 2: Run `ProjectionsAndVisibilityTests` to confirm failure**

Run: `xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -only-testing:FUnlockTests/ProjectionsAndVisibilityTests test`
Expected: FAIL

- [ ] **Step 3: Implement `StatusProjection`, `LiveSignalProjection`, timer-free `SignalDataStore.snapshot()`, `DiagnosticsView` `TimelineView`, `OverviewView` & `MainWindowView` timer removal, and `README.md` update**

Verify via grep that zero `Timer.scheduledTimer`, `Timer.publish`, or `RunLoop.main.add` calls remain anywhere in `FUnlock/`.

- [ ] **Step 4: Run full package tests, Xcode unit tests, timer audit, and signed Release build**

Run:
```bash
swift test --package-path Packages/FUnlockCore && \
xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' test && \
xcodebuild build -project FUnlock.xcodeproj -scheme FUnlock -configuration Release
```
Expected: All `FUnlockCoreTests` and `FUnlockTests` PASS; Release build succeeds with `TeamIdentifier=JJYCS98SHK`.

- [ ] **Step 5: Commit**

```bash
git add FUnlock FUnlockTests FUnlock.xcodeproj README.md
git commit -m "feat(ui): land CQRS visibility-gated projections, TimelineView charts, and update docs"
```
