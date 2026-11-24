# FUnlock Precision Instrument UI Redesign Implementation Plan

> **For agentic workers:** Execute task-by-task with TDD and fresh verification (`xcodebuild test`) at every phase gate. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign FUnlock's entire macOS SwiftUI + AppKit interface into Direction A (Precision Instrument / Swiss Minimalism), converging 7 sidebar tabs into 4, unifying threshold tuning into a single Interactive Range Rail, harmonizing all Sheets and the MenuBar Popover under one dynamic `FUnlockTheme`, and fixing accessibility and dead-UI debt with zero behavior regressions.

**Architecture:** Replace ad-hoc `colorScheme` branches and `LiquidGlass.swift` aurora/rainbow layers with one AppKit-backed dynamic token layer (`FUnlockTheme`) and a single `StatusPresentation` model shared by Sidebar, Overview, Diagnostics, and MenuBar Popover. Keep BLE (`FUn`), state machine (`FUnlockStateMachine`), `SignalHysteresisEngine`, `ConfigStore`, and `DecisionLogger` completely untouched; only presentation and view-layer routing change.

**Tech Stack:** Swift 5.7+, SwiftUI + AppKit (`NavigationSplitView`, `NSPopover`, `NSWindow`, `Charts`), macOS 14.0+, zero third-party dependencies, Xcode project (`FUnlock.xcodeproj/project.pbxproj`, manual `PBXBuildFile`/`PBXFileReference` registration).

**Spec:** `docs/superpowers/specs/2026-11-24-precision-instrument-ui-redesign-spec.md`
**Prototype:** `docs/precision-instrument-prototype.html`

## Global Constraints

- **Zero third-party dependencies**; macOS 14.0+ deployment target.
- **Zero logic regressions**: Do not alter BLE scanning, `SignalPipeline`, `SignalHysteresisEngine`, `FUnlockStateMachine`, `SecurityService`, `ConfigStore` keys, or `ScriptRunner` execution semantics.
- **Exact numeric bounds**: RSSI range is `-95...(-30)` (`SignalHysteresisEngine.rssiRange`), offset range is `0...20` (`defaultWakeAdvance = 20`, `defaultPreUnlockTrigger = 10`), `lockUnlockDelayGap = 10`, `unlockDisabled = 1`, `lockDisabled = -100`.
- **Test contracts preserved**: `MenuBarPopoverView.signalLevel(for:)`, `MenuBarPopoverView.signalBars(for:)`, `MenuBarPopoverView.signalText(effectiveRSSI:hasSignal:)`, `StatsCalculator.*`, `DiagnosticsView.timelinePageSize == 40`, `Array.chunked(pageSize:)`, `CalibrationWizardView.computeFinalThresholds(avgUnlock:avgLock:)`, and `ReasonActionMappingTests` (`DecisionReason.*.action`) must remain green.
- **Performance red lines**: Zero full-screen blur/gradients, zero card `.shadow`, off-screen animations paused on `NSPopover.didCloseNotification`, 40-row timeline chunking, 120-point chart downsampling, discrete status-bar icon redraw.
- **Manual pbxproj**: Every added or removed `.swift` file must be synchronized across `PBXFileReference`, `PBXBuildFile`, `PBXGroup.children`, and `PBXSourcesBuildPhase` in `FUnlock.xcodeproj/project.pbxproj`.

## Review Focus

1. **Legacy `DecisionReason.goToTab` & `DistributedNotification` tab keys (`"basic"`, `"unlock"`, `"lock"`, `"network"`, `"config"`)** — `MenuTab.resolve(_:)` must route legacy keys to `.behavior` / `.scenarios` so diagnostics action buttons and external notifications never silently no-op.
2. **Automatic unlock disabled sentinel (`unlockRSSI == FUn.UNLOCK_DISABLED == 1`)** — Range Rail must never render an out-of-range handle at `+1 dBm`; it must hide the unlock handle, show the disabled pill, and keep lock threshold editable.
3. **Sidebar vs Popover `displaySleeping` / `screensaver` state parity** — Both must derive from `StatusPresentation.resolve(screen:connected:hasDevice:)` so standby never renders grey in one place and orange in the other.
4. **Hysteresis & clamping on Range Rail drag/stepper/apply** — Lock must stay `< unlock`, clamping strictly to `-95...(-30)`; stepping unlock with unmodified lock shifts lock by `lockUnlockDelayGap` (10 dB); `isThresholdApplied` tracks all 4 values (`lock`, `unlock`, `wakeAdvance`, `preUnlockTrigger`).
5. **Accessibility fallbacks & Escape dismissal** — `accessibilityReduceMotion` disables animations; `accessibilityReduceTransparency` forces opaque surfaces; all 4 Sheets handle `Esc` cleanly (and `CalibrationWizardView` runs `endCalibration()` on dismiss/Esc).

