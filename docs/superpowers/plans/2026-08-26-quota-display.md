# OpenCode 套餐余量显示 实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 在 FUnlock 的菜单栏弹窗与主窗口总览页各挂一张苹果风套餐余量卡（迷你态 ↔ 点击展开三窗口详情），数据来自本机 bridge 缓存文件，30 秒轮询，四态渲染零跳动。

**架构：** `QuotaService`（ObservableObject，AppDelegate 持有）后台队列每 30s 读 `~/.clawd/opencode-go-bridge-cache.json` 并归一化为不可变快照发布；`QuotaCard` 共享 SwiftUI 组件观察同一 Service，两处挂载显示永远一致。规格见 `docs/superpowers/specs/2026-08-26-quota-display-design.md`。

**技术栈：** Swift + SwiftUI + XCTest；零第三方依赖；传统 pbxproj（objectVersion 50，非文件系统同步组）。

**已核实的接口事实（实现时不要凭记忆改写）：**

- **pbxproj 注册**：新增 `.swift` 文件必须手工注册 4 处——PBXBuildFile、PBXFileReference、所属 Group 的 children、对应 Target 的 Sources phase。现成锚点样例：`DebugLog.swift` 用自定义 ID `DDGP00000000000000000001/2`（主 target），`ConfigStoreTests.swift` 用 `7340FFB65BA27D5CF63F0109`/`E695C91A38887907EE91F891`（测试 target）。本计划统一用自定义 ID 前缀 `QUOTA`（见任务 1）。
- **测试运行命令**（历史计划先例）：
  ```bash
  cd /Users/fupingguo/fuhaha_workspace/FUnlock && xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|warning: .*Quota|Test Suite|TEST SUCCEEDED|TEST FAILED" | tail -30
  ```
- **装配点行号**（合并前核对，可能漂移）：AppDelegate.swift:485 弹窗实例化、:631 主窗口实例化（`setupSettingsWindow` 内）；MainWindowView.swift:156 `OverviewView(...)` 透传点；MenuBarPopover.swift body 内分区顺序 `statusCard / enableRow / actionRows / quitRow`（:244 actionRows 定义、:327 quitRow 定义）；OverviewView.swift body 的 Form 内 `if monitoredDeviceName == nil { noDeviceSection } else { deviceStatusSection; thresholdSection; quickActionsSection }`。
- **缓存字段实际类型**（2026-08-26 对真机文件实证）：顶层 `at` 为 Unix 毫秒数（number）；`quota.<key>.resetInSec` 为相对剩余秒数（number）；`percent` 字段恒为 0 的 bug 值，一律自算不采信。窗口键固定三种：`"5h"` / `"weekly"` / `"monthly"`。
- **本地化函数**：全局 `t(_ key: String)`（FUnlockUtils.swift:4），strings 文件为 `FUnlock/Base.lproj/Localizable.strings`（英文）与 `FUnlock/zh-Hans.lproj/Localizable.strings`（中文），追加到文件末尾即可。
- **commit 规范**：仓库启用 commitlint + husky（type 必填），沿用 `feat(quota): 中文描述` 风格。

---

## 文件结构

```
FUnlock/
├── QuotaService.swift      # [新建·任务1] 快照模型 + 归一化纯函数 + 轮询服务类
└── QuotaCard.swift         # [新建·任务2/3] 取色/格式化纯函数（任务2）+ 卡片视图（任务3）
FUnlockTests/
└── QuotaTests.swift        # [新建·任务1] 归一化 + 取色 + 格式化单测（任务2 追加）
FUnlock/
├── AppDelegate.swift       # [修改·任务4] 持有 QuotaService + start + 两处传参
├── MainWindowView.swift    # [修改·任务4] 接收并透传 quota
├── OverviewView.swift      # [修改·任务4] 总览页挂载 quotaSection
├── MenuBarPopover.swift    # [修改·任务4] 弹窗挂载 QuotaCard
├── Base.lproj/Localizable.strings      # [修改·任务4] 英文 14 key
└── zh-Hans.lproj/Localizable.strings   # [修改·任务4] 中文 14 key
```

职责边界：`QuotaService` 只管「读文件→归一化→发布」，不知道任何 UI；`QuotaCard` 只管「拿快照渲染」，不自持业务状态（仅展开/收起这一个 UI 态）；纯函数（归一化/取色/格式化）全部可脱离 UI 与真实文件系统单测。

---

### 任务 1：数据内核（模型 + 归一化 + 轮询服务，TDD）

**文件：**
- 创建：`FUnlock/QuotaService.swift`
- 测试：`FUnlockTests/QuotaTests.swift`
- 修改：`FUnlock.xcodeproj/project.pbxproj`（注册上述两文件）

- [ ] **步骤 1.1：编写失败的测试**

