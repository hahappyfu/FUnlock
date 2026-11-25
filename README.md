# FUnlock

> 靠近自动解锁，离开自动锁屏 —— 用蓝牙信号守护你的 Mac，全程无需掏出手机

[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2013.0%2B-lightgrey.svg)]()
[![Version](https://img.shields.io/badge/version-2.8.37-green.svg)]()
[![Swift](https://img.shields.io/badge/Swift-5.7%2B-orange.svg)]()

FUnlock 是一个 macOS 菜单栏工具，通过监测 iPhone / Apple Watch 或任意蓝牙低功耗（BLE）设备的 RSSI 信号强度，自动锁定和解锁你的 Mac。无需安装 iPhone App，密码安全存储在 Keychain 中。

**适合谁用**：不想每次离开/回来都手动锁屏解锁的 Mac 用户；带 Apple Watch / iPhone 通勤、希望隐私与便捷兼得的用户。

---

## ✨ 项目亮点

- **靠近即解锁** — 手机靠近 Mac 自动输入密码解锁，无需手动操作
- **离开即锁定** — 手机离开范围后自动锁屏，保护隐私
- **动态信号判定** — 信号"渐弱才锁定、渐强才解锁"的平滑过程，避免信号抖动反复锁屏；忘带设备（完全无信号）时不会反复触发锁屏
- **无需 iPhone App** — 纯 macOS 端实现，利用 BLE 广播信号
- **多设备支持** — 可同时监测多个 BLE 设备，自动扫描 + RSSI 排序 + 增量更新
- **智能信号处理** — 非对称卡尔曼滤波 + 时间衰减丢包惩罚，靠近解锁干脆、离开锁定可靠
- **决策时间线（诊断页）** — 每次"为什么没解锁 / 为什么锁屏"都记录为结构化事件，按日期分组的可视化时间轴，附操作建议按钮，可排查问题
- **iMessage 通知** — 解锁/锁屏事件实时发到 Apple Watch（设置中填写收件人并授权 Messages 后开启）
- **Wi-Fi 联动** — 连接指定 Wi-Fi 时暂停自动锁屏与自动解锁（如公司/家庭网络）
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

1. 启动 FUnlock，菜单栏出现状态图标
2. 点击图标打开侧边栏控制中心
3. 在「总览」页选择你的 iPhone 或 Apple Watch（或任意 BLE 设备）
4. 输入 Mac 登录密码（安全存储在 Keychain）
5. 也可以直接使用「总览」页的**自动校准向导**，跟着走两步即可生成合适阈值

完成！离开 Mac 时自动锁屏，回来时自动解锁。

---

## 🧭 控制中心

点击菜单栏图标打开侧边栏导航控制中心（毛玻璃风格），共 7 个 Tab：

| Tab | 功能 |
|-----|------|
| **总览** | 信号仪表盘、RSSI、阈值调节、设备选择/切换、校准向导、立即锁定、统计/自动化/关于入口 |
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
| **iMessage 通知** | 解锁/锁屏事件发到 Apple Watch（需在设置中填写收件人并授权 Messages） |
| **被动模式** | 被动扫描模式，不主动连接设备 |
| **Wi-Fi 暂停** | 连接指定 SSID 时暂停锁屏（适用于公司/家庭网络） |
| **手动锁屏保护** | 内置行为：手动锁屏后不自动解锁，需手动解锁重置 |

---

## 🛡️ 安全设计

- **Keychain 加密**：密码使用 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` 存储——锁屏自动解锁必须在会话锁定状态下读取密码，因此要求设备首次解锁后即可读；`ThisDeviceOnly` 限制密钥不随 iCloud 钥匙串同步到其他设备
- **竞态保护**：手动解锁后短时间内禁止自动解锁，防止密码注入到已解锁屏幕
- **系统锁屏监听**：监听 `com.apple.screenIsLocked` 通知，通过系统菜单锁屏后禁止自动解锁
- **SQL 参数化查询**：蓝牙设备数据库查询使用参数绑定，防止注入
- **codesign 校验**：自动更新安装时校验应用签名，防止恶意替换
- **BLE 中继边界**：在场判定基于 RSSI 信号强度，无法防御 BLE 中继攻击（攻击者桥接转发手表广播伪造"在场"）。Apple Watch 不提供挑战应答 API，纯 macOS 端无技术对抗手段，属产品设计边界；对安全要求极高的场景请勿将本工具作为唯一防线
- **Actor 状态机**：基于 Swift Actor 的状态管理，线程安全，消除竞态条件

---

## 🔧 脚本事件

锁定/解锁时自动执行脚本，并写入事件日志：

- 事件日志：`~/Library/Application Support/FUnlock/events.log`
- 用户脚本：`~/Library/Application Scripts/com.fuhahah.FUnlock/event`（目录随 Bundle ID；开发构建为 `com.fuhahah.FUnlock-dev`）

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
├── Packages/FUnlockCore/             # 零依赖纯逻辑包（仅 import Foundation）
│   ├── Domain/                       # ScreenState / LockIntent / DeviceSnapshot
│   ├── Signal/                       # 非对称 Kalman 管线、迟滞引擎、环形缓冲
│   ├── Engine/                       # EngineState + EngineReducer（纯函数状态转移）
│   ├── Scheduler/                    # DeadlineID + DeadlineTable（纯值截止时间表）
│   └── Tests/                        # 毫秒级虚拟时钟单测（swift test，无需 App 宿主）
├── FUnlock/                          # 主应用（@_exported import FUnlockCore）
│   ├── CoreBridge.swift              # 再导出核心包 + ConfigStore 桥接扩展
│   ├── AppDelegate.swift             # NSStatusItem 壳 + 权限检查 + 通知 + 可见性门控
│   ├── FUnManager.swift              # @MainActor 命令门面（锁屏/解锁决策入口）
│   ├── FUn.swift                     # CoreBluetooth 驱动 + 设备/信号采样
│   ├── Runtime/                      # 系统副作用适配层
│   │   ├── LiveDeadlineScheduler.swift   # 唯一底层计时器（对齐最近 deadline）
│   │   ├── PowerKeepAliveAdapter.swift   # L0 有界在场保活（IOPMAssertion）
│   │   ├── NegativeSignalAdapter.swift   # 音频路由 / 网络负向快采
│   │   ├── StatusProjection.swift        # 常驻低频 @Observable 投影
│   │   └── LiveSignalProjection.swift    # 仅窗口可见时更新的高频投影
│   ├── SignalDataStore.swift         # 无定时器环形缓冲（TimelineView 按需 snapshot）
│   ├── DiagnosticsView.swift         # 诊断页（TimelineView 驱动图表，关窗零开销）
│   ├── ...                           # 视图 / Keychain / 注入 / 脚本 / 通知等
├── FUnlockTests/                     # 单元测试与集成测试（603 用例）
├── docs/                             # 开发文档与设计 spec
└── BUGS.md                           # 问题登记
```

---

## 🏗️ 架构概览

```
┌─────────────────────────────────────────────┐
│  NSStatusItem / NSPopover / MainWindowView   │
│  StatusProjection · LiveSignalProjection     │
│  TimelineView 按需读取 SignalDataStore        │
└──────────────────┬──────────────────────────┘
                   │ @Observable 投影（可见性门控）
┌──────────────────▼──────────────────────────┐
│        FUnManager（@MainActor 命令门面）      │
│   锁屏/解锁决策 · 手动锁保护 · 事件派发        │
└──────────────────┬──────────────────────────┘
                   │ EngineEvent / DeadlineEvent
┌──────────────────▼──────────────────────────┐
│  FUnlockCore（纯函数，零 OS 依赖）            │
│  EngineReducer.reduce(state:event:) → effects│
│  SignalPipeline · SignalHysteresisEngine     │
│  DeadlineTable（所有超时建模为截止时间）       │
└──────────────────┬──────────────────────────┘
                   │ 唯一调度器回送 deadlineFired
┌──────────────────▼──────────────────────────┐
│  LiveDeadlineScheduler（唯一底层计时器）      │
│  到期投递前用 matches(id, scheduledAt) 校验   │
└──────────────────┬──────────────────────────┘
                   │ 副作用适配器
   ┌──────────┬────┴─────┬──────────────┐
   ▼          ▼          ▼              ▼
 BLE 采样   IOKit/通知  CGEvent 注入   IOPMAssertion
 FUn        CGSession   SecretUTF16Buffer  L0 保活
```

**架构要点**：
- 纯函数内核 `Packages/FUnlockCore`：引擎状态与信号数学全部可脱离硬件毫秒级测试
- 全仓仅一个底层计时器：`LiveDeadlineScheduler` + `DeadlineTable`，不存在散装 `Timer`
- 三段式渐进解锁 L0（有界在场保活）→ L1（等待系统原生解锁）→ L2（`CGEvent` 注入），负向信号只加速锁屏
- 密码以 `SecretUTF16Buffer` 持有，注入后 `memset_s` 擦除；不再构造不可变密码 `String`
- 前端 CQRS：常驻低频投影 + 仅窗口可见的高频投影 + `TimelineView` 按需图表（关窗零拷贝）

---

## 🛠️ 开发

### 构建

```bash
# Release 必须走团队签名，不要加 CODE_SIGNING_ALLOWED=NO
xcodebuild build -project FUnlock.xcodeproj -scheme FUnlock -configuration Release
```

### 测试

```bash
xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' test
```

> 测试宿主为隔离进程：`AppDelegate` 检测到 `XCTestConfigurationFilePath` 时跳过蓝牙扫描与菜单栏初始化，不会顶掉正在运行的正式版。Debug 构建的 Bundle ID 为 `com.fuhahah.FUnlock-dev`，与 Release 的 `com.fuhahah.FUnlock` 隔离。

### 安装（覆盖安装）

```bash
pkill -x FUnlock; sleep 1; pgrep -x FUnlock || echo "已退出"
rm -rf /Applications/FUnlock.app
# Release 产物在 DerivedData，示例路径按本机实际调整
cp -R ~/Library/Developer/Xcode/DerivedData/FUnlock-*/Build/Products/Release/FUnlock.app /Applications/
open /Applications/FUnlock.app
```

### 签名与辅助功能权限持久化

**现象**：若 Release 用 `CODE_SIGNING_ALLOWED=NO` 构建，会产生 `Signature=adhoc / Identifier=FUnlock / TeamIdentifier=not set / Info.plist=not bound` 的临时签名。macOS 的 TCC（Transparency, Consent, and Control）会将每次构建识别为不同应用，`AXIsProcessTrusted()` 始终返回 `false`，表现为“重启后辅助功能权限被重置”。

**正确做法**：Release 走 Automatic 签名，团队 `JJYCS98SHK`（`Apple Development: jinfuaa@gmail.com`），产物为：

```
Identifier=com.fuhahah.FUnlock
TeamIdentifier=JJYCS98SHK
Signature=Apple Development
```

此时授权一次后重启仍保持。验证方式：

```bash
codesign -dv /Applications/FUnlock.app 2>&1 | grep -E "Identifier|TeamIdentifier|Signature"
```

若需排查，可在「系统设置 → 隐私与安全 → 辅助功能」中删除旧的 `FUnlock`（ad-hoc）条目，只保留团队签名版后重新勾选。

### 要求

- Xcode 15+
- macOS 13.0+ 部署目标
- Swift 5.7+

### 关键技术

- **纯函数状态机**：`EngineReducer` 以 `(State, Event) -> (State, [Effect])` 驱动全部时序与决策，副作用由运行时执行
- **单一截止时间调度器**：`DeadlineTable` 建模所有超时，`LiveDeadlineScheduler` 是唯一底层计时器；过期投递经 `matches(id, scheduledAt)` 拒绝
- **非对称卡尔曼滤波**：`SignalPipeline` 靠近时快速响应、离开时强阻尼，丢包自动降级
- **动态信号判定**：双阈值迟滞 + 斜率自适应锁屏超时，避免边缘信号反复触发
- **输入活动否决**：IOKit HID 监听键盘/触控板，有活动时否决锁定决策
- **三段式渐进解锁**：L0 有界在场保活（15 分钟空闲上限）→ L1 等待系统原生解锁 → L2 `CGEvent` 注入；负向信号只加速锁屏
- **密码零残留**：`SecretUTF16Buffer` + `memset_s` 擦除，全链路无不可变密码字符串
- **预备唤醒**：信号平滑 + 阶梯唤醒策略，避免边缘信号反复唤醒/休眠
- **连续失败降级**：密码注入连续失败时自动降级并通知用户
- **手动锁保护**：手动锁屏进入保护窗口，期间禁止自动解锁，直到用户手动解锁
- **结构化并发**：唤醒重试、解锁延迟与 UI 刷新均使用 `Task` / `TimelineView`，全仓零散装 `Timer`

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