---

### Task 1 (Phase 1): `FUnlockTheme`, `StatusPresentation`, Core Components & Solid Canvas Backdrop

**Files:**
- Create: `FUnlock/FUnlockTheme.swift`
- Create: `FUnlock/PrecisionComponents.swift`
- Create: `FUnlockTests/PrecisionThemeTests.swift`
- Modify: `FUnlock.xcodeproj/project.pbxproj` (register the 3 new Swift files)
- Modify: `FUnlock/MainWindowView.swift` (replace `LiquidAuroraMesh` + `.ultraThinMaterial` window backdrop with `FUnlockTheme.Surface.canvas`)
- Modify: `FUnlock/AppDelegate.swift:638-651` (make `settingsWindow` opaque with native canvas appearance, remove transparent clear glass hack)

**Interfaces:**
- Produces:
  - `FUnlockTheme` (`Surface`, `Text`, `State`, `Accent`, `Radius`, `Space`, `Motion`)
  - `StatusTone` (`.safe`, `.amber`, `.danger`, `.neutral`)
  - `StatusPresentation.resolve(screen: ScreenState, connected: Bool, hasDevice: Bool) -> StatusPresentation`
  - `FUnlockCard`, `Hairline`, `InlineNotice`, `IconTile`, `FieldStyle` (`.precisionField()`), `InstrumentButton` (`.primary`, `.secondary`, `.ghost`, `.destructive`), `ControlRow`, `StatusBadge`, `SheetScaffold`

- [ ] **Step 1: Create feature branch `feat/precision-instrument-ui` from current `main`**
  Commit existing design docs separately or keep working tree clear of untracked conflicts.
- [ ] **Step 2: Write failing unit tests in `FUnlockTests/PrecisionThemeTests.swift`**
  Test `StatusPresentation.resolve` across all combinations (`unlocked`, `locked+connected`, `screensaver`, `displaySleeping`, `disconnected+hasDevice`, `disconnected+noDevice`), verify `FUnlockTheme.Radius` (`6/10/12/9999`), `FUnlockTheme.Space` (`4/8/12/16/20/24`), and Light/Dark dynamic color distinctness.
- [ ] **Step 3: Implement `FUnlock/FUnlockTheme.swift` & `FUnlock/PrecisionComponents.swift`**
  Implement exact Light/Dark hex tokens from Spec §2.1–2.7 using `NSColor(name: nil) { appearance in ... }` dynamic provider, `StatusPresentation`, and the precision component family (respecting `@Environment(\.accessibilityReduceMotion)` and `@Environment(\.accessibilityReduceTransparency)`).
- [ ] **Step 4: Register new files in `FUnlock.xcodeproj/project.pbxproj` & switch `MainWindowView` / `AppDelegate` window backdrop to `FUnlockTheme.Surface.canvas`**
- [ ] **Step 5: Run full test suite & commit Phase 1**
  Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS'`
  Expected: `** TEST SUCCEEDED **`, 0 failures, total tests > 519.
  Commit: `feat(ui): add FUnlockTheme, StatusPresentation, and precision component foundation`

---

### Task 2 (Phase 2A): Interactive Range Rail Pure Geometry & View Component

**Files:**
- Create: `FUnlock/RangeRailView.swift`
- Create: `FUnlockTests/RangeRailTests.swift`
- Modify: `FUnlock.xcodeproj/project.pbxproj` (register the 2 new files)

**Interfaces:**
- Consumes: `FUnlockTheme`, `SignalHysteresisEngine`, `lockUnlockDelayGap`
- Produces:
  - `RangeRailGeometry` (pure static functions: `position(forRSSI:width:)`, `rssi(forX:width:)`, `clampLock(_:unlock:)`, `linkedLock(forUnlock:currentLock:userModified:)`, `hysteresisGap(lock:unlock:)`, `isBufferNarrow(lock:unlock:)`)
  - `RangeRailView` (SwiftUI component with calibrated `-95...(-30)` track, Lock/Hysteresis/Unlock zones, Wake/Pre-unlock ticks, live RSSI needle, draggable & keyboard-accessible handles, 4 precision steppers, explicit legend, `UNLOCK_DISABLED` sentinel handling, dirty-state Apply/Revert bar)

