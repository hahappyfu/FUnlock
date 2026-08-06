# 配置文件导入导出实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 给配置文件栏（ConfigSettingsView）增加文件导入/导出：全部配置文件导出为单个 JSON 文件，导入时合并（同 id 覆盖、default 跳过、新配置追加）。

**架构：** 纯逻辑放 `ProfileManager`（`exportJSON()` / `importFrom(json:)`，可单测）；文件面板（NSSavePanel/NSOpenPanel）与按钮放 `ConfigSettingsView`，toast 通过新增 `onToast` 闭包回调到 `MainWindowView`。

**技术栈：** SwiftUI、AppKit（NSSavePanel/NSOpenPanel）、UniformTypeIdentifiers、JSONEncoder/Decoder（Profile 已 Codable）、XCTest

**规格：** `docs/superpowers/specs/2026-08-06-profile-import-export-design.md`（已批准）

---

### 任务 1：ProfileManager 导出/导入逻辑 + 单测

**文件：**
- 修改：`FUnlock/ProfileManager.swift`（`save()` 之前追加两个方法）
- 测试：`FUnlockTests/FUnlockTests.swift`（文件末尾追加 `ProfileImportExportTests` 类）

- [ ] **步骤 1：编写失败测试**

在 `FUnlockTests/FUnlockTests.swift` 文件末尾（最后一个 `}` 之前）追加：

```swift
// MARK: - 配置文件导入导出

class ProfileImportExportTests: XCTestCase {
    private var manager: ProfileManager!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "profiles")
        UserDefaults.standard.removeObject(forKey: "activeProfileID")
        manager = ProfileManager()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "profiles")
        UserDefaults.standard.removeObject(forKey: "activeProfileID")
        super.tearDown()
    }

    private func profile(_ id: String, _ name: String, lock: Int) -> Profile {
        Profile(id: id, name: name, lockRSSI: lock, unlockRSSI: -60, enabled: true)
    }

    func testExportImportRoundTrip() {
        manager.addProfile(profile("a", "家", lock: -70))
        manager.addProfile(profile("b", "公司", lock: -75))
        guard let json = manager.exportJSON(),
              let stats = manager.importFrom(json: json) else {
            return XCTFail("导出/导入应成功")
        }
        XCTAssertEqual(stats.added, 2, "往返后新增 2 个配置")
        XCTAssertEqual(stats.updated, 0)
        XCTAssertEqual(stats.skipped, 0)
        XCTAssertTrue(manager.profiles.contains { $0.id == "a" && $0.name == "家" })
        XCTAssertTrue(manager.profiles.contains { $0.id == "b" && $0.lockRSSI == -75 })
    }

    func testImportOverwritesSameID() {
        manager.addProfile(profile("a", "家", lock: -70))
        let json = "[{\"id\":\"a\",\"name\":\"家新版\",\"lockRSSI\":-65,\"unlockRSSI\":-60,\"enabled\":true}]"
        guard let stats = manager.importFrom(json: json) else {
            return XCTFail("导入应成功")
        }
        XCTAssertEqual(stats.updated, 1, "同 id 应覆盖")
        XCTAssertEqual(manager.profiles.first { $0.id == "a" }?.lockRSSI, -65)
        XCTAssertEqual(manager.profiles.first { $0.id == "a" }?.name, "家新版")
    }

    func testImportSkipsDefault() {
        let json = "[{\"id\":\"default\",\"name\":\"恶意默认\",\"lockRSSI\":-30,\"unlockRSSI\":-20,\"enabled\":true}]"
        guard let stats = manager.importFrom(json: json) else {
            return XCTFail("导入应成功")
        }
        XCTAssertEqual(stats.skipped, 1, "default 应被跳过保护")
        XCTAssertEqual(manager.profiles.first { $0.id == "default" }?.name, "默认", "内置默认不得被覆盖")
    }

    func testImportAppendsNew() {
        manager.addProfile(profile("a", "家", lock: -70))
        let json = "[{\"id\":\"a\",\"name\":\"家\",\"lockRSSI\":-70,\"unlockRSSI\":-60,\"enabled\":true},{\"id\":\"c\",\"name\":\"新\",\"lockRSSI\":-78,\"unlockRSSI\":-55,\"enabled\":true}]"
        guard let stats = manager.importFrom(json: json) else {
            return XCTFail("导入应成功")
        }
        XCTAssertEqual(stats.updated, 1)
        XCTAssertEqual(stats.added, 1, "全新 id 应追加")
        XCTAssertTrue(manager.profiles.contains { $0.id == "c" })
    }

    func testImportInvalidJSONReturnsNil() {
        XCTAssertNil(manager.importFrom(json: "not json"))
        XCTAssertNil(manager.importFrom(json: "{\"wrong\":\"shape\"}"), "非数组结构应失败")
    }

    func testExportProducesValidJSONArray() {
        manager.addProfile(profile("a", "家", lock: -70))
        guard let json = manager.exportJSON(), let data = json.data(using: .utf8) else {
            return XCTFail("导出应成功")
        }
        let array = try? JSONSerialization.jsonObject(with: data) as? [Any]
        XCTAssertNotNil(array, "导出内容应为合法 JSON 数组")
    }
}
```