创建 `FUnlockTests/QuotaTests.swift`：

```swift
// FUnlockTests/QuotaTests.swift
import XCTest
@testable import FUnlock

final class QuotaTests: XCTestCase {

    /// 与真机 bridge 缓存同构的合法样本（percent 字段是已知 bug 值 0，断言必须证明未采信它）
    private let validJSON = """
    {"at":1787713741779,"quota":{"5h":{"used":600,"limit":1200,"resetInSec":8931,"percent":0,"resetHuman":"x"},"weekly":{"used":750,"limit":3000,"resetInSec":421859,"percent":0,"resetHuman":"y"},"monthly":{"used":1300,"limit":6000,"resetInSec":2143015,"percent":0,"resetHuman":"z"}}}
    """.data(using: .utf8)!

    /// 1787713741779ms → 固定基准时刻，保证断言确定性
    private let baseDate = Date(timeIntervalSince1970: 1_787_713_741.779)

    func testNormalizeValidComputesPercentAndIgnoresBugField() {
        let snap = QuotaSnapshot.normalize(validJSON, now: baseDate)
        XCTAssertTrue(snap.available)
        XCTAssertFalse(snap.expired)
        XCTAssertEqual(snap.fetchedAt!, baseDate, accuracy: 0.01)
        XCTAssertEqual(snap.windows.map(\.key), ["5h", "weekly", "monthly"])
        let fiveH = snap.windows[0]
        XCTAssertEqual(fiveH.percent, 50, accuracy: 0.001)   // 600/1200 自算，而非缓存的 0
        XCTAssertEqual(fiveH.resetAt!, baseDate.addingTimeInterval(8931), accuracy: 0.01)
    }

    func testNormalizeTruncatedJSONReturnsEmpty() {
        let snap = QuotaSnapshot.normalize("{broken".data(using: .utf8), now: baseDate)
        XCTAssertEqual(snap, .empty)
    }

    func testNormalizeNilDataReturnsEmpty() {
        XCTAssertEqual(QuotaSnapshot.normalize(nil, now: baseDate), .empty)
    }

    func testNormalizeEmptyObjectReturnsEmpty() {
        let snap = QuotaSnapshot.normalize("{}".data(using: .utf8), now: baseDate)
        XCTAssertEqual(snap, .empty)
    }

    func testNormalizeNonPositiveLimitYieldsZeroPercent() {
        let json = """
        {"at":1787713741779,"quota":{"5h":{"used":100,"limit":0,"resetInSec":10},"weekly":{"used":100,"limit":-5,"resetInSec":10},"monthly":{"used":100,"resetInSec":10}}}
        """.data(using: .utf8)!
        let snap = QuotaSnapshot.normalize(json, now: baseDate)
        XCTAssertEqual(snap.windows.map(\.percent), [0, 0])   // limit≤0 → 0；limit 缺失的窗口被剔除
        XCTAssertEqual(snap.windows.count, 2)
    }

    func testNormalizeUsedOverLimitCapsAt100() {
        let json = """
        {"at":1787713741779,"quota":{"5h":{"used":150,"limit":100,"resetInSec":10}}}
        """.data(using: .utf8)!
        let snap = QuotaSnapshot.normalize(json, now: baseDate)
        XCTAssertEqual(snap.windows[0].percent, 100, accuracy: 0.001)
    }

    func testExpiredBoundaryExactlyTenMinutesIsFresh() {
        let tenMin = 1787713741779 - 600 * 1000
        let json = """
        {"at":\(tenMin),"quota":{"5h":{"used":1,"limit":2,"resetInSec":10}}}
        """.data(using: .utf8)!
        XCTAssertFalse(QuotaSnapshot.normalize(json, now: baseDate).expired)     // 恰好 600s 未超
        let overMin = 1787713741779 - 601 * 1000
        let json2 = """
        {"at":\(overMin),"quota":{"5h":{"used":1,"limit":2,"resetInSec":10}}}
        """.data(using: .utf8)!
        XCTAssertTrue(QuotaSnapshot.normalize(json2, now: baseDate).expired)     // 601s 超
    }

    func testMissingAtMarksExpiredButAvailable() {
        let json = """
        {"quota":{"5h":{"used":1,"limit":2,"resetInSec":10}}}
        """.data(using: .utf8)!
        let snap = QuotaSnapshot.normalize(json, now: baseDate)
        XCTAssertTrue(snap.expired)
        XCTAssertTrue(snap.available)
    }

    func testWindowOrderFixedRegardlessOfJSONKeyOrder() {
        let json = """
        {"at":1787713741779,"quota":{"monthly":{"used":1,"limit":2,"resetInSec":10},"5h":{"used":1,"limit":2,"resetInSec":10},"weekly":{"used":1,"limit":2,"resetInSec":10}}}
        """.data(using: .utf8)!
        XCTAssertEqual(QuotaSnapshot.normalize(json, now: baseDate).windows.map(\.key),
                       ["5h", "weekly", "monthly"])
    }
}
```

