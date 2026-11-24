# FUnlock 精密仪器风 UI 重设计规格（方向 A）

> 创建日期：2026-11-24 | 状态：draft（等待 HTML 原型确认后进入实施）
> 关联产物：`design-system/funlock/MASTER.md`、`design-system/funlock/tokens.json`、`docs/precision-instrument-prototype.html`
> 范围：仅 UI / 交互 / 设计系统。不改 BLE、状态机、信号算法、持久化 key 与安全逻辑。

---

## 1. 设计定位与核心原则（Precision Instrument / Swiss Minimalism）

### 1.1 一句话定位

FUnlock 是常驻菜单栏的蓝牙解锁工具，核心任务是清晰显示当前信号状态并降低距离阈值调参成本：主读数优先、层级边界明确、各入口状态语义唯一、移除无功能价值的装饰层。

### 1.2 从 `design-system/funlock/MASTER.md` 继承什么

| 继承项 | 落地方式 |
|---|---|
| 安全蓝主色 `#0369A1` | 主操作、焦点环、选中态、链接；深色模式换算为 `#38BDF8` |
| 护盾绿（保护/安全语义） | 仅用于「已解锁·安全在场」与成功反馈，不做装饰色 |
| Swiss Minimalism | 严格网格、强对齐、留白即分组、无渐变堆叠 |
| 高对比度 | 正文 ≥ 4.5:1，非文本控件边界 ≥ 3:1（第 2 章给出实测值） |
| 反模式清单 | 禁止 emoji 图标；禁止不可见焦点；禁止布局位移式 hover；禁止低于 4.5:1 的正文 |

### 1.3 明确舍弃的 Web 产物

| MASTER.md 产物 | 舍弃原因 | macOS 原生替代 |
|---|---|---|
| Google Fonts（Outfit / Work Sans） | 系统应用引入网络字体既慢又破坏系统一致性 | SF Pro Text / Display + SF Mono（通过 SwiftUI 语义字号与 `design: .monospaced` 取得） |
| Page Pattern：Hero + Features + CTA | 落地页结构，与 4 分区桌面工具无关 | 4 Tab 仪器面板（第 4 章） |
| GSAP Scroll Reveal / `prefers-reduced-motion` 的 JS 实现 | 原生应用无滚动揭示需求，Motion 3/10 只保留状态反馈 | `accessibilityReduceMotion` + 120–200ms 状态过渡（第 8 章） |
| CSS px / rem / `cursor:pointer` / 响应式断点 | 平台语义不同 | pt + 4/8pt 网格；`NSCursor` 由 AppKit 负责；窗口最小尺寸约束 |
| CSS 组件片段（`.btn-primary` 等） | 仅作视觉参照 | 第 2.6 节的 SwiftUI 组件族 |

### 1.4 明确告别的现有视觉

| 现有实现 | 问题 | 替代方案 |
|---|---|---|
| `LiquidAuroraMesh`（5 色径向极光 + blur 20） | 全屏彩色渐变抢占读数注意力；blur 与逐帧合成增加 GPU/CPU 成本；8GB 机器已因动画空转踩过坑 | 中性表盘基底：`Window Canvas` / `Sidebar Surface` / `Card Surface` 三级实体表面，零渐变、零全屏模糊 |
| 彩虹色散双描边（`LiquidCardModifier` 两层 `strokeBorder` + 双色投影） | 视觉噪声、深浅色分支散落在每个组件、无法统一 | 1px 实体描边 + 明确 elevation 阶梯（卡片不再"发光"） |
| `colorScheme == .dark ? x : y` 遍地硬编码 | 无单一来源，任何调整需多点改动 | `FUnlockTheme` 动态色 token，只在 token 定义处出现一次明暗分支 |
| `Animation.funSpring`（0.32 / 0.78）作为万能动效 | 仪器感应克制；大量弹簧让界面"软" | `FUnlockMotion.standard`：easeOut 150ms；仅拖拽释放可以 200ms 收敛 |

### 1.5 五条核心原则

1. **读数优先**：任何装饰不得与 dBm 数字、状态徽标争夺注意力。彩色面积以「一个屏幕不超过两处语义色块」为上限。
2. **单一语义源**：同一状态在侧边栏、Popover、诊断页必须是同一个组件、同一套颜色、同一句文案（第 3 章）。
3. **边界靠层级，不靠颜色**：表面三级 + 1px 描边即可表达从属关系；颜色只承担状态语义。
4. **一切可键盘**：每个自定义控件都有焦点环、键盘操作与 VoiceOver 语义；拖拽控件必须有非拖拽替代（第 5、8 章）。
5. **性能即设计约束**：不使用全屏模糊、不使用常驻循环动画、不在滚动列表内使用阴影；所有动效必须可被系统"减弱动态效果"关闭。

---

## 2. 浅色 / 深色双态 Design Tokens（`FUnlockTheme` 映射表）

### 2.1 色板（Light）

| Token | Hex | 角色 | 实测对比度 |
|---|---|---|---|
| `canvas` | `#F4F6F8` | 主窗口底色（滚动区） | — |
| `sidebar` | `#ECEFF3` | 侧边栏表面 | — |
| `card` | `#FFFFFF` | 卡片 / 行容器 | — |
| `well` | `#EEF2F6` | 内嵌凹槽：输入槽、图表底、步进器底 | — |
| `border` | `#D8E0E8` | 装饰性分隔线与卡片描边 | 1.23:1 vs canvas（仅装饰） |
| `border-strong` | `#64748B` | **可交互控件边界**（输入框、分段控件、聚焦容器） | 4.39:1 vs canvas / 4.76:1 vs card |
| `text-primary` | `#0F172A` | 正文、标题、读数 | 16.48 / 17.85 / 15.48（canvas / card / sidebar） |
| `text-secondary` | `#475569` | 说明、单位、次要标签 | 6.99 / 7.58 / 6.57 |
| `text-tertiary` | `#64748B` | 极次要信息（仅限非关键提示） | 4.39 / 4.76 / 4.12 |
| `accent` | `#0369A1` | 主操作、选中、链接、焦点环 | 5.48 / 5.93 / 5.14 |
| `accent-hover` | `#075985` | 主操作 hover/pressed | 6.98 / 7.56 / 6.56 |
| `on-accent` | `#FFFFFF` | 主按钮文字 | 5.93 on accent |
| `safe-text` | `#15803D` | 绿色**文字**（card/canvas 上） | 5.02 / 4.63 / **4.35（sidebar 不足）** |
| `safe-text-alt` | `#166534` | 绿色文字（sidebar / well 上） | 6.18 / 6.58 |
| `safe-fill` | `#16A34A` | 绿色**填充/图形**（点、条、图标底） | 3.30 card / 3.04 canvas / **2.86 sidebar 不足** |
| `amber-text` | `#B45309` | 琥珀**文字**（card/canvas 上） | 5.02 / 4.64 / **4.35（sidebar 不足）** |
| `amber-text-alt` | `#92400E` | 琥珀文字（sidebar / well 上） | 6.15 / 6.54 |
| `amber-fill` | `#D97706` | 琥珀填充/图形 | 3.19 card / 2.94 canvas / **2.76 sidebar 不足** |
| `danger-text` | `#DC2626` | 危险**文字**（card 上） | 4.83 card / **4.46 canvas** / **4.19 sidebar** |
| `danger-text-alt` | `#B91C1C` | 危险文字（canvas / sidebar 上） | 5.97 / 5.61 |
| `danger-fill` | `#DC2626` | 危险填充（删除按钮底、告警条） | 白字 4.83:1 ✓ |

