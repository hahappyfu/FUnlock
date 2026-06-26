# Spec: 菜单栏添加"重新设置密码"入口

**Date:** 2026-06-26
**Scope:** FUnlock macOS 应用 — 新增菜单栏密码重设功能
**Status:** Approved

---

## Background

FUnlock 的密码输入弹窗（`askPassword()`）仅在首次启动、连续解锁失败、系统密码变更时自动触发。用户无法主动更新已存储的密码，导致密码更改后需要等多次解锁失败才能重新输入。

## Goal

在菜单栏右键菜单中添加"重新设置密码"选项，让用户随时可以手动更新钥匙串中存储的密码。

## UI Design

菜单栏右键菜单新增一项，位于"打开设置"下方：

```
打开设置
重新设置密码    ← 新增
───────────────
立即锁定
解锁统计
───────────────
退出 FUnlock
```

## Implementation

### 1. AppDelegate.swift

- 在菜单栏构建代码中（约 line 407），"打开设置"之后插入新菜单项
- 使用 localization key `menu_change_password`
- action 指向 `FUnManager.shared.askPassword()`

### 2. 本地化文件（6 语言）

新增 key `menu_change_password`：

| 语言 | 翻译 |
|------|------|
| zh-Hans | 重新设置密码 |
| en | Re-enter Password |
| ja | パスワードを再設定 |
| de | Passwort erneut eingeben |
| sv | Ange lösenord på nytt |
| da | Indtast adgangskode igen |
| nb | Skriv inn passord på nytt |
| tr | Şifreyi yeniden girin |

### 3. 不需要改动的部分

- `FUnManager.askPassword()` — 已有完整实现，直接复用
- `storePassword()` / `fetchPassword()` — 无需修改
- 设置界面 — 不涉及

## Testing

1. 右键菜单栏图标，确认"重新设置密码"出现在正确位置
2. 点击后弹出密码输入框，输入新密码后存入钥匙串
3. 锁屏后验证新密码能正常解锁
4. 各语言环境下确认翻译正确
