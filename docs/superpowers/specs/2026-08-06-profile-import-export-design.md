# 配置文件导入导出设计规格

> 日期：2026-08-06 ｜ 分支：feat/diagnostics-tab ｜ 状态：已批准（用户确认）

## 背景与动机

配置文件（Profile）当前仅存于 UserDefaults（`ProfileManager`），重装/换机即丢失，也无法分享。用户要求：配置文件栏支持**导入/导出**（文件形式），实现备份、迁移与分享。

现状：`ConfigSettingsView` 已有配置文件选择下拉 + 新增（+）/删除（−）按钮；`Profile` 模型（id/name/lockRSSI/unlockRSSI/enabled）已是 Codable。

## 范围

**包含：**
- 导出：全部配置文件 → 单个 JSON 文件（用户选位置保存）
- 导入：选择 JSON 文件 → 合并进现有配置（同 id 覆盖、default 跳过、新配置追加）

**不包含（YAGNI）：**
- 完整应用设置导出（阈值偏移量、开关项等）——仅配置文件本身
- 版本字段、导出单个配置、剪贴板复制、自动备份目录

## 文件格式

JSON 数组，直接编码现有 `Profile` 结构：

```json
[{"id":"default","name":"默认","lockRSSI":-80,"unlockRSSI":-60,"enabled":true}]
```

- 编码器使用 `prettyPrinted` + `.utf8` 输出，方便人类阅读/分享
- 无版本字段（Profile 结构简单，解码失败即报导入失败）

## 数据层：ProfileManager 扩展（纯逻辑，可测）

```swift
// 全部配置 → JSON 字符串（prettyPrinted）；编码失败返回 nil
func exportJSON() -> String?

// 解析 JSON 并合并：
//  - 同 id 已存在 → 覆盖（计入 updated）
//  - id == "default" → 跳过（保护内置默认，计入 skipped）
//  - 新 id → 追加（计入 added）
// 解析失败 → 返回 nil
// 成功 → 保存到 UserDefaults 并返回统计
func importFrom(json: String) -> (added: Int, updated: Int, skipped: Int)?
```

- `importFrom` 内部使用 `JSONDecoder` 解码 `[Profile]`；解码失败返回 nil
- 合并完成后调用现有 `save()` 持久化
- 导入不切换 activeProfileID（导入≠应用）

## UI 层：ConfigSettingsView（负责文件面板）

在现有 `+ / −` 按钮行追加两个按钮（小图标，与现有风格一致）：

| 按钮 | 图标 | 行为 |
|---|---|---|
| 导入 | `arrow.down.doc` | NSOpenPanel 选文件（默认过滤 json）→ 读内容 → `importFrom(json:)` → toast 结果 |
| 导出 | `arrow.up.doc` | `exportJSON()` → NSSavePanel 选位置（默认名 "FUnlock-配置.json"）→ 写入 → toast 成功 |

Toast 复用现有 `MainWindowView.showToast` 机制：给 `ConfigSettingsView` 增加 `onToast: ((String, String, Color) -> Void)? = nil` 闭包参数，`MainWindowView` 传 `{ self.showToast($0, icon: $1, color: $2) }`；未传时（无闭包）静默失败即可。

错误处理：
- 导出编码失败 / 写入失败 → toast "导出失败"
- 导入文件读取失败 / 解析失败 → toast "导入失败"
- 导入成功 → toast "已导入：新增 x，更新 y"

## 本地化（zh-Hans + Base，其余 fallback）

| key | zh-Hans | Base |
|---|---|---|
| profile_import | 导入 | Import |
| profile_export | 导出 | Export |
| profile_export_done | 配置已导出 | Profiles exported |
| profile_import_done | 已导入：新增 %d，更新 %d | Imported: %d added, %d updated |
| profile_export_failed | 导出失败 | Export failed |
| profile_import_failed | 导入失败 | Import failed |

（字符串拼接用 `String(format:)`，与现有代码风格一致。）

## 测试（FUnlockTests.swift 新增 ProfileImportExportTests 类）

1. **往返一致性**：构造 2 个配置 → `exportJSON()` → `importFrom(json:)` → 断言配置内容一致、统计正确（added=2）
2. **同 id 覆盖**：先有 A(id=a, lock=-80) → 导入 A'(id=a, lock=-70) → a 被覆盖为 -70，统计 updated=1
3. **default 保护**：导入含 id="default" 且 lockRSSI 被改的配置 → 内置 default 不被覆盖，统计 skipped=1
4. **新配置追加**：导入含既有 id 与全新 id → 全新 id 追加成功
5. **非法 JSON**：`importFrom(json: "not json")` → nil
6. **导出编码**：`exportJSON()` 返回非 nil 且可被 JSONSerialization 解析为数组

## 验收标准

- 设置 → 配置文件栏可见导入/导出按钮
- 导出：选择位置生成 .json，内容为可读 JSON 数组
- 导入：选择合法文件后配置列表合并生效；选非法文件 toast "导入失败"
- 全量测试通过（新增 6 个用例）