> **规则（由实测值反推，必须遵守）**
> 1. 绿色、琥珀、红色在浅色模式下**只有 `*-text` 可用于文字**；`*-fill` 仅用于图形与填充，且不得放在 sidebar 表面（< 3:1）。
> 2. 在 `sidebar` / `well` 上使用绿色或琥珀文字时，必须切到 `*-text-alt`。
> 3. `danger-text` 在 canvas 上为 4.46:1，低于正文门槛 → canvas 上的危险文字使用 `danger-text-alt`。
> 4. `border` 只做装饰；任何"靠边框才能识别"的控件必须用 `border-strong`。
> 5. 主按钮一律 `on-accent` on `accent`（5.93:1），hover 切 `accent-hover`。

### 2.2 色板（Dark）

| Token | Hex | 角色 | 实测对比度 |
|---|---|---|---|
| `canvas` | `#0D1117` | 主窗口底色 | — |
| `sidebar` | `#121720` | 侧边栏表面 | — |
| `card` | `#161C26` | 卡片 / 行容器 | — |
| `well` | `#1E2633` | 内嵌凹槽 | — |
| `border` | `#2A3444` | 装饰性描边 | 1.51:1 vs canvas（仅装饰） |
| `border-strong` | `#64748B` | 可交互控件边界 | 3.98:1 vs canvas / 3.59:1 vs card |
| `text-primary` | `#F1F5F9` | 正文/读数 | 17.27 / 15.61 / 16.40 |
| `text-secondary` | `#94A3B8` | 说明/单位 | 7.38 / 6.67 / 7.01 |
| `text-tertiary` | `#64748B` | 极次要信息 | 3.98 / 3.59 / 3.79 |
| `accent` | `#38BDF8` | 主操作、选中、链接、焦点环 | 8.83 / 7.98 / 8.38 |
| `on-accent` | `#082F49` | 主按钮文字 | 6.48 on accent |
| `safe` | `#22C55E` | 绿色文字与图形（深色下统一一档） | 8.31 / 7.50 / 7.88 |
| `amber` | `#F59E0B` | 琥珀文字与图形 | 8.81 / 7.96 / 8.36 |
| `danger` | `#F87171` | 危险文字与图形 | 6.84 / 6.18 / 6.49 |

> 深色模式所有语义色对三种表面均 ≥ 6:1，**文字与图形可共用同一档**，无需 alt 变体。禁止把 `#475569` 当深色文字（vs card 仅 2.26:1）。

### 2.3 `FUnlockTheme` 的实现契约

**唯一允许出现明暗分支的地方**是 token 定义。使用 `NSColor` 动态 provider 一次绑定，调用点不再读 `colorScheme`：

```swift
enum FUnlockTheme {
    // 单一来源：外观切换由 AppKit 驱动，调用点无需分支
    private static func dyn(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    enum Surface {
        static let canvas  = dyn(.init(srgbHex: 0xF4F6F8), .init(srgbHex: 0x0D1117))
        static let sidebar = dyn(.init(srgbHex: 0xECEFF3), .init(srgbHex: 0x121720))
        static let card    = dyn(.init(srgbHex: 0xFFFFFF), .init(srgbHex: 0x161C26))
        static let well    = dyn(.init(srgbHex: 0xEEF2F6), .init(srgbHex: 0x1E2633))
        static let border       = dyn(.init(srgbHex: 0xD8E0E8), .init(srgbHex: 0x2A3444))
        static let borderStrong = dyn(.init(srgbHex: 0x64748B), .init(srgbHex: 0x64748B))
    }

    enum Text {
        static let primary   = dyn(.init(srgbHex: 0x0F172A), .init(srgbHex: 0xF1F5F9))
        static let secondary = dyn(.init(srgbHex: 0x475569), .init(srgbHex: 0x94A3B8))
        static let tertiary  = dyn(.init(srgbHex: 0x64748B), .init(srgbHex: 0x64748B))
    }

    enum State {
        static let safeText    = dyn(.init(srgbHex: 0x15803D), .init(srgbHex: 0x22C55E))
        static let safeTextAlt = dyn(.init(srgbHex: 0x166534), .init(srgbHex: 0x22C55E))
        static let safeFill    = dyn(.init(srgbHex: 0x16A34A), .init(srgbHex: 0x22C55E))
        static let amberText    = dyn(.init(srgbHex: 0xB45309), .init(srgbHex: 0xF59E0B))
        static let amberTextAlt = dyn(.init(srgbHex: 0x92400E), .init(srgbHex: 0xF59E0B))
        static let amberFill    = dyn(.init(srgbHex: 0xD97706), .init(srgbHex: 0xF59E0B))
        static let dangerText    = dyn(.init(srgbHex: 0xDC2626), .init(srgbHex: 0xF87171))
        static let dangerTextAlt = dyn(.init(srgbHex: 0xB91C1C), .init(srgbHex: 0xF87171))
        static let dangerFill    = dyn(.init(srgbHex: 0xDC2626), .init(srgbHex: 0xF87171))
    }

    enum Accent {
        static let base    = dyn(.init(srgbHex: 0x0369A1), .init(srgbHex: 0x38BDF8))
        static let hover   = dyn(.init(srgbHex: 0x075985), .init(srgbHex: 0x38BDF8))
        static let onAccent = dyn(.init(srgbHex: 0xFFFFFF), .init(srgbHex: 0x082F49))
    }

    enum Radius {
        static let sm: CGFloat = 6      // 输入、徽标、图标底
        static let md: CGFloat = 10     // 行、卡片内嵌块
        static let lg: CGFloat = 12     // 主卡片、Popover 卡片
        static let pill: CGFloat = 9999 // 胶囊标签
    }

    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 20
        static let xl: CGFloat = 24
    }

    enum Motion {
        static let fast = Animation.easeOut(duration: 0.12)
        static let standard = Animation.easeOut(duration: 0.15)
        static let settle = Animation.easeOut(duration: 0.20)
    }
}
```

