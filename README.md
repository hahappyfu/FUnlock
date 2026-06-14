# BLEUnlock

> 靠近自动解锁，离开自动锁屏 —— 用蓝牙信号守护你的 Mac

[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2012.0%2B-lightgrey.svg)]()
[![Version](https://img.shields.io/badge/version-2.0.0-green.svg)]()
[![Swift](https://img.shields.io/badge/Swift-5.7%2B-orange.svg)]()

BLEUnlock 是一个 macOS 菜单栏工具，通过监测 iPhone / Apple Watch 或任意蓝牙低功耗（BLE）设备的 RSSI 信号强度，自动锁定和解锁你的 Mac。无需安装 iPhone App，密码安全存储在 Keychain 中。

---

## ✨ 核心特性

- **靠近即解锁** — 手机靠近 Mac 自动输入密码解锁，无需手动操作
- **离开即锁定** — 手机离开范围后自动锁屏，保护隐私
- **无需 iPhone App** — 纯 macOS 端实现，利用 BLE 广播信号
- **SwiftUI 控制中心** — 现代化 NSPopover 面板，实时显示信号强度和设备状态
- **多设备支持** — 可同时监测多个 BLE 设备（任一在场即解锁）
- **智能信号处理** — 卡尔曼滤波 + 自适应轮询，平衡精度与功耗
- **事件日志** — 自动记录锁定/解锁事件，支持自定义脚本触发
- **安全存储** — 密码使用 Keychain 加密，设置 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
- **多语言** — 支持中文、日文、德语、瑞典语、挪威语、丹麦语、土耳其语

---

## 📦 安装

### Homebrew Cask（推荐）

```bash
brew install bleunlock
```

### 手动安装

1. 从 [Releases](https://gitee.com/fuhahah/bleunlock/releases) 下载最新版本
2. 解压后将 `BLEUnlock.app` 移到 `/Applications` 文件夹
3. 首次启动时按提示授予蓝牙、辅助功能、钥匙串和通知权限

---

## 🚀 快速开始

1. 启动 BLEUnlock，菜单栏出现蓝牙图标
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
| **Enabled** | 总开关，暂停/恢复 BLEUnlock |
| **Unlock RSSI** | 解锁阈值，数值越大要求越近（设为 Disable 关闭自动解锁） |
| **Lock RSSI** | 锁定阈值，数值越小要求越远（设为 Disable 关闭自动锁定） |
| **Delay to Lock** | 检测到离开后延迟多久再锁定（防止误触） |
| **No-Signal Timeout** | 最后一次收到信号后多久判定为信号丢失 |
| **Wake on Proximity** | 靠近时唤醒显示器 |
| **Wake without Unlocking** | 只唤醒不解锁（配合 Apple Watch 解锁） |
| **Pause Now Playing** | 锁定时暂停音乐/视频播放 |
| **Use Screensaver to Lock** | 用屏保代替直接锁屏 |
| **Turn Off Screen on Lock** | 锁定时关闭显示器 |
| **Passive Mode** | 被动扫描模式，不主动连接设备（降低蓝牙干扰） |
| **Launch at Login** | 开机自启动 |

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
| `unlocked` | BLEUnlock 自动解锁 |
| `intruded` | 用户手动解锁（非 BLEUnlock 触发） |

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
BLEUnlock/
├── BLEUnlock/
│   ├── BluetoothManager.swift    # 核心状态机（@MainActor + Combine）
│   ├── BLE.swift                 # CoreBluetooth 底层驱动
│   ├── AppDelegate.swift         # NSPopover UI + 通知转发
│   ├── MenuDashboardView.swift   # SwiftUI 控制中心面板
│   ├── LEDeviceInfo.swift        # macOS 蓝牙设备数据库查询
│   ├── appleDeviceNames.swift    # Apple 设备名称映射表
│   ├── checkUpdate.swift         # 自动更新检查
│   ├── AboutBox.swift            # 关于窗口
│   ├── lowlevel.h / .c           # 系统级 API（锁屏/唤醒显示器）
│   └── MediaRemote.h             # 私有框架（Now Playing 控制）
├── Launcher/                      # 开机自启动 Helper
└── docs/                          # 开发文档
```

---

## 🏗️ 架构概览

```
┌─────────────────────────────────────────────┐
│            MenuDashboardView (SwiftUI)       │
│         NSPopover 控制中心 @ObservedObject   │
└──────────────────┬──────────────────────────┘
                   │ @Published state/rssi/connected
┌──────────────────▼──────────────────────────┐
│          BluetoothManager (@MainActor)       │
│    状态机：ScreenLockState + Combine          │
│    决策：lockOrSaveScreen / fakeKeyStrokes    │
│    async/await 替代 Timer                     │
└──────────────────┬──────────────────────────┘
                   │ BLEDelegate
┌──────────────────▼──────────────────────────┐
│              BLE (CoreBluetooth)             │
│    扫描 / 连接 / RSSI 读取 / 卡尔曼滤波      │
│    专用串行队列 bleQueue                       │
└─────────────────────────────────────────────┘
```

---

## 🛠️ 开发

### 构建

```bash
xcodebuild build -project BLEUnlock.xcodeproj -scheme BLEUnlock -destination 'platform=macOS'
```

### 要求

- Xcode 14+
- macOS 12.0+ 部署目标
- Swift 5.7+

### 关键技术

- **状态机**：`LockScreenState` 枚举管理屏幕/系统/意图/唤醒/媒体 5 个正交维度
- **Combine**：`@Published` 暴露状态，SwiftUI 视图自动响应
- **async/await**：唤醒重试、解锁延迟、入侵检测均使用 `Task` 替代 `Timer`
- **卡尔曼滤波**：RSSI 平滑处理（Q=0.008, R=0.5），替代简单滑动平均
- **自适应轮询**：RSSI 稳定时从 2s 降频到 8s，降低功耗约 75%

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