- [ ] **Step 1: Write failing unit tests in `FUnlockTests/RangeRailTests.swift`**
  Pin `RangeRailGeometry` boundaries (`-95` → `0`, `-30` → `width`, round-trip `rssi(forX:)`, `clampLock` enforces `lock < unlock`, `linkedLock` shifts by 10 dB when unmodified and preserves manual lock when modified, `isBufferNarrow` true when `< 10`, `UNLOCK_DISABLED` sentinel handling).
- [ ] **Step 2: Implement `FUnlock/RangeRailView.swift` and register in `project.pbxproj`**
- [ ] **Step 3: Run tests to verify green**
  Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -only-testing:FUnlockTests/RangeRailTests`
  Expected: All `RangeRailTests` pass.

---

### Task 3 (Phase 2B): 7 → 4 Tab Convergence, New Views & Unified Diagnostics

**Files:**
- Create: `FUnlock/BehaviorSettingsView.swift` (merges Basic + Unlock + Lock + IM/Bark cards)
- Create: `FUnlock/ScenariosSettingsView.swift` (merges Network + Profiles + Backup + fixed single-script Automation card)
- Modify: `FUnlock/MainWindowView.swift` (4-case `MenuTab` + `MenuTab.resolve(_:)` legacy mapping, `⌘S` / `.menuShowStats` routes to `.diagnostics`, bottom bar uses `InstrumentButton`, restore `About` trigger)
- Modify: `FUnlock/SidebarView.swift` (no group headers, `StatusPresentation`-driven status header, 4 tabs, bottom version strip `FUnlock 2.8.37` opening `AboutView` Sheet)
- Modify: `FUnlock/OverviewView.swift` (Precision telemetry gauge + bound device card + `RangeRailView` + calibration button, zero card shadows)
- Modify: `FUnlock/DiagnosticsView.swift` (embed `StatsCalculator` KPI strip + `SignalChartView`/`SlopeChartView` segmented card above the 40-row chunked timeline; keep `timelinePageSize == 40`, `chunked`, and export zip intact)
- Modify: `FUnlock/IMSettingsCard.swift` & `FUnlock/BarkSettingsCard.swift` (adopt `FUnlockTheme` + `.precisionField()` + `InstrumentButton`, keep all validation & test actions)
- Modify: `FUnlock/ToastView.swift` (adopt `FUnlockTheme`)
- Modify: `FUnlockTests/UATVisualTests.swift` (update from 7 tabs to 4 tabs + capture Popover & 4 Tabs)
- Create/Extend: `FUnlockTests/MenuTabRoutingTests.swift` (test `MenuTab.resolve` for all new and legacy tab strings)
- Modify: `FUnlock.xcodeproj/project.pbxproj` (register new views/tests; remove obsolete `BasicSettingsView.swift`, `UnlockSettingsView.swift`, `LockSettingsView.swift`, `NetworkSettingsView.swift`, `ConfigSettingsView.swift`, `AutomationView.swift` if fully superseded — keep `StatsCalculator` & chart views in `DiagnosticsView.swift` or `SignalChartsView.swift`)

**Interfaces:**
- Consumes: `FUnlockTheme`, `StatusPresentation`, `RangeRailView`, `PrecisionComponents`
- Produces: 4-tab `MenuTab` (`.overview`, `.behavior`, `.scenarios`, `.diagnostics`) with `static func resolve(_ raw: String) -> MenuTab?`

- [ ] **Step 1: Add failing `MenuTabRoutingTests` verifying `MenuTab.resolve` maps `"basic"/"unlock"/"lock"` → `.behavior` and `"network"/"config"` → `.scenarios`**
- [ ] **Step 2: Implement `BehaviorSettingsView`, `ScenariosSettingsView`, and refactor `OverviewView`, `DiagnosticsView`, `SidebarView`, `MainWindowView`, `IMSettingsCard`, `BarkSettingsCard`, `ToastView`**
- [ ] **Step 3: Update `UATVisualTests.swift` to capture the 4 tabs + Popover and remove unused old tab view files cleanly from disk & `project.pbxproj`**
- [ ] **Step 4: Run full test suite & visually inspect `/tmp/uat_screenshots/*.png` + commit Phase 2**
  Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS'`
  Expected: `** TEST SUCCEEDED **`, 0 failures.
  Commit: `feat(ui): converge 7 tabs into 4 precision panels with Range Rail and unified diagnostics`

---

### Task 4 (Phase 3): MenuBar Popover Redesign, Unified Sheets & Brand `FUnlock` + Localizations

**Files:**
- Modify: `FUnlock/MenuBarPopover.swift` (remove `LiquidAuroraMesh` / rainbow borders; adopt `FUnlockTheme` + `StatusPresentation` + `ControlRow`; keep `signalLevel`/`signalBars`/`signalText` static signatures untouched; keep 8-item contract & off-screen breathing pause)
- Modify: `FUnlock/CalibrationWizardView.swift` (adopt `SheetScaffold` + `FUnlockTheme`, remove `.formStyle(.grouped)`, add `Esc` → `endCalibration()`)
- Modify: `FUnlock/AboutView.swift` (adopt `SheetScaffold` + `FUnlockTheme`, brand `FUnlock`)
- Modify: `FUnlock/OnboardingView.swift` (adopt `SheetScaffold` + `FUnlockTheme`, add Back button, `Esc` to skip/mark completed, final step direct action to open Calibration Wizard)
- Modify: `FUnlock/AppDelegate.swift` (`PermissionCheckView` adopts `FUnlockTheme` + auto-refresh on app activation; `showStats()` activates MainWindow & switches to `.diagnostics`; `toolTip` & window title unified to `"FUnlock"`)
- Modify: `FUnlock/Info.plist` (`CFBundleName` → `FUnlock` if safe for display without changing bundle ID)
- Modify: All 8 `FUnlock/*.lproj/Localizable.strings` (add the new spec keys from Spec §9, unify visible `Funlock` → `FUnlock`, preserve all existing keys)

- [ ] **Step 1: Redesign `MenuBarPopover.swift` keeping `MenuBarPopoverViewTests` 100% green**
- [ ] **Step 2: Unify `CalibrationWizardView`, `AboutView`, `OnboardingView`, and `PermissionCheckView` using `SheetScaffold` & `FUnlockTheme`**
- [ ] **Step 3: Update `AppDelegate.swift` (`showStats()` → Tab 4, title/tooltip `"FUnlock"`) and add new keys to all 8 `Localizable.strings`**
- [ ] **Step 4: Run full test suite & visually inspect updated `/tmp/uat_screenshots/00_menubar_popover.png` + commit Phase 3**
  Run: `xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS'`
  Expected: `** TEST SUCCEEDED **`, 0 failures.
  Commit: `feat(ui): unify MenuBar Popover, all Sheets, and FUnlock branding under FUnlockTheme`

---

### Task 5 (Phase 4): Accessibility Audit, Cleanup (`LiquidGlass.swift` Removal) & Release Build Verification

**Files:**
- Delete: `FUnlock/LiquidGlass.swift` & `FUnlock/MenuRowButton.swift` (if fully replaced by `ControlRow`) & `FUnlock/StatsView.swift` (if fully moved into `DiagnosticsView.swift` / `SignalChartsView.swift`)
- Modify: `FUnlock.xcodeproj/project.pbxproj` (remove deleted file refs)
- Modify: UI views for final Accessibility pass (`accessibilityReduceMotion`, `accessibilityReduceTransparency`, VoiceOver labels, focus rings, zero `.font(.system(size:))` magic numbers except `@ScaledMetric` gauge readout)

- [ ] **Step 1: Audit and remove remaining references to `LiquidGlass`, `LiquidAuroraMesh`, `funSpring`, `.formStyle(.grouped)`, and ad-hoc `colorScheme == .dark` branches**
- [ ] **Step 2: Run full Accessibility & `grep` cleanliness check across `FUnlock/*.swift`**
- [ ] **Step 3: Run full test suite (`xcodebuild test`) + Release build (`xcodebuild build -configuration Release`)**
  Expected: Both exit 0 (`** TEST SUCCEEDED **` and `** BUILD SUCCEEDED **` with zero regressions).
- [ ] **Step 4: Final commit & inspect fresh `/tmp/uat_screenshots/*.png` screenshots**
  Commit: `refactor(ui): remove legacy LiquidGlass layer and finalize accessibility pass`
