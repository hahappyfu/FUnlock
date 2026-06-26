# Menu Change Password Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在菜单栏右键菜单中添加"重新设置密码"入口，让用户手动更新钥匙串中的密码。

**Architecture:** 在 AppDelegate 的菜单构建代码中插入一个新 NSMenuItem，点击时调用已有的 `FUnManager.askPassword()` 方法。8 个本地化文件各添加一个 `menu_change_password` key。

**Tech Stack:** Swift / AppKit / NSMenu / Localizable.strings

---

### Task 1: 添加菜单项和 action 方法

**Files:**
- Modify: `FUnlock/AppDelegate.swift:252-269`（添加新 action 方法）
- Modify: `FUnlock/AppDelegate.swift:408-409`（添加菜单项）

- [ ] **Step 1: 添加 `changePassword` action 方法**

在 `AppDelegate.swift` 的 `showStats()` 方法之后（约 line 271），添加：

```swift
    @MainActor @objc func changePassword() {
        manager.askPassword()
    }
```

- [ ] **Step 2: 在菜单中插入新项**

在 line 408（`menu_open_settings`）之后插入一行：

```swift
        menu.addItem(NSMenuItem(title: t("menu_change_password"), action: #selector(changePassword), keyEquivalent: ""))
```

修改后的菜单构建代码应为：

```swift
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: t("menu_open_settings"), action: #selector(toggleSettingsWindow(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: t("menu_change_password"), action: #selector(changePassword), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: t("menu_lock_now"), action: #selector(lockNow), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: t("menu_stats"), action: #selector(showStats), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: t("menu_quit"), action: #selector(quitApp), keyEquivalent: ""))
        statusItem.menu = menu
```

- [ ] **Step 3: Commit**

```bash
git add FUnlock/AppDelegate.swift
git commit -m "feat: 菜单栏添加重新设置密码入口"
```

---

### Task 2: 添加本地化字符串

**Files:**
- Modify: `FUnlock/zh-Hans.lproj/Localizable.strings:190-191`
- Modify: `FUnlock/Base.lproj/Localizable.strings:192-193`
- Modify: `FUnlock/ja.lproj/Localizable.strings`（menu_open_settings 之后）
- Modify: `FUnlock/de.lproj/Localizable.strings`（menu_open_settings 之后）
- Modify: `FUnlock/sv.lproj/Localizable.strings`（menu_open_settings 之后）
- Modify: `FUnlock/da.lproj/Localizable.strings`（menu_open_settings 之后）
- Modify: `FUnlock/nb.lproj/Localizable.strings`（menu_open_settings 之后）
- Modify: `FUnlock/tr.lproj/Localizable.strings`（menu_open_settings 之后）

- [ ] **Step 1: 在每个本地化文件的 `menu_open_settings` 行之后插入 `menu_change_password`**

各语言翻译：

| 文件 | 插入内容 |
|------|----------|
| `zh-Hans.lproj/Localizable.strings` | `"menu_change_password" = "重新设置密码";` |
| `Base.lproj/Localizable.strings` | `"menu_change_password" = "Re-enter Password";` |
| `ja.lproj/Localizable.strings` | `"menu_change_password" = "パスワードを再設定";` |
| `de.lproj/Localizable.strings` | `"menu_change_password" = "Passwort erneut eingeben";` |
| `sv.lproj/Localizable.strings` | `"menu_change_password" = "Ange lösenord på nytt";` |
| `da.lproj/Localizable.strings` | `"menu_change_password" = "Indtast adgangskode igen";` |
| `nb.lproj/Localizable.strings` | `"menu_change_password" = "Skriv inn passord på nytt";` |
| `tr.lproj/Localizable.strings` | `"menu_change_password" = "Şifreyi yeniden girin";` |

- [ ] **Step 2: 验证所有文件格式正确**

Run: `grep "menu_change_password" FUnlock/*/Localizable.strings`
Expected: 8 行输出，每个语言文件各一行

- [ ] **Step 3: Commit**

```bash
git add FUnlock/*/Localizable.strings
git commit -m "i18n: 添加 menu_change_password 多语言翻译"
```

---

### Task 3: 构建验证

- [ ] **Step 1: 编译项目**

Run: `xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: Commit docs 清理（如有）**

```bash
git add -A && git status
```
