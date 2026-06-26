# Spec: FUnlock 自动检测更新

**Date:** 2026-06-26
**Scope:** FUnlock macOS 应用 — 新增自动检测更新 + 静默安装功能
**Status:** Approved

---

## Background

FUnlock 已有 `UpdateChecker` 类实现 24h 定时检测 Gitee Release 并发送系统通知，但只通知不安装。用户需要手动去 Gitee 下载更新，体验割裂。此外版本比较存在 bug：`tag_name`（`v2.2.0`）与 `CFBundleShortVersionString`（`2.2.0`）因 `v` 前缀永远不相等，导致每次检测都误报。

## Goal

实现全自动更新闭环：检测新版本 → 下载 zip → 静默安装 → 重启 app，全程无需用户干预。

## Architecture

### 组件拆分

| 组件 | 文件 | 职责 |
|------|------|------|
| UpdateChecker | `checkUpdate.swift` | 版本检测（已有，需修复+扩展） |
| UpdateDownloader | 新建 `UpdateDownloader.swift` | 下载 zip + 解压 + 校验 |
| UpdateInstaller | 新建 `UpdateInstaller.swift` | 生成安装脚本 + 启动 + 退出 app |
| AppDelegate | `AppDelegate.swift` | 菜单栏入口 + UI 状态反馈 |

### 数据流

```
onUnlock() / 手动触发
  → UpdateChecker.check()
    → Gitee API: GET /releases/latest
      → 版本比较（去 v 前缀）
        → 有新版本: UpdateDownloader.download(version)
          → URLSession 下载 zip 到 /tmp/FUnlock-update/
          → 解压 + 校验 CFBundleIdentifier
          → UpdateInstaller.install()
            → 写 install.sh 脚本
            → Process 启动脚本（脱离父进程）
            → NSApplication.terminate
            → 脚本: 等 2s → rm 旧 app → cp 新 app → open → 清理
```

---

## Component Design

### 1. UpdateChecker（修改已有）

**修改点：**

- 修复版本比较：去掉 `tag_name` 的 `v` 前缀再与本地版本比较
- 新增 `completionHandler: ((String) -> Void)?` 回调，检测到新版本时传递版本号
- 新增 `forceCheck()` 方法，忽略 24h 间隔，用于手动触发

**版本比较逻辑：**
```swift
private func compareVersionsAndNotify(_ latestVersion: String) {
    let cleanVersion = latestVersion.hasPrefix("v") ? String(latestVersion.dropFirst()) : latestVersion
    if let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
       current != cleanVersion {
        notify()
        completionHandler?(cleanVersion)  // 触发下载
        notified = true
    }
}
```

### 2. UpdateDownloader（新建）

**职责：** 下载 zip → 解压 → 校验

**API：**
```swift
class UpdateDownloader {
    enum State {
        case idle
        case downloading(progress: Double)
        case completed(URL)        // 解压后的 app 路径
        case failed(Error)
    }

    var onStateChange: ((State) -> Void)?

    func download(version: String)
    func cancel()
}
```

**下载 URL：**
```
https://gitee.com/fuhahah/bleunlock/releases/download/v{version}/FUnlock.zip
```

**实现要点：**
- 使用 `URLSessionDownloadTask` + `URLSessionDownloadDelegate` 获取进度
- 下载到 `/tmp/FUnlock-update/FUnlock.zip`
- 使用 `unzip` 命令解压到 `/tmp/FUnlock-update/`
- 校验解压后的 `FUnlock.app/Contents/Info.plist` 的 `CFBundleIdentifier` 必须等于 `com.fuhahah.FUnlock`
- 校验失败 → 删除临时文件 → `.failed`

### 3. UpdateInstaller（新建）

**职责：** 生成安装脚本 → 启动 → 退出 app

**API：**
```swift
class UpdateInstaller {
    static func install(appPath: URL) throws
}
```

**安装脚本内容：**
```bash
#!/bin/bash
sleep 2  # 等待 app 退出
APP="/Applications/FUnlock.app"
UPDATE="/tmp/FUnlock-update/FUnlock.app"

if [ -d "$UPDATE" ]; then
    rm -rf "$APP"
    cp -R "$UPDATE" "$APP"
    open "$APP"
fi
rm -rf /tmp/FUnlock-update
```

**启动脚本方式：**
```swift
let process = Process()
process.executableURL = URL(fileURLWithPath: "/bin/bash")
process.arguments = [scriptPath]
process.standardOutput = FileHandle.nullDevice
process.standardError = FileHandle.nullDevice
try process.run()
```

### 4. UI 交互

**菜单栏入口：**
```
打开设置
重新设置密码
检查更新         ← 新增
───────────────
...
```

**菜单项状态：**
- 默认：`"检查更新"` / `menu_check_update`
- 检测中：`"检查中..."` / disabled
- 下载中：`"正在下载更新 (45%)..."` / disabled
- 无新版本：Toast `"已是最新版本"`

**后台自动检测：**
- `onUnlock()` 时触发，检测到新版本后静默下载安装
- 下载完成后弹窗提示"FUnlock 即将重启以完成更新"，1 秒后自动退出

---

## Error Handling

| 场景 | 处理 |
|------|------|
| 网络不可用 | 静默跳过，下次 unlock 重试 |
| 下载失败 | 静默跳过，不打断用户 |
| 解压失败 | 清理临时文件，静默跳过 |
| Bundle ID 不匹配 | 清理临时文件，静默跳过 |
| 安装脚本启动失败 | 清理临时文件，静默跳过 |
| 用户在下载过程中锁屏 | URLSession 后台继续下载 |

---

## Testing

1. **版本比较**：mock API 返回 `v2.3.0`，本地 `2.2.0` → 应触发更新；mock 返回 `v2.2.0` → 不触发
2. **下载**：mock 一个小型 zip，验证进度回调和解压
3. **安装脚本**：验证脚本内容正确，Process 能启动
4. **菜单栏**：手动点击"检查更新"，验证状态变化
5. **端到端**：发布测试版本，验证完整更新流程