- [ ] **步骤 1.2：在 pbxproj 注册两个文件**

对 `FUnlock.xcodeproj/project.pbxproj` 做 8 处插入（锚点均以 grep 定位，插入位置紧邻锚点行）：

自定义 ID 分配：

```
QUOTA00000000000000000001  BuildFile   QuotaService.swift（主 target Sources）
QUOTA00000000000000000002  FileReference QuotaService.swift
QUOTA00000000000000000005  BuildFile   QuotaTests.swift（测试 target Sources）
QUOTA00000000000000000006  FileReference QuotaTests.swift
```

| # | 定位锚点（grep 该行） | 插入内容 |
|---|---|---|
| 1 | `DDGP00000000000000000001 /* DebugLog.swift in Sources */` 所在 PBXBuildFile section | `QUOTA00000000000000000001 /* QuotaService.swift in Sources */ = {isa = PBXBuildFile; fileRef = QUOTA00000000000000000002 /* QuotaService.swift */; };` |
| 2 | 同 section，`ConfigStoreTests.swift in Sources` 的 PBXBuildFile 行（:68 附近） | `QUOTA00000000000000000005 /* QuotaTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = QUOTA00000000000000000006 /* QuotaTests.swift */; };` |
| 3 | `DDGP00000000000000000002 /* DebugLog.swift */` 的 PBXFileReference 行（:124） | `QUOTA00000000000000000002 /* QuotaService.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = QuotaService.swift; sourceTree = "<group>"; };` |
| 4 | `E695C91A38887907EE91F891 /* ConfigStoreTests.swift */` 的 PBXFileReference 行（:171） | `QUOTA00000000000000000006 /* QuotaTests.swift */ = {isa = PBXFileReference; includeInIndex = 1; lastKnownFileType = sourcecode.swift; path = QuotaTests.swift; sourceTree = "<group>"; };` |
| 5 | `DDGP00000000000000000002 /* DebugLog.swift */,` 的 Group children 行（:250） | `QUOTA00000000000000000002 /* QuotaService.swift */,` |
| 6 | `E695C91A38887907EE91F891 /* ConfigStoreTests.swift */,` 的测试 Group children 行（:307） | `QUOTA00000000000000000006 /* QuotaTests.swift */,` |
| 7 | `DDGP00000000000000000001 /* DebugLog.swift in Sources */,` 的主 target Sources phase 行（:493） | `QUOTA00000000000000000001 /* QuotaService.swift in Sources */,` |
| 8 | `AA000022226C1DF200000001 /* FUnlockStateMachineTests.swift in Sources */,` 的测试 Sources phase 行（:543） | `QUOTA00000000000000000005 /* QuotaTests.swift in Sources */,` |

同时创建空实现占位使编译可过（下一步立即填充）：`touch FUnlock/QuotaService.swift` 写入一行注释 `// QuotaService.swift` 即可。

- [ ] **步骤 1.3：运行测试验证失败**

运行任务头部给出的测试命令。预期：FAIL——`Unknown type 'QuotaSnapshot'` 之类编译错误（红）。

- [ ] **步骤 1.4：实现 QuotaService.swift**

