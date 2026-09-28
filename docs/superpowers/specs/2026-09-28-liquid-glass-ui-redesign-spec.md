# FUnlock UI 全盘换装 Apple Liquid Glass（晶体液态玻璃）设计系统规格说明

> 创建日期: 2026-09-28 | 状态: ready-for-agent | 关联 issue: UI-LIQUID-GLASS-001

## Problem Statement

当前 FUnlock 应用存在视觉体验脱节问题：
1. **主设置窗口（MainWindowView）仍为传统灰白表单**：右侧表单采用 macOS 默认的 `.formStyle(.grouped)`，大面积不透明冷硬灰白底色，缺乏现代 macOS 系统的通透感与层次。
2. **侧边栏与主区域割裂**：侧边栏使用原生灰底列表，与右侧白底容器形成生硬的接缝；底部快捷操作栏采用粗糙的灰色实体胶囊按钮，缺乏精致感。
3. **提示条与状态元素缺乏晶体质感**：权限警告条采用大块扁平纯色橙底，破坏视觉连贯性；数据输入框与按钮为系统默认矩形，与高品质桌面工具定位不符。
4. **两套窗口风格不统一**：状态栏悬浮窗（MenuBarPopover）已探索验证了高通透极光流光，而主设置窗口仍停留在经典表单，用户在菜单栏与主窗口之间切换时产生强烈的视觉断层。

用户期望全盘换装为符合 Apple 官方最高水准的 **Liquid Glass（全玻璃精致化）** 设计系统，在彻底保留所有功能、性能和快捷键的前提下，获得通透、轻盈、流光跃动的沉浸式视觉享受。

## Solution

在整个应用中全面落地 **Apple Liquid Glass 晶体液态玻璃设计规范**：

1. **统一窗口级玻璃底座**：
   - 主设置窗口与菜单栏悬浮窗均采用系统级硬件加速透明材质作为视窗基底，透射桌面壁纸。
   - 注入自发光多点径向网格（紫罗兰、冰蓝、薄荷、柔粉、高光核）与天光散射层，营造微弱但灵动的极光漫反射。
2. **重构核心容器为 Liquid Glass Card**：
   - 彻底废除 `.formStyle(.grouped)` 的厚重不透明底块，改用微透凹槽质感（透明度 0.14~0.18）的晶体玻璃卡片。
   - 每张卡片装备双层光学边缘结构：外层 3D 弧面反射高光环（左上强光→右下转暗）+ 内层微弱粉青棱镜色散色环。
   - 叠加双层彩色微散射环境投影，使卡片轻盈悬浮于流光之上。
3. **侧边栏与交互控件玻璃化**：
   - 侧边栏选中项换装为晶体浮动胶囊（Liquid Pill），带细微亮边与发光图标。
   - 底部操作按钮、设置项开关、文本框全部玻璃微透化，悬停带镜面微光。
   - 权限警告条升级为 Amber Glass 琥珀微透晶体条。
4. **数据权威性与对比度保障**：
   - 正文与重要指标严格使用系统高对比纯色，代码与数值统一使用等宽字体（SF Mono），禁止灰字叠在半透明底上。
   - 信号强度条、状态指示灯保持实心高饱和色，确保安全工具的数据严谨性。

## User Stories

1. As a macOS user, I want the main settings window to have a frosted crystalline background with subtle ambient aurora highlights, so that the application feels modern, premium, and harmonized with contemporary macOS design.
2. As a user, I want the sidebar items to highlight with a glowing liquid capsule when selected, so that I can instantly see which settings tab is active without harsh contrast.
3. As a user, I want the settings panels across all tabs to be housed in translucent glass cards instead of opaque white boxes, so that the underlying wallpaper and ambient light subtly refract through the interface.
4. As a user, I want each glass card to feature a delicate 3D specular highlight and subtle prismatic chromatic dispersion along its borders, so that the edges look physically beveled like cut optical glass.
5. As a user, I want permission warnings and alert banners to appear as warm amber liquid glass rather than flat solid blocks, so that important notices remain prominent without looking jarring.
6. As a user, I want form controls (toggles, text fields, sliders) to have subtle frosted glass grooves and responsive hover glows, so that interacting with settings feels tactile and responsive.
7. As a user, I want the bottom action bar with "Lock Screen" and "Quit" to feature elegant glass pill buttons with spring physics feedback, so that system-level actions feel tactile and polished.
8. As a user, I want the status bar menu popover and the main window to share the identical Liquid Glass design language, so that transitioning between the menu bar and the preferences window feels visually cohesive.
9. As a user, I want all typography and data readings (such as RSSI dBm and UUIDs) to maintain high contrast with monospaced precision, so that visual refinement does not compromise data legibility or security monitoring.
10. As a user, I want all signal strength indicators and status badges to remain solid, vivid colors, so that I can read connection states at a glance without blur or ambiguity.
11. As a user, I want the interface to automatically adjust its glass opacity and specular intensities between Dark Mode and Light Mode, so that cards remain crisp and readable under any macOS appearance setting.
12. As a battery-conscious MacBook user, I want the aurora lighting and glass materials to use macOS WindowServer hardware-accelerated shaders without continuous high-frequency CPU rendering loops, so that the app stays energy-efficient in the background.
13. As an accessibility user, I want all custom glass controls to retain 100% of their VoiceOver traits, keyboard shortcuts, and labels, so that navigation via screen reader or keyboard continues to work seamlessly.
14. As a power user, I want all keyboard shortcuts (such as ⌘,, ⌘S, ⌃⌘Q, ⌘Q) to execute identically to prior versions, so that my muscle memory is never interrupted.