> 颜色初始化用 `NSColor(srgbHex:)` 方便评审；实施时改为 `NSColor(srgbRed:green:blue:alpha:)` 或等价实现即可，不引入第三方依赖。

### 2.4 圆角阶梯

| Token | 值 | 使用位置 | 迁移要求 |
|---|---|---|---|
| `radius-sm` | 6pt | TextField、图标徽标、步进器单元 | 现有 8pt 输入槽改为 6pt |
| `radius-md` | 10pt | 列表行、卡片内嵌块、筛选 chip 容器 | 现有 8/9pt 行高亮统一为 10pt |
| `radius-lg` | 12pt | 主卡片、Popover 状态卡、Sheet 内容卡 | 现有 13/14/16pt 全部收敛到 12pt |
| `radius-pill` | 9999pt | 胶囊标签、状态徽标、开关轨道 | 现有 Capsule 保持 |

> 迁移后全仓不应再出现 13/14/16 的卡片圆角字面量；圆角只允许从 `FUnlockTheme.Radius` 取。

### 2.5 间距阶梯（4/8pt 网格）

`4 / 8 / 12 / 16 / 20 / 24`（对应 `xxs / xs / sm / md / lg / xl`）。

| 场景 | 旧值（示例） | 新值 |
|---|---|---|
| 内容区左右内边距 | `14` | `16`（xl 用于 Sheet） |
| 卡片内 padding | `14` | `16` |
| 卡片间距 | `12` | `12`（sm） |
| 行内元素间距 | `8 / 10` | `8`（xs） |
| 行垂直 padding | `7 / 6 / 5` | `8`（xs）；紧凑行 `4`（xxs） |
| 图标与文字 | `10` | `8`（xs） |
| 分组小节间距 | `20` | `20`（lg） |

> 禁止出现 `10 / 14 / 18` 等非网格值；现有 `padding(.horizontal, 14)`、`spacing: 10` 全部按上表迁移。

### 2.6 排版体系

**全部改用语义字号**，消除现有 20 处 `.system(size: 11)`、8 处 `13`、5 处 `12` 等魔数。

| 语义样式 | macOS 视觉尺寸 | 用途 | 旧硬编码映射 |
|---|---|---|---|
| `.largeTitle`（monospaced, digit） | 26 | 信号盘主读数（可配 `@ScaledMetric` 微调，唯一例外） | `size: 30 / 36 / 40` |
| `.title2` | 17 | 页面/Sheet 标题 | `title3.bold`、`size: 22` |
| `.headline` | 13 semibold | 分组标题、卡片标题 | `subheadline.weight(.semibold)` |
| `.body` | 13 | 正文、行标题、按钮 | `size: 13 / 12` |
| `.callout` | 12 | 说明文字、次要正文 | `size: 12 / 11` |
| `.caption` | 11 | 单位、辅助说明 | `size: 11` |
| `.caption2` | 10 | 极次要标注（图例） | `size: 10` |
| `.body` + `design: .monospaced` | 13 | dBm、时间戳、版本号、MAC | `size: 11~13, design: .monospaced` |

规则：

1. 所有数字读数必须 `.monospacedDigit()`；RSSI/dBm/百分比/计数一律 SF Mono 等宽。
2. 不允许 `.font(.system(size:))` 出现在视图里；唯一例外是信号盘主读数，使用 `@ScaledMetric(relativeTo: .largeTitle)` 并标注 `// token: metric-display`。
3. 行高不写死；容器使用 `padding` 而非固定 `frame(height:)`，为"更大文本"留出空间。
4. 每个语义样式在浅/深两种表面都必须过第 2.1/2.2 节的对比度门槛。

### 2.7 组件族（替换现有 Liquid Glass 组件）

| 旧组件 | 新组件 | 规格 |
|---|---|---|
| `LiquidAuroraMesh` | **删除** | 无替代；窗口底色即 `Surface.canvas` |
| `LiquidCardModifier` / `.liquidGlassCard()` | `FUnlockCard` | `Surface.card` + 1px `Surface.border`（`radius-lg`）；无阴影、无渐变 |
| `LiquidDivider` | `Hairline` | 1px `Surface.border`，不加水平渐隐 |
| `LiquidAmberBanner` | `InlineNotice(.warning / .danger / .info)` | `well` 底 + 4pt 左侧语义色条 + `*-text` 文案；不使用整块橙底 |
| `LiquidIconBadge` | `IconTile` | `radius-sm` + `State.*Fill` 12% 底 + 语义色图标（不铺满整块渐变） |
| `LiquidInputField` | `FieldStyle` | `well` 底 + 1px `border-strong` + 聚焦 2pt `accent` 环（offset 2） |
| `LiquidPillButton` | `InstrumentButton`（primary / secondary / ghost / destructive） | 主：`accent` 底 `on-accent` 字；次：透明底 + `border-strong`；高度 28pt；hover 仅改底色，不做位移 |
| `MenuRowButton` | `ControlRow` | 保留快捷键提示与 hover/pressed；hover 底色 = `well`；焦点环必须可见 |
| `Animation.funSpring` | `FUnlockMotion.fast / standard / settle` | 见 2.3 |

---

## 3. 统一状态语义契约

### 3.1 四种主状态（单源）

新建 `StatusPresentation`（建议放在 `FUnlockTheme.swift` 或 `StatusSemantics.swift`），**Sidebar、Popover、Overview 状态卡全部消费同一个映射**，禁止各视图各自 `switch manager.state.screen`。

| 状态 | 判定 | 图标 | 颜色 token | 主文案 key | 现有冲突 |
|---|---|---|---|---|---|
| `unlocked` | `screen == .unlocked` | `lock.open.fill`（实心） | `safeFill` / `safeText` | `mb_unlocked`「已解锁」 | 一致 |
| `locked` | `screen ∈ {.locked}` 且 `connected` | `lock.fill` | `amberFill` / `amberText` | `mb_locked`「已锁定」 | 一致 |
| `standby` | `screen ∈ {.screensaver, .displaySleeping}` | `moon.zzz.fill`（空心可选） | `Text.secondary`（中性） | **新增 `status_standby`「待机」** + 详情行 `status_screensaver` / `status_display_sleeping` | **现状：Sidebar 灰 / Popover 橙，必须统一为中性** |
| `disconnected` | 未绑定设备，或 `connected == false` | `wifi.slash` | `Text.secondary`（无设备）/ `dangerText`（已绑定但失联） | `mb_disconnected`「未连接」/ `no_device`「未绑定设备」 | Popover 现为 secondary；Sidebar 无此分支 |

**契约细节**