```swift
// QuotaService.swift
// 套餐余量数据内核：读本机 bridge 缓存 → 归一化 → 发布快照。
// 纯观察者：不碰网络、不管 bridge 进程（LaunchAgent 已保活）。
import Foundation
import Combine

// MARK: - 快照模型

struct QuotaWindow: Equatable {
    let key: String        // "5h" | "weekly" | "monthly"
    let used: Double
    let limit: Double
    let percent: Double    // 自算 used/limit*100，封顶 100；缓存内 percent 是恒 0 的 bug 值，不采信
    let resetAt: Date?     // 读取时刻 + resetInSec*1000
}

struct QuotaSnapshot: Equatable {
    let fetchedAt: Date?   // 缓存内 at（Unix 毫秒）
    let expired: Bool      // fetchedAt 缺失或距今 > 10min
    let available: Bool    // 文件缺失/解析失败/全空 → false
    let windows: [QuotaWindow]

    static let empty = QuotaSnapshot(fetchedAt: nil, expired: true, available: false, windows: [])
}

// MARK: - 归一化（纯函数，可单测）

extension QuotaSnapshot {

    /// 把 bridge 缓存原始字节归一化为快照；任何异常输入都返回可用结果，绝不抛出。
    static func normalize(_ data: Data?, now: Date = Date()) -> QuotaSnapshot {
        guard let data, !data.isEmpty,
              let file = try? JSONDecoder().decode(CacheFile.self, from: data),
              let rawQuota = file.quota, !rawQuota.isEmpty
        else { return .empty }

        // at 为 Unix 毫秒数；缺失即视为过期（available 保持 true，旧结构照常给出）
        let fetchedAt = file.at.map { Date(timeIntervalSince1970: $0 / 1000) }
        let expired = fetchedAt.map { now.timeIntervalSince($0) > 600 } ?? true

        // 固定顺序输出，与 JSON 键序无关；缺字段/非法数值的窗口直接剔除
        let windows = ["5h", "weekly", "monthly"].compactMap { key -> QuotaWindow? in
            guard let w = rawQuota[key],
                  let used = w.used, used.isFinite,
                  let limit = w.limit, limit.isFinite
            else { return nil }
            let percent = limit <= 0 ? 0 : min(100, max(0, used / limit * 100))
            let resetAt = w.resetInSec.map { now.addingTimeInterval($0) }
            return QuotaWindow(key: key, used: used, limit: limit, percent: percent, resetAt: resetAt)
        }
        return QuotaSnapshot(fetchedAt: fetchedAt, expired: expired, available: true, windows: windows)
    }

    // 注意：不用 JSONDecoder 的 dateDecodingStrategy——at 是毫秒数用 Double 接，
    // resetInSec 是相对秒数不是绝对时间戳，strategy 无从表达，显式换算更直白。
    private struct CacheFile: Decodable {
        let at: Double?
        let quota: [String: RawWindow]?
    }
    private struct RawWindow: Decodable {
        let used: Double?
        let limit: Double?
        let resetInSec: Double?
    }
}

// MARK: - 轮询服务

/// AppDelegate 创建持有；start() 后每 30s 读一次缓存。
/// 读文件与解码在后台 utility 队列，仅在回主线程时触碰 @Published。
final class QuotaService: ObservableObject {
    @Published private(set) var snapshot: QuotaSnapshot = .empty

    static let cachePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".clawd/opencode-go-bridge-cache.json")

    private let interval: TimeInterval
    private var timer: Timer?

    init(interval: TimeInterval = 30) {
        self.interval = interval
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)   // common 模式：弹窗滚动时不冻结轮询
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 单次刷新：后台读 + 解析，主线程发布。失败静默保留旧快照。
    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = try? Data(contentsOf: Self.cachePath)
            let snap = QuotaSnapshot.normalize(data)
            DispatchQueue.main.async { [weak self] in
                self?.snapshot = snap
            }
        }
    }
}
```

- [ ] **步骤 1.5：运行测试验证通过**

运行同一测试命令。预期：`Test Suite QuotaTests` 全部 PASS，且全仓既有套件无回归（370+ 项）。

- [ ] **步骤 1.6：Commit**

```bash
cd /Users/fupingguo/fuhaha_workspace/FUnlock && git add FUnlock/QuotaService.swift FUnlockTests/QuotaTests.swift FUnlock.xcodeproj/project.pbxproj && git commit -m "feat(quota): 套餐余量数据内核——归一化与 30s 轮询服务（TDD）"
```

---

### 任务 2：展示纯函数（取色 / 大数缩写 / 倒计时 / 新鲜度，TDD）

**文件：**
- 创建：`FUnlock/QuotaCard.swift`（本任务只放纯函数，视图留任务 3）
- 测试：`FUnlockTests/QuotaTests.swift`（追加）

- [ ] **步骤 2.1：编写失败的测试（追加到 QuotaTests.swift 末尾，类内）**

```swift
    // MARK: 展示纯函数

    func testQuotaColorThresholdBoundaries() {
        XCTAssertEqual(quotaColor(percent: 0), quotaGreen)
        XCTAssertEqual(quotaColor(percent: 49.9), quotaGreen)
        XCTAssertEqual(quotaColor(percent: 50), quotaAmber)
        XCTAssertEqual(quotaColor(percent: 80), quotaAmber)
        XCTAssertEqual(quotaColor(percent: 80.1), quotaRed)
        XCTAssertEqual(quotaColor(percent: 100), quotaRed)
    }

    func testFormatNumScalesLargeNumbers() {
        XCTAssertEqual(formatNum(1_200_000_000), "12 亿")
        XCTAssertEqual(formatNum(6_100_000_000), "61 亿")
        XCTAssertEqual(formatNum(12_340), "1.2 万")
        XCTAssertEqual(formatNum(9999), "9999")
        XCTAssertEqual(formatNum(2.8), "2.8")
        XCTAssertEqual(formatNum(10), "10")
        XCTAssertEqual(formatNum(.nan), "--")
    }

    func testHumanizeResetThreeTiersFromSeconds() {
        XCTAssertEqual(humanizeReset(8931), "2 小时 29 分后重置")
        XCTAssertEqual(humanizeReset(5059), "1 小时 24 分后重置")
        XCTAssertEqual(humanizeReset(3600), "1 小时后重置")
        XCTAssertEqual(humanizeReset(431_995), "5 天后重置")
        XCTAssertEqual(humanizeReset(40), "1 分钟内重置")
        XCTAssertEqual(humanizeReset(-1), "1 分钟内重置")
    }

    func testTimeAgoTextFreshnessWording() {
        XCTAssertEqual(timeAgoText(baseDate.addingTimeInterval(-20), now: baseDate), "刚刚更新")
        XCTAssertEqual(timeAgoText(baseDate.addingTimeInterval(-90), now: baseDate), "更新于 1 分钟前")
        XCTAssertEqual(timeAgoText(baseDate.addingTimeInterval(-11 * 60), now: baseDate), "更新于 11 分钟前")
        XCTAssertEqual(timeAgoText(nil, now: baseDate), "暂无更新")
    }
```