## Implementation Decisions

1. **Design System Token Architecture (LiquidGlass Tokens)**:
   - Encapsulate the Liquid Glass visual primitives into a centralized, reusable set of modifiers and components:
     - `LiquidAuroraMesh`: Multi-stop radial gradient mesh (Violet `#9D91EB`, Ice Blue `#9DBEDB`, Mint `#BCE3DB`, Soft Pink `#E8BFD8`, Nucleus `#F4F0FA`) with top specular skylight and Gaussian diffusion.
     - `LiquidCardModifier`: Semi-transparent crystal base (`Color.white.opacity(0.14 ~ 0.18)` in Light Mode, `0.05 ~ 0.08` in Dark Mode) + Dual-layer optical borders (outer 3D specular gradient + inner chromatic dispersion) + Dual ambient bloom shadows.
     - `LiquidPillButtonStyle`: Interactive glass pill button styling with spring animations on hover/press.
     - `LiquidTextFieldStyle`: Frosted recessed groove text field styling with focus ring.
     - `LiquidDivider`: Horizontal specular refraction divider with center highlight and tapering ends.

2. **Window & Shell Modernization**:
   - The main window (`settingsWindow`) adopts a unified title bar (`titlebarAppearsTransparent = true` and `fullSizeContentView`), allowing the glass backdrop to flow from the traffic lights down to the bottom edge.
   - The `NavigationSplitView` sidebar background is set to clear/transparent vibrancy, allowing the window's unified background mesh to shine through.
   - The bottom utility bar is restyled with floating liquid glass pill buttons.

3. **Detail Tab Refactoring (All 7 Tabs)**:
   - Deprecate `.formStyle(.grouped)` across all tab views.
   - Replace standard form sections with `VStack` of `liquidCard` sections with consistent 16px internal padding and 12px outer spacing.
   - Tab coverage:
     - `OverviewView`: Hero device display, circular radar / signal visualizer, threshold sliders, device discovery sheet.
     - `BasicSettingsView`: Launch at login, menu bar icon styles, notifications.
     - `UnlockSettingsView`: Unlock thresholds, delay, pre-wake hysteresis.
     - `LockSettingsView`: Proximity timeout, manual lock hotkeys.
     - `NetworkSettingsView`: Trusted Wi-Fi pause toggle, SSID auto-fill, passive mode.
     - `ConfigSettingsView`: Profile import/export, full settings backup/restore.
     - `DiagnosticsView`: Live telemetry stream, decision tree inspector, health metrics.

4. **Zero Functionality Regression**:
   - All `@AppStorage`, `ConfigStore`, `FUnManager`, and `FUn` bindings remain untouched.
   - All state machine observers, timers, and background notifications remain bit-for-bit identical.
   - All localization string keys (`t(...)`) remain preserved.

## Testing Decisions

1. **What Makes a Good Test**:
   - Tests must assert external observable behavior and data contracts, never CSS-equivalent visual layout details (like pixel radii or gradient angles).
   - Invariants to guarantee:
     - All 440 existing unit tests (`SignalPipeline`, `StateMachine`, `Orchestrator`, `UIAndUtilityTests`, etc.) continue to pass with 0 failures.
     - All user settings read/write roundtrips through `ConfigStore` must remain functional after form container replacement.
     - Signal level thresholds, bar counts, and formatted RSSI strings remain deterministic.
     - Build continues with 0 compilation errors under Swift 6 strict concurrency (`SWIFT_STRICT_CONCURRENCY = complete`).

2. **Modules to Test**:
   - `FUnlockTests/UIAndUtilityTests.swift`: Verify discrete status calculations, localized signal descriptions, and view model outputs.
   - `FUnlockTests/StateAndConfigTests.swift`: Verify settings persistence across all modified tab controls.
   - Manual smoke test: Run Debug build on macOS, inspect both Popover and MainWindow under Light and Dark modes.

## Out of Scope

1. **Backend & Bluetooth Pipeline Changes**: Zero changes to BLE scanning, CoreBluetooth delegates, Kalman filtering, or signal hysteresis engines.
2. **Security & Keychain Architecture**: No changes to Keychain access, password hashing, or accessibility injection scripts.
3. **New Functional Features**: This spec strictly covers visual and interaction design overhaul; no new settings keys or business logic features are introduced.

## Further Notes

- Prototype verification in `MenuBarPopover.swift` confirmed that eliminating redundant stacked materials in AppKit hosting views is essential to prevent milky opacity.
- macOS `NSWindow` transparency requires properly configuring the window's `isOpaque = false` and `backgroundColor = .clear` when `fullSizeContentView` is engaged.