- [ ] **步骤 2：运行测试确认失败**

运行：`xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' test 2>&1 | grep -E "error:|TEST SUCCEEDED|TEST FAILED"`
预期：编译错误 `value of type 'ProfileManager' has no member 'exportJSON'`

- [ ] **步骤 3：实现 exportJSON 与 importFrom**

在 `FUnlock/ProfileManager.swift` 的 `// MARK: - Persistence` 之前追加：

```swift
    // MARK: - 导入导出

    /// 导出全部配置为 JSON 字符串（prettyPrinted）；编码失败返回 nil
    func exportJSON() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(profiles) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 解析 JSON 并合并进现有配置：
    /// 同 id 覆盖（updated）；id == "default" 跳过保护（skipped）；新 id 追加（added）。
    /// 解析失败返回 nil；成功则持久化并返回统计。
    func importFrom(json: String) -> (added: Int, updated: Int, skipped: Int)? {
        guard let data = json.data(using: .utf8),
              let incoming = try? JSONDecoder().decode([Profile].self, from: data) else {
            return nil
        }
        var added = 0, updated = 0, skipped = 0
        for p in incoming {
            if p.id == "default" {
                skipped += 1
                continue
            }
            if let idx = profiles.firstIndex(where: { $0.id == p.id }) {
                profiles[idx] = p
                updated += 1
            } else {
                profiles.append(p)
                added += 1
            }
        }
        save()
        return (added, updated, skipped)
    }
```

- [ ] **步骤 4：运行测试确认通过**

运行：`xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' test 2>&1 | grep -E "error:|TEST SUCCEEDED|TEST FAILED"`
预期：TEST SUCCEEDED

- [ ] **步骤 5：Commit**

```bash
git add FUnlock/ProfileManager.swift FUnlockTests/FUnlockTests.swift
git commit -m "feat: ProfileManager 配置导出/导入（合并策略）与单测"
```

---

### 任务 2：ConfigSettingsView 导入/导出按钮 + 文件面板 + toast 接线

**文件：**
- 修改：`FUnlock/ConfigSettingsView.swift`（头部 import、结构体属性、按钮行）
- 修改：`FUnlock/MainWindowView.swift:155`

- [ ] **步骤 1：ConfigSettingsView 增加 onToast 闭包与 import**

`FUnlock/ConfigSettingsView.swift` 头部改为：

```swift
// ConfigSettingsView.swift
import SwiftUI
import UniformTypeIdentifiers
```

结构体属性（`@State private var newProfileName = ""` 之后）追加：

```swift
    var onToast: ((String, String, Color) -> Void)? = nil
```

- [ ] **步骤 2：按钮行追加导入/导出按钮**

将现有 `HStack` 按钮区（`plus.circle` / `minus.circle` 的 HStack）整体替换为：

```swift
                    HStack {
                        Spacer()
                        Button {
                            newProfileName = ""
                            showAddProfile = true
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                        if profileManager.activeProfileID != "default" {
                            Button { showDeleteProfile = true } label: {
                                Image(systemName: "minus.circle")
                            }
                        }
                        Divider()
                            .frame(height: 12)
                        Button(action: importProfiles) {
                            Image(systemName: "arrow.down.doc")
                        }
                        Button(action: exportProfiles) {
                            Image(systemName: "arrow.up.doc")
                        }
                    }
```

- [ ] **步骤 3：追加导入/导出动作方法**

在结构体末尾（最后一个 `}` 之前）追加：

```swift
    // MARK: - 导入/导出

    private func importProfiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let content = try? String(contentsOf: url, encoding: .utf8),
                  let stats = self.profileManager.importFrom(json: content) else {
                self.onToast?(t("profile_import_failed"), "xmark.circle", .red)
                return
            }
            self.onToast?(String(format: t("profile_import_done"), stats.added, stats.updated),
                          "checkmark.circle", .green)
        }
    }

    private func exportProfiles() {
        guard let json = profileManager.exportJSON() else {
            onToast?(t("profile_export_failed"), "xmark.circle", .red)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = t("profile_export_filename")
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try json.write(to: url, atomically: true, encoding: .utf8)
                self.onToast?(t("profile_export_done"), "checkmark.circle", .green)
            } catch {
                self.onToast?(t("profile_export_failed"), "xmark.circle", .red)
            }
        }
    }
```