同时在类外顶部（`final class QuotaTests` 上方、import 之后）加三个颜色基准常量，供断言与实现对齐：

```swift
// 与规格 §4.3 一致的阈值色基准值（#34C759 / #FF9F0A / #FF3B30）
private let quotaGreen = Color(red: 0.204, green: 0.780, blue: 0.349)
private let quotaAmber = Color(red: 1.0, green: 0.624, blue: 0.039)
private let quotaRed = Color(red: 1.0, green: 0.231, blue: 0.188)
```

注意：测试文件需要补 `import SwiftUI`（Color 类型）。

- [ ] **步骤 2.2：运行测试验证失败**

运行测试命令。预期：FAIL——`Cannot find 'quotaColor' in scope` 等编译错误。

- [ ] **步骤 2.3：实现纯函数**

创建 `FUnlock/QuotaCard.swift`（本任务内容；任务 3 会在此文件追加视图结构体）：

```swift
// QuotaCard.swift
// 套餐余量卡的展示纯函数 + 视图。纯函数区供单测，视图区不自持业务状态。
import SwiftUI

// MARK: - 展示纯函数（唯一事实源）

/** 用量阈值色：<50 绿 · [50,80] 琥珀 · >80 红。进度条一律走这里，禁止硬编码。 */
func quotaColor(percent: Double) -> Color {
    if percent > 80 { return Color(red: 1.0, green: 0.231, blue: 0.188) }   // #FF3B30
    if percent >= 50 { return Color(red: 1.0, green: 0.624, blue: 0.039) }  // #FF9F0A
    return Color(red: 0.204, green: 0.780, blue: 0.349)                     // #34C759
}

/// 至多一位小数的紧凑数字（12.0 → "12"，1.234 → "1.2"）
private func oneDecimal(_ v: Double) -> String {
    let r = (v * 10).rounded() / 10
    return r == r.rounded() ? String(Int(r)) : String(r)
}

/** 大数缩写：≥1e8 → x.x 亿；≥1e4 → x.x 万；否则至多一位小数；非法 → "--"。 */
func formatNum(_ n: Double) -> String {
    guard n.isFinite else { return "--" }
    if n >= 1e8 { return oneDecimal(n / 1e8) + " 亿" }
    if n >= 1e4 { return oneDecimal(n / 1e4) + " 万" }
    return oneDecimal(n)
}

/** 重置倒计时文案（入参为剩余秒数，与缓存 resetInSec 同单位）。 */
func humanizeReset(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds > 0 else { return t("quota_reset_soon") }
    if seconds >= 86_400 {
        return String(format: t("quota_reset_days"), Int((seconds / 86_400).rounded()))
    }
    if seconds >= 3_600 {
        let h = Int(seconds / 3_600)
        let m = Int((seconds.truncatingRemainder(dividingBy: 3_600) / 60).rounded())
        // 余数秒 < 1800 时 m ≤ 30，不可能进位溢出
        return m == 0 ? String(format: t("quota_reset_hours"), h)
                      : String(format: t("quota_reset_hours_min"), h, m)
    }
    if seconds >= 60 {
        return String(format: t("quota_reset_minutes"), max(1, Int((seconds / 60).rounded())))
    }
    return t("quota_reset_soon")
}

/** 数据新鲜度文案。 */
func timeAgoText(_ fetchedAt: Date?, now: Date) -> String {
    guard let fetchedAt else { return t("quota_no_time") }
    let diff = now.timeIntervalSince(fetchedAt)
    if diff < 60 { return t("quota_updated_just_now") }
    return String(format: t("quota_updated_ago"), Int(diff / 60))
}
```

并在 pbxproj 注册 `QuotaCard.swift`（照任务 1 表格模式再插 4 处，ID 用
`QUOTA00000000000000000003`（BuildFile）与 `QUOTA00000000000000000004`（FileReference），
Group children 插在 QuotaService.swift 行后，Sources phase 同理）。