1. 「失联」不再用橙色：橙色专属于 `locked`。已绑定设备失联用 `dangerText` 图标 + 文案，未绑定用 `text-secondary`。
2. `standby` 的中性色表达"屏幕不可见，但设备可能仍在附近"；它与 `locked` 的区别是**屏幕是否已锁**，不是"好坏"。
3. 颜色之外必须同时有：不同图标 + 文案。任何地方不得只靠圆点颜色表达状态。
4. 圆点呼吸动画仅允许出现在 Popover 的 `unlocked` 态，且必须满足第 8 章三条（可见性启停、Reduce Motion、静态回退）。

### 3.2 信号强度：两把尺子，互不混用

| 尺子 | 数据源 | 档位 | 用途 | 现有实现 |
|---|---|---|---|---|
| **绝对信号质量**（固定阈值） | `effectiveRSSI` | `> -60` 极佳 / `-75…-60` 良好 / `< -75` 较弱；5 格细分为 5/4/3/2/1 | Popover 信号格与档位文案；设备列表排序后的质量色 | `MenuBarPopoverView.signalLevel`（-60 / -75 边界有单测锁定，**不得改动**） |
| **距离场景**（用户阈值） | `rssi` + `unlockRSSI` / `lockRSSI` | 非常近（≥ -45）/ 在范围内（≥ unlock）/ 接近中（≥ lock）/ 减弱（≥ lock-10）/ 远离 | Overview 场景文案与颜色；Range Rail 分区 | `OverviewView.scenarioText / scenarioColor` |

**统一规则**

1. 两把尺子各有明确标签：Popover 写「信号质量」，Overview 写「距离场景」。UI 上不得只出现一列无标签的彩色文字。
2. 用户拖动阈值时，信号格（绝对质量）**不得变化**；场景文案与 Range Rail 变化。这一点必须在设计文档和原型里显式演示，避免评审误判为 bug。
3. 数值文本统一：无信号或 `effectiveRSSI ≤ -100` 显示 `-- dBm`；否则 `%.0f dBm`。该格式已被单测覆盖（`MenuBarPopoverView.signalText`）。
4. 质量色：极佳/良好用 `safeFill`，较弱用 `amberFill`，危险/远离用 `dangerFill`；颜色永远配文字档位。

---

## 4. 信息架构重构：7 Tab → 4 主分区

### 4.1 新侧边栏结构

```
FUnlock（无分组标题，仪器面板不需要）
├─ 总览仪表        Overview      gauge.with.dots.needle.bottom.50percent
├─ 行为与通知      Behavior      switch.2
├─ 场景与配置      Scenarios     square.stack.3d.up
├─ 信号与诊断      Diagnostics   waveform.path.ecg
└─ （底部固定）设备状态条 + 版本条 v2.8.37 → 点击打开「关于」Sheet
```

* 侧边栏宽度维持 `180 / 200 / 240`，背景 `Surface.sidebar`，与内容区之间用 1px `Surface.border` 分隔（不再整体透出极光）。
* 顶部设备状态条改为 `StatusBadge` + 设备名 + 信号质量的紧凑行，颜色语义与第 3 章一致。
* 底部版本条是新入口：`FUnlock 2.8.37 (1526)`，点击 → `AboutView` Sheet。**修复现状 `showAbout` 永不为真的死 UI。**

### 4.2 Tab 1：总览仪表（Overview）

| 区块 | 内容 | 来源 |
|---|---|---|
| A. 信号仪表 | 环形信号盘（主读数 + 档位 + `距离场景` 标签）；无信号显示 `—` + `scenario_no_signal` | `OverviewView.signalRing` |
| B. 设备卡 | 已绑定设备名/图标、更换设备（展开扫描列表）、解绑（破坏性确认） | 现有 `deviceStatusSection` |
| C. 交互式距离标尺 | 见第 5 章（替代 thresholdBar + hysteresisBand + 2 Slider + 2 输入行） | 新组件 |
| D. 校准入口 | 「自动校准向导」主按钮 → Sheet | 现有 `showCalibration` |
| E. 权限提醒 | 若 AX/蓝牙缺失，在内容区顶部显示 `InlineNotice(.warning)`（两个权限各一条，含「前往设置」） | 现有 `LiquidAmberBanner` 语义 |

未绑定设备时：只显示 B 的扫描引导卡（`select_device` / `scan_hint` / `start_search` / `no_device`），不显示 A、C。

### 4.3 Tab 2：行为与通知（Behavior）

四张分组卡片，顺序固定：

| 分组 | 控件 | Key（@AppStorage） |
|---|---|---|
| 运行 | 启用 FUnlock / 开机启动 | `enabled` / `launchAtLogin` |
| 解锁 | 靠近唤醒 / 唤醒但不解锁 / 使用屏幕保护程序 | `wakeOnProximity` / `wakeWithoutUnlocking` / `screensaver` |
| 锁定 | 锁定时暂停播放 / 锁定时关闭屏幕 / 输入活动时暂缓锁定 | `pauseItunes` / `sleepDisplay` / `lockOnIdle` |
| 通知 | iMessage 卡 + Bark 卡（原样迁移两卡全部控件与校验） | `iMessageNotify` / `iMessageNotifyRecipient` / `barkNotify` / `barkNotifyKey` / `barkNotifyServer` |

* 每个开关行：`IconTile` + 标题 + 说明（`*.desc`）+ 右侧系统风格开关；行高 ≥ 36pt。
* 通知卡保留：输入即时校验、行内错误、授权状态（iMessage）、测试按钮与结果文案，**一条不省**。
* 底部不放"应用"按钮：这些开关即时生效（与现状一致）。

### 4.4 Tab 3：场景与配置（Scenarios）

| 分组 | 内容 | 来源 |
|---|---|---|
| 网络 | 连接指定 Wi-Fi 时暂停 / SSID 输入 + 「使用当前 Wi-Fi」/ 定位提示 / 被动模式 | `NetworkSettingsView` |
| 配置档 | Picker + 新建 / 删除（仅非 default）/ 导入 / 导出 + 三个确认弹窗 | `ConfigSettingsView` 卡片 1 |
| 备份 | 导出全部设置 / 导入全部设置 + 替换确认 + 结果 toast | `ConfigSettingsView` 卡片 2 |
| 自动化 | **新增单脚本卡**：一个 `event` 脚本路径 + 4 个事件参数标签 + 「打开脚本目录」+「重建示例脚本」 | `AutomationView`（原死 UI） |

**自动化缺陷修复（必须）**：现状 `AutomationView.isScriptConfigured()` 对 4 行都检查同一个 `event` 文件，导致四行状态永远相同。新规格改为**单一卡片**：

