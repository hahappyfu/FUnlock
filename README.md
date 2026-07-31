# FUnlock

> 靠近自动解锁，离开自动锁屏 —— 用蓝牙信号守护你的 Mac

[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2013.0%2B-lightgrey.svg)]()
[![Version](https://img.shields.io/badge/version-2.6.0-green.svg)]()
[![Swift](https://img.shields.io/badge/Swift-5.7%2B-orange.svg)]()

FUnlock 是一个 macOS 菜单栏工具，通过监测 iPhone / Apple Watch 或任意蓝牙低功耗（BLE）设备的 RSSI 信号强度，自动锁定和解锁你的 Mac。无需安装 iPhone App，密码安全存储在 Keychain 中。

---

## ✨ 核心特性

- **靠近即解锁** — 手机靠近 Mac 自动输入密码解锁，无需手动操作
- **离开即锁定** — 手机离开范围后自动锁屏，保护隐私
- **无需 iPhone App** — 纯 macOS 端实现，利用 BLE 广播信号
- **侧边栏导航控制中心** — 毛玻璃风格（NSVisualEffectView），7 个 Tab 分类管理，SF Symbols 矢量图标
- **多设备支持** — 可同时监测多个 BLE 设备，自动扫描 + RSSI 排序 + 增量更新
- **智能信号处理** — 非对称卡尔曼滤波 + 时间衰减丢包惩罚，靠近解锁干脆、离开锁定可靠
- **Wi-Fi 联动** — 连接指定 Wi-Fi 时暂停锁屏（如公司/家庭网络）
- **多配置文件** — 支持创建多个配置，不同场景一键切换
- **输入活动保护** — 检测键盘/触控板活动时暂缓锁定，打字不会误锁屏
- **手动锁屏保护** — 可选手动锁屏后禁止自动解锁，防止旁人靠近时屏幕自动打开
- **指纹解锁安全** — 指纹解锁时自动中断模拟密码输入，防止输入泄漏到前台应用
- **自动更新** — 每天检测 GitHub Release，有新版本自动下载安装并重启
- **启动权限检查** — 启动时自动检查辅助功能和蓝牙权限，缺失时弹窗引导授权
- **安全存储** — 密码使用 Keychain 加密
- **多语言** — 支持中文、日文、德语、瑞典语、挪威语、丹麦语、土耳其语

---

## 🔒 V3 安全加固（v2.6.0）

- **Actor 状态机** — 基于 Swift Actor 的 `FUnlockStateMachine`，线程安全的状态管理，消除竞态条件
- **密码注入前奏** — 注入密码前先发送 Shift 键 + 300ms 延迟，确保前台应用获得输入焦点
- **双保险验证** — 密码注入后通过 CGSession 兜底验证，确保解锁确实成功
- **预备唤醒** — 信号平滑 + 阶梯唤醒策略，避免在信号边缘反复唤醒/休眠
- **连续失败降级** — 连续密码注入失败时自动降级并通知用户，防止暴力尝试
- **Keychain 安全收紧** — 冷启动时捕获 Keychain 错误码，密码读取失败时安全降级
- **用户主动干预处理** — 检测用户手动解锁/锁屏行为，自动调整 FUnlock 策略
- **乐观解锁策略** — 信号达标后立即触发解锁，减少用户感知延迟

---

## 📦 安装

### Homebrew Cask（推荐）

```bash
brew install funlock
```

### 手动安装（DMG）

1. 从 [Releases](https://github.com/hahappyfu/FUnlock/releases) 下载最新 `FUnlock.dmg`
2. 打开 DMG 文件，将 `FUnlock.app` 拖入 `/Applications` 文件夹
3. 首次启动时按提示授予蓝牙和辅助功能权限

---

## 🚀 快速开始

1. 启动 FUnlock，菜单栏出现蓝牙图标
2. 点击图标打开控制中心面板
3. 切换到「设备」tab，选择你的 iPhone 或 Apple Watch
4. 调整锁定/解锁的 RSSI 阈值（默认 -80 / -60 dBm）
5. 输入 Mac 登录密码（安全存储在 Keychain）

完成！离开 Mac 时自动锁屏，回来时自动解锁。

---

## 🧭 控制中心

点击菜单栏图标打开侧边栏导航控制中心（毛玻璃风格）：

| Tab | 功能 |
|-----|------|
| **总览** | 信号仪表盘、RSSI、阈值调节、校准向导、统计/自动化/关于入口 |
| **设备** | 已绑定设备、自动 BLE 扫描、设备列表（RSSI 排序） |
| **基础** | 启用/禁用、开机自启 |
| **解锁** | 靠近唤醒、唤醒不解锁、屏保模式 |
| **锁定** | 暂停媒体、关闭显示器、延迟锁定、手动锁后不解锁 |
| **网络** | Wi-Fi 暂停（指定 SSID）、被动模式 |
| **配置** | 多配置文件管理 |

---

## ⚙️ 选项说明

| 选项 | 说明 |
|------|------|
| **启用** | 总开关，暂停/恢复 FUnlock |
| **靠近时唤醒** | 设备靠近时点亮屏幕（显示锁屏界面） |
| **唤醒但不解锁** | 只唤醒不解锁（配合 Apple Watch 解锁） |
| **锁定时暂停播放** | 锁定时暂停音乐/视频播放 |
| **使用屏幕保护程序** | 用屏保代替直接锁屏 |
| **锁定时关闭屏幕** | 锁定时关闭显示器 |
| **输入活动时暂缓锁定** | 检测到键盘/触控板活动时暂缓锁定，防止误锁 |
| **手动锁屏不自动解锁** | 手动锁屏后禁止自动解锁，保护隐私 |
| **被动模式** | 被动扫描模式，不主动连接设备 |
| **Wi-Fi 暂停** | 连接指定 SSID 时暂停锁屏（适用于公司/家庭网络） |
| **开机自启动** | 开机自动启动 FUnlock |

---

## 🛡️ 安全设计

- **Keychain 加密**：密码使用 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` 存储，设备锁定时不可读
- **竞态保护**：手动解锁后 3 秒内禁止自动解锁，防止密码注入到已解锁屏幕
- **系统锁屏监听**：监听 `com.apple.screenIsLocked` 通知，通过系统菜单锁屏后禁止自动解锁
- **SQL 参数化查询**：蓝牙设备数据库查询使用参数绑定，防止注入
- **codesign 校验**：自动更新安装时校验应用签名，防止恶意替换

---

## 🔧 脚本事件

锁定/解锁时自动执行脚本：

```
~/Library/Application Scripts/FUnlock/event
```

参数格式：`event rssi deviceName timestamp`

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
├── FUnlock/
│   ├── AppDelegate.swift              # 应用入口 + 权限检查 + 通知处理
│   ├── FUnManager.swift               # 核心状态机（@MainActor）
│   ├── FUn.swift                      # CoreBluetooth 驱动 + 信号滤波
│   ├── MenuDashboardView.swift        # 侧边栏导航控制中心
│   ├── SystemInteractionService.swift # 锁屏/唤醒/密码输入（从 FUnManager 解耦）
│   ├── SecurityService.swift          # Keychain 读写 + 密码验证（从 FUnManager 解耦）
│   ├── ScriptRunner.swift             # 脚本事件执行（从 FUnManager 解耦）
│   ├── TelemetryLogger.swift          # 结构化日志 + 关键路径埋点
│   ├── FUnlockStateMachine.swift      # Actor 状态机（v2.6.0 安全加固）
│   ├── InputActivityMonitor           # IOKit HID 键盘/触控板活动检测
│   ├── CalibrationWizardView.swift    # 阈值校准向导
│   ├── OnboardingView.swift           # 首次启动引导页
│   ├── StatsView.swift                # 统计数据视图
│   ├── AutomationView.swift           # 自动化设置视图
│   ├── ProfileManager.swift           # 多配置文件管理
│   ├── ToastView.swift                # 轻提示组件
│   ├── WiFiMonitor.swift              # Wi-Fi SSID 监听（暂停锁屏）
│   ├── Log.swift                      # 日志记录
│   ├── SignalDataStore.swift          # 信号数据存储
│   ├── RingBuffer.swift               # 环形缓冲区
│   ├── UpdateDownloader.swift         # 自动更新下载器
│   ├── UpdateInstaller.swift          # 自动更新安装器
│   ├── checkUpdate.swift              # 自动更新检查
│   ├── FUnlockUtils.swift             # 通用工具函数
│   ├── LEDeviceInfo.swift             # macOS 蓝牙设备数据库查询
│   ├── appleDeviceNames.swift         # Apple 设备名称映射表
│   ├── AboutView.swift                # 关于窗口
│   ├── lowlevel.h / .c                # 系统级 API（锁屏/唤醒显示器）
│   └── MediaRemote.h                  # 私有框架（Now Playing 控制）
├── FUnlockTests/                      # 单元测试与集成测试（v2.6.0）
├── Launcher/                          # 开机自启动 Helper
├── docs/                              # 开发文档与设计 spec
└── BUGS.md                            # 问题登记
```

---

## 🏗️ 架构概览

```
┌─────────────────────────────────────────────┐
│       MenuDashboardView (侧边栏导航)        │
│         控制中心 @ObservedObject              │
└──────────────────┬──────────────────────────┘
                   │ @Published state/rssi/connected
┌──────────────────▼──────────────────────────┐
│          FUnManager (@MainActor)             │
│    状态机：ScreenState + LockIntent           │
│    决策：lockOrSaveScreen / fakeKeyStrokes    │
│    输入活动否决 + 心跳检查                     │
└──────────────────┬──────────────────────────┘
                   │ 依赖注入（解耦后）
    ┌──────────────┼──────────────┐
    ▼              ▼              ▼
┌──────────┐ ┌──────────┐ ┌──────────┐
│SystemInt.│ │Security  │ │ Script   │
│Service   │ │Service   │ │ Runner   │
│锁屏/唤醒 │ │Keychain  │ │ 脚本事件 │
└──────────┘ └──────────┘ └──────────┘

                   │ FUnDelegate
┌──────────────────▼──────────────────────────┐
│              FUn (CoreBluetooth)             │
│    扫描 / 连接 / RSSI 读取                    │
│    非对称 Kalman + 时间衰减 + 独立显示滤波     │
│    专用串行队列 bleQueue                       │
└──────────────────┬──────────────────────────┘
                   │ IOKit HID
┌──────────────────▼──────────────────────────┐
│        InputActivityMonitor                  │
│    键盘 / 触控板活动检测                       │
└─────────────────────────────────────────────┘
```

**v2.4.0 架构改进**：
- 从 FUnManager 拆分出 SystemInteractionService（锁屏/唤醒/密码）、SecurityService（Keychain）、ScriptRunner（脚本事件）
- 新增 TelemetryLogger 结构化日志系统，关键路径埋点
- 消除不必要的心跳定时器，降低后台 CPU 占用

**v2.6.0 安全加固**：
- 新增 FUnlockStateMachine（Swift Actor），线程安全的状态管理，替代原有 @MainActor 枚举状态
- 密码注入流程增加「注入前奏 + 双保险验证 + 乐观解锁」三重保障
- Keychain 读取增加冷启动错误码捕获与安全降级
- 用户手动干预自动识别并调整策略，避免与 FUnlock 冲突

---

## 🛠️ 开发

### 构建

```bash
xcodebuild build -project FUnlock.xcodeproj -scheme FUnlock -configuration Release
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

- **状态机**：`ScreenState` + `LockIntent` 枚举管理锁定/解锁/唤醒/媒体状态
- **Actor 状态机**：`FUnlockStateMachine`（Swift Actor），线程安全的状态管理，消除竞态条件
- **非对称卡尔曼滤波**：靠近时快速响应（Q 自适应放大 + 钳位），离开时强阻尼（原始小 Q）
- **时间衰减丢包惩罚**：`effectiveRSSI = kalmanEstimate - 0.5×elapsed`，丢包自动降级
- **输入活动否决**：IOKit HID 监听键盘/触控板，有活动时否决锁定决策
- **密码注入安全**：注入前奏（Shift + 300ms）+ 双保险验证（CGSession 兜底）+ 乐观解锁
- **预备唤醒**：信号平滑 + 阶梯唤醒策略，避免边缘信号反复唤醒/休眠
- **连续失败降级**：密码注入连续失败时自动降级并通知用户
- **心跳检查**：每 2 秒主动轮询，防丢包 100% 时状态机死锁
- **UI 解耦**：决策层用非对称 Kalman，UI 显示用独立对称 EMA（α=0.1）
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