- [ ] **步骤 2.4：运行测试验证通过**

预期：QuotaTests 全 PASS、全仓无回归。（若断言不符，修实现不改测试——测试即规格。）

- [ ] **步骤 2.5：Commit**

```bash
cd /Users/fupingguo/fuhaha_workspace/FUnlock && git add FUnlock/QuotaCard.swift FUnlockTests/QuotaTests.swift FUnlock.xcodeproj/project.pbxproj && git commit -m "feat(quota): 阈值取色与大数/倒计时/新鲜度展示纯函数（TDD）"
```

---

### 任务 3：QuotaCard 视图（迷你态 + 展开态 + 四态渲染）

UI 无既有快照测试设施，本任务以「编译通过 + 结构符合规格」为验收，行为由任务 5 手动验收兜底。

**文件：**
- 修改：`FUnlock/QuotaCard.swift`（追加视图；纯函数区不动）

- [ ] **步骤 3.1：追加视图实现**

在 `QuotaCard.swift` 文件末尾追加：

```swift
// MARK: - 卡片视图（弹窗与总览页共用）

struct QuotaCard: View {
    @ObservedObject var quota: QuotaService
    @State private var expanded = false

    private var snap: QuotaSnapshot { quota.snapshot }
    /// 有可渲染数据（available 且至少一个合法窗口）；.empty 同时充当加载中骨架
    private var hasData: Bool { snap.available && !snap.windows.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 迷你态行：点击切换展开
            Button {
                guard hasData else { return }
                withAnimation(.easeInOut(duration: 0.22)) { expanded.toggle() }
            } label: {
                miniRow.padding(.vertical, 2)
            }
            .buttonStyle(.plain)

            if expanded && hasData {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(snap.windows, id: \.key) { win in
                        windowRow(win)
                    }
                    Text(t("quota_footer_hint"))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .padding(.top, 2)
                }
                .padding(.top, 10)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // 迷你行：⚡ 标题 + 右侧百分比 + 4px 进度条 + 新鲜度徽标
    private var miniRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(hasData ? badgeColor : .secondary)
                Text(t("quota_title"))
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(displayPercent)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(hasData ? .primary : .secondary)
            }
            bar(percent: hasData ? fiveHour?.percent : nil, height: 4)
            HStack(spacing: 4) {
                Circle().fill(badgeColor).frame(width: 5, height: 5)
                Text(badgeText).font(.system(size: 9)).foregroundColor(.secondary)
                Spacer()
            }
        }
    }

    // 展开行：标签 + 倒计时 / 6px 条 + used/limit 数值
    private func windowRow(_ win: QuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(windowLabel(win.key))
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(resetText(win))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 8) {
                bar(percent: win.percent, height: 6)
                    .frame(maxWidth: .infinity)
                Text("\(formatNum(win.used)) / \(formatNum(win.limit))")
                    .font(.system(size: 9, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                    .fixedSize()
            }
        }
    }

    // 通用进度条：percent=nil 渲染灰色空槽（无数据/加载中），布局高度不变
    private func bar(percent: Double?, height: CGFloat) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                if let p = percent {
                    Capsule()
                        .fill(quotaColor(percent: p))
                        .frame(width: geo.size.width * min(100, max(0, p)) / 100)
                }
            }
        }
        .frame(height: height)
    }

    // ---- 派生展示值 ----

    private var fiveHour: QuotaWindow? { snap.windows.first { $0.key == "5h" } }

    private var displayPercent: String {
        guard hasData, let p = fiveHour?.percent else { return "--" }
        return "\(Int(p.rounded()))%"
    }

    // 四态徽标：正常绿 / 过期琥珀 / 无数据与加载中红
    private var badgeColor: Color {
        if !hasData { return .red }
        return snap.expired ? .orange : .green
    }
    private var badgeText: String {
        if !hasData { return t("quota_no_data") }
        if snap.expired { return t("quota_expired") }
        return timeAgoText(snap.fetchedAt, now: Date())
    }

    private func windowLabel(_ key: String) -> String {
        switch key {
        case "5h": return t("quota_5h")
        case "weekly": return t("quota_weekly")
        default: return t("quota_monthly")
        }
    }

    private func resetText(_ win: QuotaWindow) -> String {
        guard let resetAt = win.resetAt else { return "--" }
        return humanizeReset(resetAt.timeIntervalSinceNow)
    }
}
```

设计注记：
- 四态收敛为三个视觉分支——「加载中」复用 `.empty` 骨架（本地文件读取毫秒级完成，独立加载态属过度设计），布局高度恒定满足零跳动要求。
- 徽标文案里的倒计时/新鲜度每次 body 重估时按 `Date()` 计算；卡片本身随 Service 每 30s 快照刷新而重绘，无需额外定时器。
- `badgeColor` 用语义色 `.green/.orange/.red` 自动适配深浅色模式；进度条色 `quotaColor` 三值为苹果系统色，两种模式下均可辨识。