* 标题：`automation_title`「场景自动化」
* 状态：`automation_configured`「已配置」/ `automation_not_configured`「未配置」（基于 `event` 文件存在且可执行）
* 四个只读参数标签（不是四个按钮）：`event_away`「设备远离」`$1=away`、`event_lost`「信号丢失」`$1=lost`、`event_unlocked`「自动解锁」`$1=unlocked`、`event_intruded`「手动解锁」`$1=intruded`
* 说明：`automation_hint`「将可执行脚本放入对应目录，事件触发时自动运行。」
* 动作：`automation_open_folder`「打开脚本目录」（新建示例脚本只在文件缺失时生成，行为与现状一致）
* 若未来要支持每事件独立脚本，再引入 `event-<name>` 并迁移；本期不做（避免 ScriptRunner 行为变更）。

### 4.5 Tab 4：信号与诊断（Diagnostics）

自上而下：

1. **KPI 行**：今日解锁 / 今日锁定 / 本周解锁（大数字 `.title` + 等宽数字 + 图标），数据源 `StatsCalculator`。
2. **图表卡**：分段控件「信号曲线 / 斜率变化」+ `SignalChartView` / `SlopeChartView` + 图例；空数据显示 `stats_no_data`。
3. **决策时间线**：筛选 chip（全部/解锁/锁屏/系统/用户）+ 按日期分组 + 40 行分块 + 操作按钮（`action_*`）+ 空状态 + 底部「导出诊断信息 / 清空记录」。

* `⌘S` 行为变更：从「打开 StatsView Sheet」改为「激活主窗口并切到 Tab 4」。快捷键保留。
* Popover 的「解锁统计」行同样改为跳转 Tab 4，不再弹 Sheet。
* `StatsView` 作为独立 Sheet **删除**（其内容全部并入本 Tab）。
* 图表保留 120 点降采样；时间线保留 40 行分块；筛选逻辑与导出 zip 逻辑不变。

### 4.6 旧入口 → 新归属 → 核心 Key 对照表

| 旧入口 | 新归属 | 核心 Localizable Key |
|---|---|---|
| 侧边栏「总览」 | Tab 1 | `overview`、`distance_threshold`、`hysteresis_band`、`change_device`、`unbind*`、`select_device`、`scan_hint`、`start_search`、`calibration_wizard` |
| 侧边栏「基础」 | Tab 2 · 运行 | `enable`、`enable_desc`、`launch_at_login`、`launch_at_login_desc` |
| 侧边栏「解锁」 | Tab 2 · 解锁 + 通知 | `wake_on_proximity*`、`wake_without_unlock*`、`use_screensaver*`、`im_*`、`bark_*` |
| 侧边栏「锁定」 | Tab 2 · 锁定 | `pause_on_lock*`、`sleep_display_on_lock*`、`defer_lock_on_input*` |
| 侧边栏「网络」 | Tab 3 · 网络 | `pause_on_wifi*`、`wifi_ssid*`、`current_wifi`、`wifi_need_location`、`wifi_unavailable`、`passive_mode*` |
| 侧边栏「配置」 | Tab 3 · 配置档 + 备份 | `profile*`、`settings_*` |
| 侧边栏「诊断」 | Tab 4 | `diagnostics_*`、`reason_*`、`action_*` |
| Popover「解锁统计」/ `⌘S` | Tab 4（跳转） | `menu_stats`、`unlock_stats`、`stats_*` |
| 主窗口 sheet「统计」 | 删除（并入 Tab 4） | — |
| 主窗口 sheet「自动化」（原不可达） | Tab 3 · 自动化（新入口） | `automation_*`、`event_*` |
| 主窗口 sheet「关于」（原不可达） | 侧边栏底部版本条 → Sheet | `about_*`、`done` |
| 主窗口 sheet「校准」 | Tab 1 入口 → Sheet（皮肤统一） | `calibration_*` |
| 首次引导 sheet | 保持 sheet，补「上一步 / Esc / 打开校准」 | `onboarding_*` + 新增 key |
| 首次权限窗口 | 保持独立窗口，皮肤统一 | `permission_*` |
| 菜单栏图标 | Popover（8 项不变） | `menu_*`、`mb_*` |
| 底部栏「立即锁定 / 退出」 | 保留在 4 Tab 共用的底栏 | `lock_now`、`quit` |

### 4.7 品牌统一为 `FUnlock`

| 位置 | 现状 | 目标 |
|---|---|---|
| `CFBundleName` | `Funlock` | `FUnlock` |
| 主窗口标题 | `Funlock` | `FUnlock` |
| About 标题 | `Funlock` | `FUnlock` |
| 状态栏 toolTip | `Funlock` | `FUnlock` |
| 文案 `quit` / `about` / `permission_check_window_title` 等 | `Funlock` | `FUnlock`（8 个 lproj 全部同步） |

> 这是一次纯展示层改名，不涉及 bundle identifier、签名与 Keychain 服务名。

---

## 5. 核心创新组件：交互式距离标尺（Interactive Range Rail）

### 5.1 目标

用一个组件替代现状四处重复表达：`thresholdBar`（三游标）、`hysteresisBand`（缓冲带）、两个 `Slider` 行、两个数字输入行。

### 5.2 定义域（必须以代码为准）

* 阈值范围：**`-95 … -30 dBm`**（`SignalHysteresisEngine.rssiRange`）。
  ⚠️ **原型对齐项**：任务书与可能的 HTML 原型写的是 `-100 … -30`，与代码不符。**统一使用 -95**，否则手柄位置与 `clampRSSI` 不一致。
* 方向：左 = 远（-95），右 = 近（-30）。
* 坐标：`x(v) = (v - (-95)) / 65 × railWidth`，手柄中心与指针共用同一函数。
* 偏移量范围：`0 … 20 dB`（`offsetRange`）；默认唤醒提前量 20、预解锁触发量 10。
* 迟滞间隔常量：`lockUnlockDelayGap = 10 dB`。

### 5.3 视觉结构（单行刻度尺，高 64pt）

```
 -95                          -65            -45                 -30
  ├─────────── 锁定区 ────────┼── 缓冲带 ──┼──── 解锁区 ────────────┤
  │        红 8% 底           │ 琥珀 12% 底 │      绿 8% 底          │
  │                        ◉ 锁定手柄      ◉ 解锁手柄               │
  │                               ┆ 实时 RSSI 指针                   │
  │                        ┄ 唤醒提前刻度   ┄ 预解锁刻度             │
```

