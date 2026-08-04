# FUnlock

> 靠近自动解锁，离开自动锁屏 —— 用蓝牙信号守护你的 Mac，全程无需掏出手机

[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2013.0%2B-lightgrey.svg)]()
[![Version](https://img.shields.io/badge/version-2.7.0-green.svg)]()
[![Swift](https://img.shields.io/badge/Swift-5.7%2B-orange.svg)]()

FUnlock 是一个 macOS 菜单栏工具，通过监测 iPhone / Apple Watch 或任意蓝牙低功耗（BLE）设备的 RSSI 信号强度，自动锁定和解锁你的 Mac。无需安装 iPhone App，密码安全存储在 Keychain 中。

**适合谁用**：不想每次离开/回来都手动锁屏解锁的 Mac 用户；带 Apple Watch / iPhone 通勤、希望隐私与便捷兼得的用户。

---

## ✨ 核心特性

- **靠近即解锁** — 手机靠近 Mac 自动输入密码解锁，无需手动操作
- **离开即锁定** — 手机离开范围后自动锁屏，保护隐私
- **动态信号判定** — 信号"渐弱才锁定、渐强才解锁"的平滑过程，避免信号抖动反复锁屏；忘带设备（完全无信号）时不会反复触发锁屏
- **无需 iPhone App** — 纯 macOS 端实现，利用 BLE 广播信号
- **多设备支持** — 可同时监测多个 BLE 设备，自动扫描 + RSSI 排序 + 增量更新
- **智能信号处理** — 非对称卡尔曼滤波 + 时间衰减丢包惩罚，靠近解锁干脆、离开锁定可靠
- **决策时间线（诊断页）** — 每次"为什么没解锁 / 为什么锁屏"都记录为结构化事件，按日期分组的可视化时间轴，附操作建议按钮，可排查问题
- **Wi-Fi 联动** — 连接指定 Wi-Fi 时暂停锁屏（如公司/家庭网络）
- **多配置文件** — 支持创建多个配置，不同场景一键切换
- **输入活动保护** — 检测键盘/触控板活动时暂缓锁定，打字不会误锁屏
- **手动锁屏保护** — 手动锁屏后不会自动解锁，必须手动解锁才能重置（内置强制行为）
- **指纹解锁安全** — 指纹解锁时自动中断模拟密码输入，防止输入泄漏到前台应用
- **自动更新** — 每天检测 GitHub Release，有新版本自动下载安装并重启
- **启动权限检查** — 启动时自动检查辅助功能和蓝牙权限，缺失时弹窗引导授权
- **安全存储** — 密码使用 Keychain 加密
- **多语言** — 支持中文、日文、德语、瑞典语、挪威语、丹麦语、土耳其语

---

## 📦 安装

### 手动安装（DMG）

1. 从 [GitHub Releases](https://github.com/hahappyfu/FUnlock/releases) 下载最新 `FUnlock.dmg`
2. 打开 DMG 文件，将 `FUnlock.app` 拖入 `/Applications` 文件夹
3. 首次启动时按提示授予蓝牙和辅助功能权限

### 从源码构建

```bash
git clone https://github.com/hahappyfu/FUnlock.git
cd FUnlock
xcodebuild build -project FUnlock.xcodeproj -scheme FUnlock -configuration Release
```

---

## 🚀 快速开始

1. 启动 FUnlock，菜单栏出现蓝牙图标
2. 点击图标打开侧边栏控制中心，进入「设备」Tab
3. 选择你的 iPhone 或 Apple Watch（或任意 BLE 设备）
4. 输入 Mac 登录密码（安全存储在 Keychain）
5. 也可以直接使用「总览」页的**自动校准向导**，跟着走两步即可生成合适阈值

完成！离开 Mac 时自动锁屏，回来时自动解锁。

---

## 🧭 控制中心

点击菜单栏图标打开侧边栏导航控制中心（毛玻璃风格），共 8 个 Tab：

| Tab | 功能 |
|-----|------|
| **总览** | 信号仪表盘、RSSI、阈值调节、校准向导、立即锁定、统计/自动化/关于入口 |
| **设备** | 已绑定设备、自动 BLE 扫描、设备列表（RSSI 排序） |
| **基础** | 启用/禁用、开机自启 |
| **解锁** | 靠近唤醒、唤醒不解锁、屏保模式 |
| **锁定** | 暂停媒体、关闭显示器、输入活动暂缓锁定 |
| **网络** | Wi-Fi 暂停（指定 SSID）、被动模式 |
| **配置** | 多配置文件管理 |
| **诊断** | 解锁/锁屏决策时间线（按日期分组），含原因、信号与操作建议 |

---

## ⚙️ 选项说明

| 选项 | 说明 |
|------|------|
| **启用** | 总开关，暂停/恢复 FUnlock |
| **开机自启动** | 开机自动启动 FUnlock |
| **靠近时唤醒** | 设备靠近时点亮屏幕（显示锁屏界面） |
| **唤醒但不解锁** | 只唤醒不解锁（配合 Apple Watch 解锁） |
| **使用屏幕保护程序** | 用屏保代替直接锁屏 |
| **锁定时暂停播放** | 锁定时暂停音乐/视频播放 |
| **锁定时关闭屏幕** | 锁定时关闭显示器 |
| **输入活动时暂缓锁定** | 检测到键盘/触控板活动时暂缓锁定，防止误锁 |
| **被动模式** | 被动扫描模式，不主动连接设备 |
| **Wi-Fi 暂停** | 连接指定 SSID 时暂停锁屏（适用于公司/家庭网络） |
| **手动锁屏保护** | 内置行为：手动锁屏后不自动解锁，需手动解锁重置 |

---

## 🛡️ 安全设计

- **Keychain 加密**：密码使用 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` 存储，设备锁定时不可读
- **竞态保护**：手动解锁后短时间内禁止自动解锁，防止密码注入到已解锁屏幕
- **系统锁屏监听**：监听 `com.apple.screenIsLocked` 通知，通过系统菜单锁屏后禁止自动解锁
- **SQL 参数化查询**：蓝牙设备数据库查询使用参数绑定，防止注入
- **codesign 校验**：自动更新安装时校验应用签名，防止恶意替换
- **Actor 状态机**：基于 Swift Actor 的状态管理，线程安全，消除竞态条件

---

## 🔧 脚本事件

锁定/解锁时自动执行脚本，并写入事件日志：

- 事件日志：`~/Library/Application Support/FUnlock/events.log`
- 用户脚本：`~/Library/Application Scripts/FUnlock/event`

脚本参数：`event rssi deviceName timestamp`

| 事件 | 说明 |
|------|------|
| `away` | 设备远离，自动锁定 |
| `lost` | 信号丢失，自动锁定 |
| `unlocked` | FUnlock 自动解锁 |
| `intruded` | 用户手动解锁（非 FUnlock 触发） |

示例脚本：
```bash
#!/bin/bash
case $1 in
    away)   curl -X POST ... "Mac 已锁定（设备远离）" ;;
    lost)   curl -X POST ... "Mac 已锁定（信号丢失）" ;;
    intruded) curl -X POST ... "Mac 被手动解锁！" ;;
esac
```

---

## 📁 项目结构

```
FUnlock/
├── FUnlock/                          # 主应用
│   ├── AppDelegate.swift             # 应用入口 + 权限检查 + 通知处理 + 输入活动监听
│   ├── FUnManager.swift              # 核心管理器（@MainActor）：锁屏/解锁决策、手动锁保护
│   ├── FUn.swift                     # CoreBluetooth 驱动 + 信号滤波 + 心跳检查
│   ├── SignalPipeline.swift          # 信号处理管线（非对称 Kalman + 丢包惩罚）
│   ├── FUnlockStateMachine.swift     # Actor 状态机（线程安全）
│   ├── MainWindowView.swift          # 主窗口（NavigationSplitView 侧边栏导航）
│   ├── SidebarView.swift             # 侧边栏导航（毛玻璃）
│   ├── OverviewView.swift            # 总览：信号仪表盘 + 阈值调节 + 校准入口
│   ├── DiagnosticsView.swift         # 诊断页：决策时间线（时间轴布局）
│   ├── DecisionLogger.swift          # 决策记录器（结构化事件 + JSONL 持久化）
│   ├── StatsView.swift               # 统计数据视图
│   ├── CalibrationWizardView.swift   # 阈值校准向导
│   ├── OnboardingView.swift          # 首次启动引导页
│   ├── AutomationView.swift          # 自动化设置视图
│   ├── ProfileManager.swift          # 多配置文件管理
│   ├── SystemInteractionService.swift# 锁屏/唤醒/密码输入（与 FUnManager 解耦）
│   ├── SecurityService.swift         # Keychain 读写 + 密码验证
│   ├── ScriptRunner.swift            # 脚本事件执行 + 事件日志
│   ├── TelemetryLogger.swift         # 结构化日志 + 关键路径埋点
│   ├── DebugLog.swift                # 调试日志组件
│   ├── SignalDataStore.swift         # 信号数据存储
│   ├── RingBuffer.swift              # 环形缓冲区
│   ├── UpdateDownloader.swift        # 自动更新下载器
│   ├── UpdateInstaller.swift         # 自动更新安装器
│   ├── ToastView.swift               # 轻提示组件
│   └── ...                           # 各设置视图 + 工具类
├── FUnlockTests/                     # 单元测试与集成测试（308 用例）
├── Launcher/                         # 开机自启动 Helper
├── docs/                             # 开发文档与设计 spec
└── BUGS.md                           # 问题登记
```

---

## 🏗️ 架构概览

```
┌─────────────────────────────────────────────┐
│       MainWindowView (侧边栏导航，8 Tab)      │
│          总览/设备/基础/解锁/锁定/网络/配置/诊断 │
└──────────────────┬──────────────────────────┘
                   │ @Published state/rssi/events
┌──────────────────▼──────────────────────────┐
│          FUnManager (@MainActor)             │
│    状态机：ScreenState + LockIntent           │
│    决策：锁屏判定 / 手动锁保护 / 输入活动否决    │
└──────────────────┬──────────────────────────┘
                   │ 依赖注入（解耦后）
    ┌──────────────┼──────────────┐
    ▼              ▼              ▼
┌──────────┐ ┌──────────┐ ┌──────────┐
│SystemInt.│ │Security  │ │ Script   │
│Service   │ │Service   │ │ Runner   │
│锁屏/唤醒 │ │Keychain  │ │ 脚本事件 │
└──────────┘ └──────────┘ └──────────┘

                   │ FUnDelegate + 决策事件
┌──────────────────▼──────────────────────────┐
│              FUn (CoreBluetooth)             │
│    扫描 / 连接 / RSSI 读取                    │
│    SignalPipeline：非对称 Kalman + 丢包惩罚    │
│    输入活动否决（IOKit HID）                   │
└──────────────────┬──────────────────────────┘
                   ▼
┌─────────────────────────────────────────────┐
│        DecisionLogger → 诊断页时间轴          │
│    每个决策记录 原因/信号/设备/结果 + 操作建议  │
└─────────────────────────────────────────────┘
```

**架构要点**：
- 从 FUnManager 拆分为 SystemInteractionService（锁屏/唤醒/密码）、SecurityService（Keychain）、ScriptRunner（脚本事件）
- FUnlockStateMachine 基于 Swift Actor，线程安全的状态管理
- 决策层用非对称 Kalman，UI 显示用独立对称 EMA（α=0.1）
- 心跳检查每 2 秒主动轮询，防丢包 100% 时状态机死锁
- 诊断页把"为什么锁屏/没解锁"沉淀为结构化数据，便于调参与排查

---

## 🛠️ 开发

### 构建

```bash
xcodebuild build -project FUnlock.xcodeproj -scheme FUnlock -configuration Release
```

### 测试

```bash
xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' test
```

### 安装（DMG 覆盖安装）

```bash
pkill FUnlock
rm -rf /Applications/FUnlock.app
cp -R build/Build/Products/Release/FUnlock.app /Applications/
open /Applications/FUnlock.app
```

### 要求

- Xcode 15+
- macOS 13.0+ 部署目标
- Swift 5.7+

### 关键技术

- **Actor 状态机**：`FUnlockStateMachine`（Swift Actor），线程安全的状态管理
- **非对称卡尔曼滤波**：靠近时快速响应（Q 自适应放大 + 钳位），离开时强阻尼（原始小 Q）
- **时间衰减丢包惩罚**：`effectiveRSSI = kalmanEstimate - 0.5×elapsed`，丢包自动降级
- **动态信号判定**：信号渐弱才锁定、渐强才解锁，避免边缘信号反复触发
- **输入活动否决**：IOKit HID 监听键盘/触控板，有活动时否决锁定决策
- **密码注入安全**：注入前奏（Shift + 300ms）+ 双保险验证（CGSession 兜底）+ 乐观解锁
- **预备唤醒**：信号平滑 + 阶梯唤醒策略，避免边缘信号反复唤醒/休眠
- **连续失败降级**：密码注入连续失败时自动降级并通知用户
- **手动锁保护**：手动锁屏进入 24h 保护窗口，期间禁止自动解锁，直到用户手动解锁
- **心跳检查**：每 2 秒主动轮询，防丢包 100% 时状态机死锁
- **async/await**：唤醒重试、解锁延迟均使用 `Task` 替代 `Timer`

---

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

1. Fork 本仓库
2. 创建功能分支：`git checkout -b feature/your-feature`
3. 提交更改：`git commit -m "feat: add your feature"`
4. 推送分支：`git push origin feature/your-feature`
5. 创建 Pull Request

---

## 📝 License

MIT License

Copyright © 2019-2026 Takeshi Sone. 二次开发维护 by fuhahah.