- [ ] **步骤 3.2：编译冒烟**

```bash
cd /Users/fupingguo/fuhaha_workspace/FUnlock && xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -5
```

预期：BUILD SUCCEEDED。

- [ ] **步骤 3.3：全量回归**

运行测试命令。预期：全部 PASS（视图未被引用，不影响既有套件）。

- [ ] **步骤 3.4：Commit**

```bash
cd /Users/fupingguo/fuhaha_workspace/FUnlock && git add FUnlock/QuotaCard.swift && git commit -m "feat(quota): QuotaCard 双态视图与四态渲染骨架"
```

---

### 任务 4：装配与本地化（两处挂载）

**文件：**
- 修改：`FUnlock/AppDelegate.swift`（约 :174 类属性区、applicationDidFinishLaunching、:485、:631）
- 修改：`FUnlock/MainWindowView.swift`（属性区 + :156）
- 修改：`FUnlock/OverviewView.swift`（属性区 + body 的 Form）
- 修改：`FUnlock/MenuBarPopover.swift`（属性区 + body 分区）
- 修改：`FUnlock/Base.lproj/Localizable.strings`、`FUnlock/zh-Hans.lproj/Localizable.strings`

- [ ] **步骤 4.1：AppDelegate 持有并启动服务**

在 AppDelegate 中 `manager` / `fun` 存储属性声明旁（grep `let fun` 或 `var fun` 定位）新增：

```swift
    let quotaService = QuotaService()
```

在 `applicationDidFinishLaunching` 内 manager/fun 完成初始化之后追加：

```swift
        quotaService.start()
```

- [ ] **步骤 4.2：两处实例化点传参**

```swift
// :485 附近（setupStatusBarAndMenu 内），原：
let hosting = NSHostingController(rootView: MenuBarPopoverView(manager: manager, fun: fun) { [weak self] action in
// 改为：
let hosting = NSHostingController(rootView: MenuBarPopoverView(manager: manager, fun: fun, quota: quotaService) { [weak self] action in
```

```swift
// :631 附近（setupSettingsWindow 内），原：
let dashboard = MainWindowView(manager: manager, fun: fun)
// 改为：
let dashboard = MainWindowView(manager: manager, fun: fun, quota: quotaService)
```

同一函数内，弹窗 hosting 创建后追加一行（macOS 13+ 让 NSPopover 跟随 SwiftUI 内容高度变化，防止展开详情后被裁切）：

```swift
        if #available(macOS 13.0, *) { hosting.sizingOptions = .preferredContentSize }
```

- [ ] **步骤 4.3：MainWindowView 透传**

属性区（`fun` 声明后）加：

```swift
    @ObservedObject var quota: QuotaService
```

:156 的 OverviewView 调用改为：

```swift
        case .overview:
            OverviewView(manager: manager, fun: fun, quota: quota,
                         showCalibration: $showCalibration)
```

- [ ] **步骤 4.4：OverviewView 挂载 quotaSection**

属性区（`fun` 声明后）加 `@ObservedObject var quota: QuotaService`；
body 的 Form 改为（套餐余量与蓝牙设备状态无关，无条件展示）：

```swift
            Form {
                if manager.monitoredDeviceName == nil {
                    noDeviceSection
                } else {
                    deviceStatusSection
                    thresholdSection
                    quickActionsSection
                }
                quotaSection
            }
            .formStyle(.grouped)
```

并在结构体内新增：

```swift
    // MARK: 套餐余量

    private var quotaSection: some View {
        Section(t("quota_title")) {
            QuotaCard(quota: quota)
        }
    }
```

- [ ] **步骤 4.5：MenuBarPopover 挂载**

属性区（`fun` 声明后）加 `@ObservedObject var quota: QuotaService`；
body 的分区序列在 `actionRows` 与 `quitRow` 之间插入一组：

```swift
            actionRows
            Divider()
            QuotaCard(quota: quota)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            quitRow
```

- [ ] **步骤 4.6：本地化 14 key**

`FUnlock/Base.lproj/Localizable.strings` 末尾追加：

```
// OpenCode 套餐余量
"quota_title" = "OpenCode Plan";
"quota_5h" = "5-hour";
"quota_weekly" = "This week";
"quota_monthly" = "This month";
"quota_reset_days" = "Resets in %d d";
"quota_reset_hours_min" = "Resets in %dh %dm";
"quota_reset_hours" = "Resets in %dh";
"quota_reset_minutes" = "Resets in %d min";
"quota_reset_soon" = "Resets soon";
"quota_updated_just_now" = "Just updated";
"quota_updated_ago" = "Updated %d min ago";
"quota_expired" = "Data stale";
"quota_no_data" = "No data";
"quota_no_time" = "No timestamp";
"quota_footer_hint" = "Auto-refreshes every 30 s · from local bridge cache";
```

