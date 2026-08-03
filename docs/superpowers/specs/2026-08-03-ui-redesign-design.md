# FUnlock UI 重设计（产品化）设计文档

日期：2026-08-03
状态：已确认
目标版本：FUnlock v2.7.x（当前分支 feat/diagnostics-tab）

## 背景与目标

当前 FUnlock 界面为 440×520 固定窗口 + 自绘侧边栏 8 Tab 布局，被用户判定为"不够产品化"。本轮重做将全部 SwiftUI 界面统一为 macOS 原生（Apple 系）设计语言，替换全部自绘布局组件为系统原生组件，并重构信息架构与交互。

设计方向（用户确认）：
- 布局骨架：侧边栏导航（系统设置风）
- 信息架构：按使用频率分组
- 总览页：保留，作为主入口
- 配色：跟随系统明暗 + 默认系统蓝
- 信号呈现：环形盘保留 + 可视化阈值条
- 窗口形态：自由缩放（类系统设置）
- 技术路线：NavigationSplitView
- 最低系统版本：macOS 12.0 → **macOS 13.0**

## 技术路线决策

使用 `NavigationSplitView`（macOS 13+）替换当前自绘 `HStack` 侧边栏布局。部署目标从 12.0 提升到 13.0，放弃 macOS 12 支持（2021 年发布，市占已很低，Apple 新 API 普遍要求 13+）。

## 架构变更

### 窗口（AppDelegate）

- `setupSettingsWindow()`：以 `NavigationSplitView` 替换 `MenuDashboardView` 的固定 440×520 布局
- 窗口 `contentMinSize` 设为 560×420，侧边栏固定宽约 200px，内容区随窗口自由扩展
- 去掉全窗口 `.regularMaterial` 背景，改用系统标准控件背景
- 窗口 `styleMask` 保持 `[.titled, .closable, .resizable]`，新增全尺寸缩放

### 侧边栏（SidebarView.swift，新文件）

`List` + `Section` 按使用频率分三组：

| 分组 | 条目 |
|------|------|
| 常用 | 总览（信号仪表盘）、锁定、解锁 |
| 设置 | 基础、网络、配置 |
| 诊断 | 诊断 |

设备管理（绑定/解绑/扫描）并入总览页，不设独立条目。总览页「设备状态」卡内嵌「更换/解绑设备」入口与扫描列表。

- 每项用 SF Symbols 图标，选中态由系统提供
- 侧边栏顶部放「设备状态」小行：当前绑定设备名 + 状态点，替代现在固定在窗口顶部的状态栏
- 移除当前 `MenuDashboardView` 中的 `deviceStatusBar`、`sidebarView`、`sidebarTabButton`、`footerSection`

### 底部工具条

「立即锁定」「退出」移到窗口底部 toolbar 区（toolbar placement），不再占用主布局空间。

### 主骨架（MainWindowView.swift，新文件）

`NavigationSplitView` 骨架，持有 `FUnManager`/`FUn`，管理 tab 切换、sheet 呈现（校准/引导/自动化/关于/统计）、toast 展示。

## 页面设计

### 总览页（OverviewView.swift，新文件）— 主入口

Form 分组卡片结构：

**Group 1「设备状态」**
- 环形信号盘居中（保留现有 `Circle().trim()` 环形设计，由 `manager.rssi` 驱动），环中心显示 dBm 数字
- 环下方一行场景文字（如「信号良好」）+ 状态徽章（解锁中/已锁定）
- 环直径约 110px，放在卡片顶部居中，留白充足

**Group 2「距离阈值」**
- 可视化阈值条：一个横向条带，实时 RSSI 标记点 + 锁定（橙）/解锁（绿）两个阈值游标，直观显示当前信号落在哪个区间
- 保留两个滑块（锁定/解锁）用系统原生 `Slider`，拖动实时预览不即时写盘
- 下方保留「应用阈值」按钮，点击后写盘
- 校准向导入口保留

**Group 3「快捷操作」**
- 「立即锁定」「校准向导」两个操作按钮
- 未绑定设备时显示「选择设备」引导卡片（含扫描入口），替代现有空状态文字

**设备管理（并入总览页）**
- 已绑定设备状态卡内嵌「更换设备」「解绑」入口，点击展开扫描列表（复用现有 startScan/stopScan/DeviceRow 逻辑）
- 未绑定状态显示「选择设备」引导卡（扫描入口）

### 其余设置页（功能保留，仅换 Form 样式）

| 页 | 分组内容 |
|----|---------|
| 基础 | 启用、开机自启 |
| 解锁 | 接近唤醒、唤醒不解锁、用屏保 |
| 锁定 | 锁定时暂停音乐、关闭显示器、输入延后锁、手动锁不自动解 |
| 网络 | Wi-Fi 暂停（含 SSID 输入行）、被动模式 |
| 配置 | 配置方案 Picker + 新建/删除 |

### 诊断页

现有 DiagnosticsView 内容保留，仅统一间距与 Form 分组样式。

### 附属界面（4 个 sheet）

- AboutView / StatsView / AutomationView：改为与主窗口一致的 Form 分组风格
- CalibrationWizardView：重排为步骤化引导（靠近/远离两步 + 结果确认）
- OnboardingView：保留引导结构，样式统一

## 统一视觉语言

- 全部使用系统原生字体（`.body`/`.headline` 等），移除散落的手写 `font(.system(size: 11/12/13))`
- 颜色只保留语义色：`Color.accentColor`（跟随系统）、`.secondary`、状态绿/橙/红
- 所有自绘卡片背景/圆角/Divider 替换为 Form 原生分组
- 毛玻璃 `.regularMaterial` 仅用于必要层级
- 可点击项有 hover/选中反馈、焦点态可见、深色模式全部正常

## 文件拆分（解决巨型文件问题）

当前 `MenuDashboardView.swift` 1043 行，拆为：

- `MainWindowView.swift` — NavigationSplitView 骨架、tab 切换、sheet 管理、toast
- `SidebarView.swift` — 分组侧边栏
- `OverviewView.swift` — 总览页（信号盘 + 阈值条）
- 各设置页从 MenuDashboardView 拆出为独立视图文件（BasicSettingsView / UnlockSettingsView / LockSettingsView / NetworkSettingsView / ConfigSettingsView）
- 删除 `SettingToggleRow`、`pageTitle`、`sidebarDivider`、`otherEntriesSection` 等自绘组件，替换为 Form 原生结构

## 错误处理与边界

- 阈值滑块与实时 RSSI 无信号（nil）时，阈值条显示空态（仅游标，无标记点），场景文字显示"无信号"
- 未绑定设备时，总览页整体降级为「选择设备」引导卡，不渲染信号盘
- sheet 关闭路径与现有一致；toast 逻辑保留
- 深色/浅色模式均需验证

## 测试

- 现有测试（xcodebuild test）保持通过，UI 改动不涉及业务逻辑
- 手动验证项：
  - 窗口自由缩放（含最小尺寸）
  - 三组侧边栏选中态与导航
  - 总览页信号盘/阈值条在有无信号、已绑定/未绑定下正常
  - 深色模式全页面正常
  - 4 个 sheet 样式统一
  - 阈值应用/校准/统计/自动化功能路径无回归

## 范围外（本轮不做）

- 菜单栏图标本身、通知样式、全局快捷键交互（后续独立处理）
- 业务逻辑重构（状态机、BLE 层）
- macOS 12 兼容