| 元素 | 规格 |
|---|---|
| 轨道 | 高 8pt，`well` 底，`radius-pill`；1px `border-strong` 外框 |
| 锁定区 | `dangerFill` 8% 底；左端点画 3pt 竖刻度 + `rail_zone_lock`「锁定区」caption2 |
| 缓冲带 | 两手柄之间，`amberFill` 12% 底；顶部居中浮动 `xx dB` 等宽数字；< 10 dB 时文字转 `dangerText` 并提示"建议 ≥ 10 dB" | 
| 解锁区 | `safeFill` 8% 底；右端 3pt 刻度 + `rail_zone_unlock`「解锁区」 |
| 锁定手柄 | 14×20pt 胶囊，`dangerFill` 实心 + 2pt `card` 描边；hit area 24×32pt |
| 解锁手柄 | 同上，`safeFill` |
| 实时指针 | 2pt 竖线 + 顶部 `−67 dBm` 胶囊（`well` 底、等宽、`text-primary`）；无信号时指针隐藏、胶囊显示 `-- dBm`（`text-secondary`） |
| 唤醒提前刻度 | 虚线 1pt，位置 `unlock - wakeAdvance`；标签 `wake_advance`「唤醒提前量」 |
| 预解锁刻度 | 点线 1pt，位置 `unlock - preUnlockTrigger`；标签 `pre_unlock_trigger`「预解锁触发量」 |
| 图例 | 尺下方一行 4 项：锁定阈值 / 缓冲带 / 解锁阈值 / 实时信号；色块 + 文案，`caption2` |
| 焦点环 | 手柄聚焦时 2pt `accent` 环（offset 2），键盘可 Tab 到 |

### 5.4 交互规则

1. **拖动**：手柄可水平拖动；拖动中只改本地草稿（`sliderLock` / `sliderUnlock`），不写盘；释放后触发联动。
2. **联动（沿用现有语义，不可改）**：
   * 解锁手柄释放时：若锁定手柄未被用户单独修改或已越界，锁定自动置于 `unlock - 10`（并 clamp 到 -95）。
   * 锁动手柄释放时：强制 `lock ≤ unlock - 1`。
   * 用户单独修改过锁定手柄后，解锁联动不再覆盖它。
3. **脏态应用栏**：尺下方右侧固定 `primary`「应用阈值」（`apply_thresholds`）与 `ghost`「还原」（`rail_revert`）；未改动时按钮显示 `applied`「已应用」且禁用（沿用 `isThresholdApplied` 判定）。
4. **应用顺序**：`setUnlockRSSI(unlock)` → `setLockRSSI(lock)` → `setWakeAdvance` → `setPreUnlockTrigger`（与现状一致；`setUnlockRSSI` 内部会做迟滞联动，随后 `setLockRSSI` 覆盖）。
5. **键盘（WCAG 2.2 单指针替代）**：手柄聚焦后 `←/→` ±1 dB，`Shift+←/→` ±5 dB，`Home/End` 到边界；每次变更即时更新草稿与读数，`Return` 应用，`Esc` 还原。
6. **数字替代**：尺下方 4 格精密步进器（`Well` + `radius-sm` + 等宽数字 + `−`/`+` 按钮 + 可直接输入）：
   * 锁定阈值（-95…-31）
   * 解锁阈值（-94…-30，或"关闭自动解锁"哨兵 `UNLOCK_DISABLED = 1` 的独立开关，见 5.5）
   * 唤醒提前量（0…20）
   * 预解锁触发量（0…20）
   输入越界时即时 clamp 并给出 caption 提示；不允许静默截断。
7. **VoiceOver**：手柄暴露 `.isAdjustable`，value 为 `"锁定阈值 -72 dBm"`；每次调整播报新值。整条尺作为 group，label 汇总四段数值。
8. **动画**：指针跟随用 `FUnlockMotion.fast`（120ms）；拖动手柄无动画；Reduce Motion 下全部改为瞬时。

### 5.5 边界状态

| 状态 | 表现 |
|---|---|
| 自动解锁关闭（`unlockRSSI == 1`） | 解锁手柄隐藏，右端显示 `disabled`「禁用」胶囊；缓冲带与解锁区不渲染；数字步进器显示"关闭自动解锁"开关 |
| 无信号 | 指针隐藏，`-- dBm`；分区与手柄仍可编辑 |
| 缓冲带 < 10 dB | 缓冲带文字 `dangerText` + 提示"建议 ≥ 10 dB"，但不阻止应用（与现状一致：只 clamp 序关系） |
| 手柄越界拖动 | 实时 clamp，手柄贴边并轻微高亮边界 |

---

## 6. MenuBar Popover（282pt）重设计

保持 **8 项功能 1:1**，只换装。

| # | 区域 | 规格 |
|---|---|---|
| 0 | 容器 | 宽 282pt；内容 `Surface.card`（不透明，仅 Popover 外壳保留系统材质）；`radius-lg`；1px `Surface.border`；无极光、无彩虹描边、无彩色投影 |
| 1 | 设备状态卡 | `StatusBadge`（第 3 章）+ 设备名（`.body` semibold）+ 信号质量格（5 格 `safeFill/amberFill/dangerFill`）+ `-- dBm` 等宽读数；卡片 `Surface.well` 内嵌于 `card` |
| 2 | 启用 Funlock | 整行 `ControlRow` + 自绘开关（沿用现有 `accessibilityAddTraits(.isToggle)` 与 value）；开启色 `safeFill`，关闭色 `text-tertiary` |
| 3 | 打开设置 | `ControlRow`，`⌘,`；行为：激活主窗口（不新建） |
| 4 | 重新设置密码 | `ControlRow`；沿用 `SecurityService.askPassword()` |
| 5 | 检查更新 | `ControlRow` + 5 态（idle/checking/downloading(%)/latest/failed）；图标与文案沿用现有 key |
| 6 | 解锁统计 | `ControlRow`，`⌘S`；**行为变更**：跳转主窗口 Tab 4（不再弹 Sheet） |
| 7 | 立即锁定 | `ControlRow`，`⌃⌘Q`，`dangerText` 文字 + `dangerFill` 图标 |
| 8 | 退出 | `ControlRow`，`⌘Q` |

* 行高 32pt；行间 1px `Hairline`；危险操作前保留一条分隔（与现状一致）。
* hover：`Surface.well` 底，无位移；pressed：`accent` 8% 叠底。
* 状态点呼吸仅 `unlocked` 且 Popover 可见时运行；`NSPopover.didShow/didClose` 启停逻辑保留。
* 无 `colorScheme` 分支：全部来自 `FUnlockTheme`。

---

## 7. 全 Sheet 视觉统一方案

### 7.1 统一骨架

新增 `SheetScaffold`：标题（`.title2`）+ 右上角关闭按钮（`xmark`，`ghost`）+ 内容滚动区（`xl` 内边距）+ 底部主/次按钮区（右对齐，`Return` 主操作、`Esc` 取消）。所有 Sheet 使用 `Surface.canvas` 底 + `FUnlockCard` 内容卡，**全部删除 `.formStyle(.grouped)`**。