`FUnlock/zh-Hans.lproj/Localizable.strings` 末尾追加：

```
// OpenCode 套餐余量
"quota_title" = "OpenCode 套餐";
"quota_5h" = "5 小时";
"quota_weekly" = "本周";
"quota_monthly" = "本月";
"quota_reset_days" = "%d 天后重置";
"quota_reset_hours_min" = "%d 小时 %d 分后重置";
"quota_reset_hours" = "%d 小时后重置";
"quota_reset_minutes" = "%d 分钟后重置";
"quota_reset_soon" = "1 分钟内重置";
"quota_updated_just_now" = "刚刚更新";
"quota_updated_ago" = "更新于 %d 分钟前";
"quota_expired" = "数据过期";
"quota_no_data" = "无数据";
"quota_no_time" = "暂无时间戳";
"quota_footer_hint" = "缓存每 30 秒自动刷新 · 数据来自本机 bridge 缓存";
```

（共 15 key，含 `quota_no_time` 兜底文案。）

- [ ] **步骤 4.7：编译 + 全量回归**

```bash
cd /Users/fupingguo/fuhaha_workspace/FUnlock && xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|TEST SUCCEEDED|TEST FAILED" | tail -5
```

预期：TEST SUCCEEDED。

- [ ] **步骤 4.8：Commit**

```bash
cd /Users/fupingguo/fuhaha_workspace/FUnlock && git add FUnlock/AppDelegate.swift FUnlock/MainWindowView.swift FUnlock/OverviewView.swift FUnlock/MenuBarPopover.swift FUnlock/Base.lproj/Localizable.strings FUnlock/zh-Hans.lproj/Localizable.strings && git commit -m "feat(quota): 弹窗与总览页双挂载及中英文本地化"
```

---

### 任务 5：实机验收（用户配合项）

按 [[feedback_install_flow]] 标准流程替换生产应用后再逐项验收。

- [ ] **步骤 5.1：构建并安装 Release 版**

```bash
cd /Users/fupingguo/fuhaha_workspace/FUnlock && xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -configuration Release -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -3
```

构建成功后：删除 `/Applications/FUnlock.app` → 拷入新构建产物 → `pkill -f FUnlock` 并确认进程退出 → 从 `/Applications` 启动。

- [ ] **步骤 5.2：验收清单（对照规格 §6）**

1. 点菜单栏图标 → 弹窗底部出现套餐卡，「5 小时」百分比与本机缓存一致（自算值非 0 bug 值）：
   `node -e "const c=require(process.env.HOME+'/.clawd/opencode-go-bridge-cache.json'); console.log(c.quota['5h'].used+'/'+c.quota['5h'].limit)"`
2. 点击卡片 → 平滑展开三窗口详情（进度条/数值/倒计时），弹窗高度自适应不被裁切；再次点击收起。
3. 打开主窗口总览页 → 「OpenCode 套餐」区块与弹窗数值一致。
4. 故障演练：`echo '{broken' > ~/.clawd/opencode-go-bridge-cache.json` → 应用不崩、卡片保持旧值红点「无数据」；等 bridge 下一轮覆盖恢复。
5. 过期演练：临时把缓存 `at` 改小 20 分钟（`node -e "..."` 改写）→ 卡片琥珀点「数据过期」，数字照旧；恢复后自动变绿。
6. 全程观察两处布局无跳动、深浅色模式下配色正常。
7. 若第 2 项出现展开裁切：确认 `sizingOptions = .preferredContentSize` 是否生效（需 macOS 13+）；仍异常则回报，另行修复。

- [ ] **步骤 5.3：验收通过后推送分支**

```bash
cd /Users/fupingguo/fuhaha_workspace/FUnlock && git push -u origin feat/2026-08-26
```

---

## 计划自检记录

- **规格覆盖度**：规格 §3 数据层→任务 1；§4.1–4.4 UI 层→任务 2/3；§5 挂载与装配→任务 4；§6 测试策略→任务 1/2 单测 + 任务 5 手动验收；§7 文件清单全部对应。无遗漏。
- **占位符扫描**：所有代码步骤均为完整可粘贴代码，无 TODO/待定/类似任务 N。
- **类型一致性**：`QuotaSnapshot.normalize(_:now:)`、`QuotaWindow(key:used:limit:percent:resetAt:)`、`quotaColor(percent:)`、`formatNum(_:)`、`humanizeReset(_:)`（秒）、`timeAgoText(_:now:)` 在任务间签名一致；测试常量名与实现色值一一对应。