注意：`NSSavePanel`/`NSOpenPanel` 的 `begin` 回调在非主线程调度时也需在 main 更新 UI；`onToast` 内部最终调用 `MainWindowView.showToast`（已用 DispatchQueue.main.async 处理），此处直接调用即可。若编译报 `conversion of '(NSSavePanel) -> Void'...` 等签名问题，确认 panel 变量类型为 `NSSavePanel`（import AppKit 经 SwiftUI 隐含可用，必要时显式 `import AppKit`）。

- [ ] **步骤 4：MainWindowView 接线**

`FUnlock/MainWindowView.swift:155` 改为：

```swift
        case .config:
            ConfigSettingsView(manager: manager, onToast: { message, icon, color in
                self.showToast(message, icon: icon, color: color)
            })
```

- [ ] **步骤 5：构建验证**

运行：`xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' test 2>&1 | grep -E "error:|TEST SUCCEEDED|TEST FAILED"`
预期：TEST SUCCEEDED（无编译错误）

- [ ] **步骤 6：Commit**

```bash
git add FUnlock/ConfigSettingsView.swift FUnlock/MainWindowView.swift
git commit -m "feat: 配置文件栏导入/导出按钮（文件面板 + toast）"
```

---

### 任务 3：本地化文案

**文件：**
- 修改：`FUnlock/zh-Hans.lproj/Localizable.strings`
- 修改：`FUnlock/Base.lproj/Localizable.strings`

- [ ] **步骤 1：新增 key**

在 zh-Hans 的 `"mb_signal_lost" = "无信号";` 之后追加：

```
"profile_import" = "导入";
"profile_export" = "导出";
"profile_export_done" = "配置已导出";
"profile_import_done" = "已导入：新增 %d，更新 %d";
"profile_export_failed" = "导出失败";
"profile_import_failed" = "导入失败";
"profile_export_filename" = "FUnlock-配置.json";
```

在 Base 的 `"mb_signal_lost" = "No signal";` 之后追加：

```
"profile_import" = "Import";
"profile_export" = "Export";
"profile_export_done" = "Profiles exported";
"profile_import_done" = "Imported: %d added, %d updated";
"profile_export_failed" = "Export failed";
"profile_import_failed" = "Import failed";
"profile_export_filename" = "FUnlock-profiles.json";
```

（其余 .lproj 无此 key，自动 fallback 到 Base，无需逐个添加。`profile_import`/`profile_export` 为按钮 accessibility label 用，虽未直接展示文本但保持完整。）

- [ ] **步骤 2：构建验证**

运行：`xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' test 2>&1 | grep -E "error:|TEST SUCCEEDED|TEST FAILED"`
预期：TEST SUCCEEDED

- [ ] **步骤 3：Commit**

```bash
git add FUnlock/zh-Hans.lproj/Localizable.strings FUnlock/Base.lproj/Localizable.strings
git commit -m "feat: 配置文件导入导出本地化文案"
```

---

### 任务 4：全量回归 + 部署（需用户确认后执行）

- [ ] **步骤 1：全量测试**

运行：`xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' test 2>&1 | grep -E "error:|TEST SUCCEEDED|TEST FAILED"`
预期：TEST SUCCEEDED（含新增 ProfileImportExportTests 6 个用例）

- [ ] **步骤 2：升版 + Release 构建 + 部署（执行前先向用户确认）**

```bash
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 2.8.29" FUnlock/Info.plist
xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -configuration Release -derivedDataPath build build 2>&1 | tail -1
osascript -e 'tell application "FUnlock" to quit' 2>/dev/null; pkill -f "FUnlock.app" 2>/dev/null; sleep 1
rm -rf /Applications/FUnlock.app && cp -R build/Build/Products/Release/FUnlock.app /Applications/
codesign --verify --deep --strict /Applications/FUnlock.app
open /Applications/FUnlock.app && sleep 2 && pgrep -fl FUnlock | head -2
```

- [ ] **步骤 3：恢复版本号 + Commit + Push**

```bash
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 1258" FUnlock/Info.plist
git add FUnlock/Info.plist
git commit -m "feat: 配置文件导入导出（版本 2.8.29）"
git -c credential.helper='!/opt/homebrew/bin/gh auth git-credential' push github feat/diagnostics-tab
```

- [ ] **步骤 4：人工验收清单**

- 设置 → 配置文件栏：可见 导入（↓doc）/ 导出（↑doc）两个新按钮
- 导出：保存面板默认名"FUnlock-配置.json"，生成的 .json 为可读 JSON 数组（含所有配置）
- 导入：选导出文件 → toast"已导入：新增 x，更新 y"，列表出现新配置且可切换
- 导入同一文件两次：第二次 toast 更新数而非新增（同 id 覆盖）
- 选非 JSON 文件 → toast"导入失败"
- 配置文件含内置"默认"时导入含 default 的文件：default 不被覆盖