| Sheet | 现状问题 | 目标 |
|---|---|---|
| `CalibrationWizardView` | `Form(.grouped)` 灰白皮肤；无 Esc | 5 步流程与文案原样；步骤指示改为"步骤 n/2 + 进度环"；环形进度用 `accent` / `safeFill` / `amberFill`；采样读数等宽；`Esc` = 取消并调用 `endCalibration()` |
| `AboutView` | `Form(.grouped)`；品牌写 `Funlock` | 统一卡片；品牌 `FUnlock`；版本号等宽；三按钮（访问主页 / 查看更新 / 完成）；宽 320pt |
| `OnboardingView` | 无上一步、无 Esc、末步不直达校准 | 3 步保留；新增「上一步」(`onboarding_back`)，`step == 0` 时隐藏；`Esc` = 跳过（写入 `hasCompletedOnboarding`，避免下次再弹）；末步增加次要按钮「打开校准向导」(`onboarding_open_calibration`)：关闭引导 → 打开校准 Sheet |
| `PermissionCheckView` | 系统 `controlBackgroundColor` 行块，与主窗口两套皮肤 | 统一 `FUnlockCard` 行 + `InlineNotice`；保留独立窗口语义（首启一次、420pt 宽、Esc 跳过 / Return 刷新或完成）；新增：应用重新激活时自动 `refresh()`（替代只能手点的现状） |

### 7.2 Sheet 通用规则

1. 关闭：`Esc` 必须有效；破坏性操作（导入替换、删除配置、解绑）仍需二次确认。
2. 尺寸：校准 420×480、关于 320×自动、引导 360×340、权限 420×自动；均不使用 `.frame(width:)` 写死高度。
3. 焦点：打开时焦点落在主操作或第一个可交互控件；关闭后焦点回到触发控件。
4. 不使用 Material、不使用阴影铺满；Sheet 本身由系统提供浮层阴影。

---

## 8. 无障碍与 8GB 性能红线

### 8.1 无障碍逐项

| 项 | 要求 | 验收方式 |
|---|---|---|
| `accessibilityReduceMotion` | 关闭：呼吸动画、所有位移/缩放过渡；保留 ≤120ms 透明度反馈；Range Rail 指针瞬时更新 | 系统开启"减弱动态效果"后录屏/抽查 |
| `accessibilityReduceTransparency` | 所有 `Material` 退化为 `Surface.*` 实色；Popover 也不得透出壁纸 | 系统开启"降低透明度"后逐页检查 |
| Focus Ring | 每个自定义控件（`ControlRow`、chip、开关行、Rail 手柄、步进器）都有 2pt `accent` 环 + 2pt offset；不允许 `outline: none` 等价实现 | 全键盘走查 |
| VoiceOver | 所有图标按钮有 label；状态徽标读"已锁定，设备在连"；信号格读档位；Rail 读四段数值；图表提供摘要 label | VoiceOver 走查 4 Tab + 3 Sheet |
| 非颜色单一表达 | 状态 = 图标 + 文案 + 颜色；Rail 分区 = 边界刻度 + 标签 + 底色；图表序列 = 线型（实/虚/点）+ 图例文字 | 灰度截图评审 |
| 对比度 | 第 2.1/2.2 节实测值；新增颜色必须附计算值 | 提交时附对比度表 |
| 目标尺寸 | 可点击区域 ≥ 24×24pt（WCAG 2.2 AA）；行高 ≥ 28pt | 检查 hit area |
| 动态字体 | 只使用语义字号；窗口最小尺寸 560×460 下不截断关键读数 | "更大文本"设置下走查 |

### 8.2 四条已验证性能红线（必须继承）

1. **离屏停动画**：Popover 关闭、窗口不可见时不运行任何 `repeatForever` 动画（历史实测：空转 CPU 12.6%）。
2. **时间线 40 行分块**：诊断页 `timelinePageSize = 40` 保持不变，分块 id 规则不变（避免滚动帧率塌陷）。
3. **图表 120 点降采样**：`downsampleForChart(maxPoints: 120)` 保留；异常点与事件标记保持全量。
4. **状态栏位图按离散态重绘**：`MenuBarIconState` 缓存逻辑保留，仅在 unlocked/connected/disconnected 变化时重绘。

### 8.3 新增性能约束（本方向特有）

| 约束 | 原因 |
|---|---|
| 窗口背景零渐变、零 `blur`、零全屏 `Material` | 去掉极光后不应再引入任何全屏合成层；静态纯色由 WindowServer 直接合成 |
| 卡片/行不使用 `.shadow` | 滚动时阴影逐帧重绘成本高；用 1px 描边表达层级 |
| 列表行不使用 `.background(.ultraThinMaterial)` | 每行一个材质层会叠加离屏渲染 |
| Range Rail 只在拖动/数据变化时重绘 | 实时指针由 VM 节流到 ≥100ms 更新（现有信号采样频率足够） |
| 8GB 机器预算 | 空闲 CPU < 1%；Popover 关闭时 0 动画；诊断页滚动 ≥ 55fps；主窗口内存增量 < 30MB |

---

## 9. 分阶段 SwiftUI 实施路线图

> 前置条件：HTML 原型经用户确认、本规格定稿。每个 Phase 结束时工作区可编译、单测全绿。

### Phase 1 — Token 底座（预计 0.5–1 天）

| 任务 | 验收 |
|---|---|
| 新增 `FUnlockTheme.swift`（2.3 节全部 token + 动态色） | 编译通过；无 `colorScheme` 之外的明暗分支 |
| 新增 `StatusPresentation`（第 3 章单源） | 单元测试：4 状态 → icon/tint/key 映射唯一 |
| 新增基础组件：`FUnlockCard`、`Hairline`、`InlineNotice`、`IconTile`、`FieldStyle`、`InstrumentButton`、`ControlRow`、`StatusBadge` | 预览 Page 覆盖 4 状态 × 2 外观 |
| 主窗口背景改为 `Surface.canvas`，移除 `LiquidAuroraMesh` 与透明标题栏配置 | 截图对比；窗口无全屏模糊 |
| **不做**：不动页面布局 | 现有功能零回归 |

### Phase 2 — 主窗口 4 Tab + Range Rail（预计 2–3 天）

| 任务 | 验收 |
|---|---|
| `MenuTab` 改为 4 值；侧边栏改造 + 底部版本条 | 4 Tab 可用；`DistributedNotification` 的 selectTab 仍映射正确 |
| Overview：状态卡 + 设备卡 + **Range Rail** + 校准入口 + 权限 Notice | Rail：拖拽/键盘/数字输入/脏态/哨兵态全部可用；`-95…-30` 域正确 |
| Behavior：4 分组卡片，迁移 10 个开关 + 2 张通知卡 | 逐项对照第 4.3 节，零遗漏 |
| Scenarios：网络 + 配置档 + 备份 + 自动化单卡 | 三个确认弹窗措辞不变；自动化入口可达 |
| Diagnostics：KPI + 图表 + 时间线合并；删除 Stats Sheet；`⌘S` 跳转 Tab 4 | 现有 `StatsCalculator`/图表/分块/导出逻辑复用 |
| 单元测试 | 现有全量单测（基线约 519 例）0 失败；新增 Range Rail 几何与联动测试 |

