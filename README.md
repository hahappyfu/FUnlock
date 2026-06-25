# FUnlock

> 靠近自动解锁，离开自动锁屏 —— 用蓝牙信号守护你的 Mac

[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2013.0%2B-lightgrey.svg)]()
[![Version](https://img.shields.io/badge/version-2.2.0-green.svg)]()
[![Swift](https://img.shields.io/badge/Swift-5.7%2B-orange.svg)]()

FUnlock 是一个 macOS 菜单栏工具，通过监测 iPhone / Apple Watch 或任意蓝牙低功耗（BLE）设备的 RSSI 信号强度，自动锁定和解锁你的 Mac。无需安装 iPhone App，密码安全存储在 Keychain 中。

---

## ✨ 核心特性

- **靠近即解锁** — 手机靠近 Mac 自动输入密码解锁，无需手动操作
- **离开即锁定** — 手机离开范围后自动锁屏，保护隐私
- **无需 iPhone App** — 纯 macOS 端实现，利用 BLE 广播信号
- **SwiftUI 控制中心** — 现代化面板，实时显示信号强度和设备状态
- **多设备支持** — 可同时监测多个 BLE 设备
- **智能信号处理** — 非对称卡尔曼滤波 + 时间衰减丢包惩罚，靠近解锁干脆、离开锁定可靠
- **输入活动保护** — 检测键盘/触控板活动时暂缓锁定，打字不会误锁屏
- **手动锁屏保护** — 可选手动锁屏后禁止自动解锁，防止旁人靠近时屏幕自动打开
- **指纹解锁安全** — 指纹解锁时自动中断模拟密码输入，防止输入泄漏到前台应用
- **启动权限检查** — 启动时自动检查辅助功能和蓝牙权限，缺失时弹窗引导授权
- **安全存储** — 密码使用 Keychain 加密
- **多语言** — 支持中文、日文、德语、瑞典语、挪威语、丹麦语、土耳其语

---

## 📦 安装

### Homebrew Cask（推荐）

```bash
brew install funlock
```

### 手动安装

1. 从 [Releases](https://gitee.com/fuhahah/funlock/releases) 下载最新版本
2. 解压后将 `FUnlock.app` 移到 `/Applications` 文件夹
3. 首次启动时按提示授予蓝牙和辅助功能权限

---

## 🚀 快速开始

1. 启动 FUnlock，菜单栏出现蓝牙图标
2. 点击图标打开控制中心面板
3. 在「设备」区域选择你的 iPhone 或 Apple Watch
4. 调整锁定/解锁的 RSSI 阈值（默认 -80 / -60 dBm）
5. 输入 Mac 登录密码（安全存储在 Keychain）

完成！离开 Mac 时自动锁屏，回来时自动解锁。

---

## 🧭 控制中心

点击菜单栏图标打开 SwiftUI 控制中心：

| 区域 | 功能 |
|------|------|
| **顶部** | 设备名称、锁定状态（颜色指示）、当前 RSSI |
| **信号仪表** | 圆形进度条，实时显示信号强度 |
| **快捷开关** | 启用/禁用、靠近唤醒、被动模式等 8 个开关 |
| **底部** | 立即锁定、退出 |

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
| **开机自启动** | 开机自动启动 FUnlock |

---

## 🛡️ 安全设计

- **Keychain 加密**：密码使用 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` 存储，设备锁定时不可读
- **竞态保护**：手动解锁后 3 秒内禁止自动解锁，防止密码注入到已解锁屏幕
- **系统锁屏监听**：监听 `com.apple.screenIsLocked` 通知，通过系统菜单锁屏后禁止自动解锁
- **SQL 参数化查询**：蓝牙设备数据库查询使用参数绑定，防止注入

---

## 🔧 脚本事件

锁定/解锁时自动执行脚本：

```
~/Library/Application Scripts/jp.sone.BLEUnlock/event
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
│   ├── FUnManager.swift          # 核心状态机（@MainActor）
│   ├── FUn.swift                 # CoreBluetooth 驱动 + 信号滤波 + 输入保护
│   ├── AppDelegate.swift         # 应用入口 + 权限检查 + 输入活动监听
│   ├── MenuDashboardView.swift   # SwiftUI 控制中心面板
│   ├── CalibrationWizardView.swift # 阈值校准向导
│   ├── LEDeviceInfo.swift        # macOS 蓝牙设备数据库查询
│   ├── appleDeviceNames.swift    # Apple 设备名称映射表
│   ├── checkUpdate.swift         # 自动更新检查
│   ├── AboutBox.swift            # 关于窗口
│   ├── lowlevel.h / .c           # 系统级 API（锁屏/唤醒显示器）
│   └── MediaRemote.h             # 私有框架（Now Playing 控制）
├── Launcher/                      # 开机自启动 Helper
├── docs/                          # 开发文档与设计 spec
└── BUGS.md                        # 问题登记
```

---

## 🏗️ 架构概览

```
┌─────────────────────────────────────────────┐
│            MenuDashboardView (SwiftUI)       │
│         控制中心 @ObservedObject              │
└──────────────────┬──────────────────────────┘
                   │ @Published state/rssi/connected
┌──────────────────▼──────────────────────────┐
│          FUnManager (@MainActor)             │
│    状态机：ScreenState + LockIntent           │
│    决策：lockOrSaveScreen / fakeKeyStrokes    │
│    输入活动否决 + 心跳检查                     │
└──────────────────┬──────────────────────────┘
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

---

## 🛠️ 开发

### 构建

```bash
xcodebuild build -project FUnlock.xcodeproj -scheme FUnlock -configuration Release
```

### 要求

- Xcode 15+
- macOS 13.0+ 部署目标
- Swift 5.7+

### 关键技术

- **状态机**：`ScreenState` + `LockIntent` 枚举管理锁定/解锁/唤醒/媒体状态
- **非对称卡尔曼滤波**：靠近时快速响应（Q 自适应放大 + 钳位），离开时强阻尼（原始小 Q）
- **时间衰减丢包惩罚**：`effectiveRSSI = kalmanEstimate - 0.5×elapsed`，丢包自动降级
- **输入活动否决**：IOKit HID 监听键盘/触控板，有活动时否决锁定决策
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