### Phase 3 — Popover + 全 Sheet 换装（预计 1–2 天）

| 任务 | 验收 |
|---|---|
| Popover 8 项重构 + 统一状态语义 | 8 项功能逐项点击验证；快捷键 ⌘, ⌘S ⌃⌘Q ⌘Q 全部生效 |
| `SheetScaffold` + 校准/关于/引导/权限四 Sheet 换装 | 全部无 `.formStyle(.grouped)`；Esc 有效；About 从版本条可达 |
| 引导补「上一步 / Esc / 打开校准」 | 三步可回退；跳过后不再弹 |
| 品牌 `FUnlock` 统一（Info.plist、窗口标题、8 lproj） | 全仓 `Funlock` 仅剩历史文档与注释 |

### Phase 4 — 无障碍 + 回归 + 真机性能（预计 1–2 天）

| 任务 | 验收 |
|---|---|
| Reduce Motion / Reduce Transparency 全量接入 | 两个系统开关打开后逐页走查无动画、无透底 |
| VoiceOver 全量标签 + 焦点顺序 | 4 Tab + 4 Sheet + Popover 全键盘可完成主要任务 |
| 对比度回归（灰度截图 + 计算值） | 第 2 章表格全部达标；新增色附计算 |
| 删除 `LiquidGlass.swift` 与 `funSpring` 残留 | `grep` 无引用 |
| 全量单测 + Release 构建 + 真机验证 | 0 失败；Release 签名构建成功；8GB 机器空闲 CPU <1%、Popover 关闭 0 动画、诊断滚动 ≥55fps |

### 风险与回滚

| 风险 | 缓解 |
|---|---|
| 4 Tab 合并导致 key 迁移遗漏 | 第 4.6 节映射表 + Phase 2 逐项对照；`Localizable.strings` 不删 key，只增不改 |
| Range Rail 联动规则理解偏差 | 联动逻辑原样复用现有 `onEditingEnded` 规则；先用单测锁定边界再改 UI |
| 去极光后界面显得"平" | 用三级表面 + 1px 描边 + 明确间距建立层级；避免用颜色补层级 |
| 视觉一次性大改引发回归 | 分 4 个 Phase，每个 Phase 可独立构建/回滚；Swift 代码按 Tab 分批提交 |

### 规格新增文案 Key（需补入 8 个 lproj）

| Key | zh-Hans | en（fallback） |
|---|---|---|
| `status_standby` | 待机 | Standby |
| `behavior` | 行为与通知 | Behavior |
| `scenarios` | 场景与配置 | Scenarios |
| `behavior_group_runtime` | 运行 | Runtime |
| `behavior_group_unlock` | 解锁 | Unlock |
| `behavior_group_lock` | 锁定 | Lock |
| `behavior_group_notify` | 通知 | Notifications |
| `scenarios_group_network` | 网络 | Network |
| `scenarios_group_profiles` | 配置档 | Profiles |
| `scenarios_group_backup` | 备份 | Backup |
| `scenarios_group_automation` | 自动化 | Automation |
| `rail_zone_lock` | 锁定区 | Lock zone |
| `rail_zone_unlock` | 解锁区 | Unlock zone |
| `rail_revert` | 还原 | Revert |
| `rail_hint_gap` | 建议缓冲带 ≥ 10 dB | Keep a buffer ≥ 10 dB |
| `signal_quality_label` | 信号质量 | Signal quality |
| `distance_scenario_label` | 距离场景 | Distance scenario |
| `onboarding_back` | 上一步 | Back |
| `onboarding_open_calibration` | 打开校准向导 | Open calibration |
| `sheet_close` | 关闭 | Close |
| `automation_script_title` | 事件脚本 | Event script |
| `automation_open_folder` | 打开脚本目录 | Open script folder |
| `automation_event_params` | 参数：$1 事件名 · $2 RSSI · $3 设备名 · $4 时间戳 | Args: $1 event · $2 RSSI · $3 device · $4 timestamp |

---

## 附录 A：与现有代码的差异清单（实施前必读）

| # | 事项 | 现状 | 规格 |
|---|---|---|---|
| 1 | RSSI 定义域 | 代码 `-95…-30` | 规格与原型统一 `-95…-30`（任务书写 -100，已更正） |
| 2 | 待机状态颜色 | Sidebar 灰 / Popover 橙 | 统一中性 + `status_standby` |
| 3 | `StatsView` | 独立 Sheet | 并入 Tab 4，删除 Sheet |
| 4 | `AboutView` / `AutomationView` | 无入口（死 UI） | About 从版本条、Automation 从 Tab 3 恢复 |
| 5 | Automation 四行 | 共读同一 `event` 文件 | 单脚本卡 + 4 个参数标签 |
| 6 | 全屏极光 / 彩虹描边 | `LiquidGlass.swift` | 全部删除，Token 化 |
| 7 | 硬编码字号 | 20 处 11pt 等 | 语义字号 + 等宽数字 |
| 8 | 品牌 | `Funlock` | `FUnlock` |
| 9 | 引导 | 无上一步/Esc/直达校准 | 三项补齐 |
| 10 | 权限窗口刷新 | 手动 | App 激活时自动刷新 |

## 附录 B：原型对齐契约（CSS 变量 ↔ SwiftUI token）

HTML 原型请使用同义变量名，便于评审逐项对照：

```css
--f-canvas; --f-sidebar; --f-card; --f-well;
--f-border; --f-border-strong;
--f-text-primary; --f-text-secondary; --f-text-tertiary;
--f-accent; --f-accent-hover; --f-on-accent;
--f-safe-text; --f-safe-text-alt; --f-safe-fill;
--f-amber-text; --f-amber-text-alt; --f-amber-fill;
--f-danger-text; --f-danger-text-alt; --f-danger-fill;
--f-radius-sm: 6px; --f-radius-md: 10px; --f-radius-lg: 12px; --f-radius-pill: 9999px;
--f-space-xxs: 4px; --f-space-xs: 8px; --f-space-sm: 12px;
--f-space-md: 16px; --f-space-lg: 20px; --f-space-xl: 24px;
```

原型必须遵守的三条硬约束：

1. **Range Rail 左端是 -95，不是 -100。**
2. **没有任何渐变、模糊、彩虹描边；彩色仅出现在第 3 章的状态与第 5 章的分区。**
3. **Sidebar / Popover / Overview 的状态徽标必须同图标、同颜色、同文案。**
