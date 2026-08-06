# StatsView 视觉升级实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 对 FUnlock「解锁统计」弹窗（StatsView）做 macOS 原生质感视觉升级：大圆体数字统计卡、图表阈值线线端标注 + X 轴自适应刻度、事件列表卡片化，并将数据源从 events.log 切换到 DecisionLogger。

**架构：** 全部改动集中在 `StatsView.swift`（统计口径抽为 `StatsCalculator` 纯函数便于单测），事件图标映射提取为 `DecisionEvent.icon` 共享（诊断页复用）。图表在现有 `SignalChartView` 上增强，不改数据结构。

**技术栈：** SwiftUI、Swift Charts（macOS 13+，保留 macOS 12 fallback 分支）、XCTest

**规格：** `docs/superpowers/specs/2026-08-06-stats-view-redesign.md`

---

### 任务 1：StatsCalculator 统计口径 + 单测

**文件：**
- 修改：`FUnlock/FUnlock/StatsView.swift`（末尾新增 `StatsCalculator`）
- 测试：`FUnlockTests/FUnlockTests.swift`（末尾新增 `StatsCalculatorTests` 类）

- [ ] **步骤 1：编写失败测试**

在 `FUnlockTests/FUnlockTests.swift` 文件末尾（最后一个 `}` 之前）追加：

```swift
// MARK: - StatsCalculator 统计口径

class StatsCalculatorTests: XCTestCase {

    private func event(_ cat: DecisionCategory, _ out: DecisionOutcome, dayOffset: Int = 0) -> DecisionEvent {
        DecisionEvent(
            timestamp: Calendar.current.date(byAdding: .day, value: dayOffset, to: Date())!,
            category: cat, outcome: out, reason: nil,
            rssi: nil, device: nil, screen: nil, detail: "")
    }

    func testTodayUnlocksCountsOnlySuccess() {
        let events = [event(.unlock, .success), event(.unlock, .skipped),
                      event(.unlock, .failed), event(.lock, .success)]
        XCTAssertEqual(StatsCalculator.todayUnlocks(events), 1, "今日解锁只计解锁成功")
    }

    func testTodayLocksCountsOnlySuccess() {
        let events = [event(.lock, .success), event(.lock, .skipped), event(.unlock, .success)]
        XCTAssertEqual(StatsCalculator.todayLocks(events), 1, "今日锁定只计锁定成功")
    }

    func testYesterdayEventsNotCounted() {
        let events = [event(.unlock, .success, dayOffset: -1), event(.lock, .success, dayOffset: -1)]
        XCTAssertEqual(StatsCalculator.todayUnlocks(events), 0, "昨日解锁不计入今日")
        XCTAssertEqual(StatsCalculator.todayLocks(events), 0, "昨日锁定不计入今日")
    }

    func testThisWeekUnlocksCountsSuccess() {
        let events = [event(.unlock, .success), event(.unlock, .skipped), event(.unlock, .failed)]
        XCTAssertEqual(StatsCalculator.thisWeekUnlocks(events), 1, "本周解锁只计成功")
    }
}
```

- [ ] **步骤 2：运行测试确认失败**

运行：`xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' test 2>&1 | grep -E "error:|TEST SUCCEEDED|TEST FAILED"`
预期：编译错误 `cannot find 'StatsCalculator' in scope`

- [ ] **步骤 3：实现 StatsCalculator**

在 `FUnlock/FUnlock/StatsView.swift` 文件末尾追加：

```swift
// MARK: - 统计口径

/// 统计口径：只计成功事件（解锁=category.unlock 且 outcome.success，锁定同理）
enum StatsCalculator {
    static func todayUnlocks(_ events: [DecisionEvent], now: Date = Date(), calendar: Calendar = .current) -> Int {
        events.filter { $0.category == .unlock && $0.outcome == .success
            && calendar.isDate($0.timestamp, inSameDayAs: now) }.count
    }

    static func todayLocks(_ events: [DecisionEvent], now: Date = Date(), calendar: Calendar = .current) -> Int {
        events.filter { $0.category == .lock && $0.outcome == .success
            && calendar.isDate($0.timestamp, inSameDayAs: now) }.count
    }

    static func thisWeekUnlocks(_ events: [DecisionEvent], now: Date = Date(), calendar: Calendar = .current) -> Int {
        let startOfWeek = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
        return events.filter { $0.category == .unlock && $0.outcome == .success
            && $0.timestamp >= startOfWeek }.count
    }
}
```

- [ ] **步骤 4：运行测试验证通过**

运行：`xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' test 2>&1 | grep -E "error:|TEST SUCCEEDED|TEST FAILED"`
预期：TEST SUCCEEDED

- [ ] **步骤 5：Commit**

```bash
git add FUnlock/FUnlock/StatsView.swift FUnlockTests/FUnlockTests.swift
git commit -m "feat: StatsCalculator 统计口径（只计成功）与单测"
```

---

### 任务 2：事件图标映射提取为共享

**文件：**
- 修改：`FUnlock/FUnlock/FUnlockUtils.swift`（末尾追加扩展）
- 修改：`FUnlock/FUnlock/DiagnosticsView.swift:259-269`（`icon(for:)` 改为使用共享属性）

- [ ] **步骤 1：在 FUnlockUtils.swift 追加共享图标扩展**

确认文件头部已有 `import SwiftUI`（该文件当前只有 `t(_:)`，若没有 SwiftUI import 则补上），然后在文件末尾追加：

```swift
// MARK: - 决策事件 UI 映射

extension DecisionEvent {
    /// 事件图标与颜色（诊断页/统计页共享）
    var icon: (String, Color) {
        switch (category, outcome) {
        case (.unlock, .success): return ("lock.open.fill", .green)
        case (.unlock, .failed), (.unlock, .blocked): return ("exclamationmark.triangle.fill", .red)
        case (.unlock, .skipped), (.unlock, .info): return ("lock.open", .secondary)
        case (.lock, .success): return ("lock.fill", .orange)
        case (.lock, _): return ("lock", .secondary)
        case (.system, _): return ("power", .blue)
        case (.user, _): return ("person.fill", .teal)
        }
    }
}
```

- [ ] **步骤 2：DiagnosticsView 改用共享属性**

删除 `FUnlock/FUnlock/DiagnosticsView.swift` 中的 `static func icon(for event: DecisionEvent) -> (String, Color) { ... }`（259-269 行），并将 162 行 `let iconInfo = Self.icon(for: event)` 改为 `let iconInfo = event.icon`。

- [ ] **步骤 3：构建验证**

运行：`xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' test 2>&1 | grep -E "error:|TEST SUCCEEDED|TEST FAILED"`
预期：TEST SUCCEEDED

- [ ] **步骤 4：Commit**

```bash
git add FUnlock/FUnlock/FUnlockUtils.swift FUnlock/FUnlock/DiagnosticsView.swift
git commit -m "refactor: 决策事件图标映射提取为 DecisionEvent.icon 共享"
```

---

### 任务 3：顶部统计卡片重构（大圆体数字）

**文件：**
- 修改：`FUnlock/FUnlock/StatsView.swift`（`statCard` 替换为 `largeStatCard`；`body` 中概览 Section 改三列布局）

- [ ] **步骤 1：替换 statCard 为 largeStatCard**

删除现有 `private func statCard(_ title:value:icon:color:)`（228-244 行），替换为：

```swift
// MARK: - 统计卡（大数字圆体）

    private func largeStatCard(_ title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundColor(color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
```

- [ ] **步骤 2：更新概览 Section**

将 `body` 中概览 Section（97-104 行）替换为：

```swift
                    Section {
                        HStack(spacing: 10) {
                            largeStatCard(t("stats_today_unlocks"), value: "\(todayUnlocks)", icon: "lock.open.fill", color: .green)
                            largeStatCard(t("stats_today_locks"), value: "\(todayLocks)", icon: "lock.fill", color: .orange)
                            largeStatCard(t("stats_week_unlocks"), value: "\(thisWeekUnlocks)", icon: "calendar", color: .accentColor)
                        }
                        .frame(maxWidth: .infinity)
                    }
```

- [ ] **步骤 3：构建验证**

运行：`xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' test 2>&1 | grep -E "error:|TEST SUCCEEDED|TEST FAILED"`
预期：TEST SUCCEEDED

- [ ] **步骤 4：Commit**

```bash
git add FUnlock/FUnlock/StatsView.swift
git commit -m "feat: 统计卡大圆体数字排版"
```

---

### 任务 4：信号图表 X 轴自适应 + 阈值线端标注

**文件：**
- 修改：`FUnlock/FUnlock/StatsView.swift`（`SignalChartView`，325-344 行附近）

- [ ] **步骤 1：阈值线加线端标注**

在 `SignalChartView` 的两条 `RuleMark`（260-265 行）各追加 `.annotation(position: .trailing, spacing: 2)`，标注显示当前动态阈值：

```swift
            // 阈值参考线（线端标注当前动态值）
            RuleMark(y: .value("解锁阈值", unlockThreshold))
                .foregroundStyle(.green.opacity(0.3))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .annotation(position: .trailing, spacing: 2) {
                    Text("解锁 \(Int(unlockThreshold))")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            RuleMark(y: .value("锁定阈值", lockThreshold))
                .foregroundStyle(.orange.opacity(0.3))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .annotation(position: .trailing, spacing: 2) {
                    Text("锁定 \(Int(lockThreshold))")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
```

- [ ] **步骤 2：X 轴自适应间隔**

在 `SignalChartView` 结构体（`samples`/`unlockThreshold`/`lockThreshold` 之后）添加计算属性：

```swift
    /// X 轴刻度间隔：按数据窗口跨度自适应，避免标签拥挤重叠
    private var xStride: (unit: Calendar.Component, count: Int) {
        guard let first = samples.first?.timestamp, let last = samples.last?.timestamp else { return (.minute, 5) }
        let span = last.timeIntervalSince(first)
        switch span {
        case ..<300:   return (.second, 30)   // < 5 分钟 → 30 秒
        case ..<1800:  return (.minute, 5)    // < 30 分钟 → 5 分钟
        default:       return (.minute, 15)   // ≥ 30 分钟 → 15 分钟
        }
    }
```

将 `.chartXAxis`（325-330 行）替换为：

```swift
        .chartXAxis {
            AxisMarks(values: .stride(by: xStride.unit, count: xStride.count)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
```

- [ ] **步骤 3：构建验证**

运行：`xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' test 2>&1 | grep -E "error:|TEST SUCCEEDED|TEST FAILED"`
预期：TEST SUCCEEDED

- [ ] **步骤 4：Commit**

```bash
git add FUnlock/FUnlock/StatsView.swift
git commit -m "feat: 信号图表阈值线端标注 + X 轴自适应刻度"
```

---

### 任务 5：事件列表卡片化 + 数据源切换 DecisionLogger

**文件：**
- 修改：`FUnlock/FUnlock/StatsView.swift`

- [ ] **步骤 1：数据源切换**

在 `StatsView` 结构体顶部（`dataStore` 之后）添加：

```swift
    @ObservedObject private var logger = DecisionLogger.shared
```

删除 `private let events = loadRecentEvents()`（46 行），并在 `body` 的 `.frame(width: 440, height: 560)` 之前添加 `.onAppear { if logger.events.isEmpty { logger.loadHistory() } }`。

新增计算属性（替换原 `events` 相关的统计与列表来源）：

```swift
    private var recentEvents: [DecisionEvent] {
        logger.events
            .filter { $0.category == .unlock || $0.category == .lock }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(10)
            .map { $0 }
    }
```

- [ ] **步骤 2：统计数字改用 StatsCalculator**

将 `todayUnlocks` / `todayLocks` / `thisWeekUnlocks`（52-61 行）三个计算属性替换为：

```swift
    private var todayUnlocks: Int { StatsCalculator.todayUnlocks(logger.events) }
    private var todayLocks: Int { StatsCalculator.todayLocks(logger.events) }
    private var thisWeekUnlocks: Int { StatsCalculator.thisWeekUnlocks(logger.events) }
```

- [ ] **步骤 3：最近事件 Section 卡片化**

将最近事件 Section（147-162 行）替换为：

```swift
                    // 最近事件（圆角卡片容器，时间戳在左）
                    Section(t("stats_recent_events")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(t("stats_recent_10"))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            ForEach(recentEvents) { entry in
                                HStack(spacing: 8) {
                                    Text(entry.timestamp, format: .dateTime.hour().minute().second())
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .frame(width: 62, alignment: .leading)
                                    Image(systemName: entry.icon.0)
                                        .font(.system(size: 11))
                                        .foregroundColor(entry.icon.1)
                                        .frame(width: 16)
                                    Text(t(entry.reason?.titleKey ?? entry.outcome.rawValue))
                                        .font(.callout.weight(.medium))
                                        .lineLimit(1)
                                    if !entry.detail.isEmpty {
                                        Text(entry.detail)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                        .padding(10)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    }
```

- [ ] **步骤 4：移除孤儿代码**

删除 `StatsView.swift` 顶部 `LogEntry` 结构体与 `loadRecentEvents(maxCount:)` 函数（9-31 行，整个 `// MARK: - 事件日志` 块）。删除后检查是否还有其他文件引用 `loadRecentEvents` / `LogEntry`（`grep -rn "loadRecentEvents\|LogEntry" FUnlock --include="*.swift"`，预期只剩本文件已删干净）。

- [ ] **步骤 5：macOS 12 fallback 同步数据源**

`fallbackSignalList` 的标题与数据保持结构不变（它只用 `dataStore.samples`，不受 events.log 影响），无需改动——但需确认 `if dataStore.samples.isEmpty && events.isEmpty`（82 行）空态判断中的 `events` 已替换为 `recentEvents.isEmpty`。

- [ ] **步骤 6：构建验证**

运行：`xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' test 2>&1 | grep -E "error:|TEST SUCCEEDED|TEST FAILED"`
预期：TEST SUCCEEDED

- [ ] **步骤 7：Commit**

```bash
git add FUnlock/FUnlock/StatsView.swift
git commit -m "feat: 最近事件列表卡片化，数据源切换至 DecisionLogger"
```

---

### 任务 6：本地化文案

**文件：**
- 修改：`FUnlock/FUnlock/zh-Hans.lproj/Localizable.strings`
- 修改：`FUnlock/FUnlock/Base.lproj/Localizable.strings`

- [ ] **步骤 1：新增 key**

zh-Hans 文件末尾追加：

```
"stats_recent_10" = "最新 10 条";
```

Base 文件末尾追加：

```
"stats_recent_10" = "Latest 10";
```

（其他 .lproj 无此 key，自动 fallback 到 Base 英文，无需逐个添加。）

- [ ] **步骤 2：构建验证**

运行：`xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' test 2>&1 | grep -E "error:|TEST SUCCEEDED|TEST FAILED"`
预期：TEST SUCCEEDED

- [ ] **步骤 3：Commit**

```bash
git add FUnlock/FUnlock/zh-Hans.lproj/Localizable.strings FUnlock/FUnlock/Base.lproj/Localizable.strings
git commit -m "feat: 本地化 stats_recent_10（最新 10 条）"
```

---

### 任务 7：全量回归 + 版本升级部署

**文件：**
- 修改：`FUnlock/FUnlock/Info.plist`（版本 2.8.26 → 2.8.27）

- [ ] **步骤 1：全量测试**

运行：`xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' test 2>&1 | grep -E "error:|TEST SUCCEEDED|TEST FAILED"`
预期：TEST SUCCEEDED（含新增 StatsCalculatorTests 4 个用例）

- [ ] **步骤 2：版本升级 + Release 构建 + 部署**

```bash
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 2.8.27" FUnlock/Info.plist
xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -configuration Release -derivedDataPath build build 2>&1 | tail -1
osascript -e 'tell application "FUnlock" to quit' 2>/dev/null; pkill -f "FUnlock.app" 2>/dev/null; sleep 1
rm -rf /Applications/FUnlock.app && cp -R build/Build/Products/Release/FUnlock.app /Applications/
codesign --verify --deep --strict /Applications/FUnlock.app
open /Applications/FUnlock.app && sleep 2 && pgrep -fl FUnlock | head -2
```

- [ ] **步骤 3：恢复 CFBundleVersion + Commit + Push**

```bash
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 1258" FUnlock/Info.plist
git add FUnlock/Info.plist
git commit -m "feat: 解锁统计页视觉升级（版本 2.8.27）"
unset GITHUB_TOKEN; gh auth switch --user hahappyfu >/dev/null 2>&1
git -c credential.helper='!/opt/homebrew/bin/gh auth git-credential' push github feat/diagnostics-tab
```

- [ ] **步骤 4：人工验收清单**

- 打开「解锁统计」弹窗：三卡大数字圆体、无重叠
- 图表：阈值线右端有「解锁 -65」「锁定 -80」标签；X 轴时间标签不重叠
- 最近事件：圆角卡片、时间在左（等宽）、名称+详情、最新 10 条
- 弹出统计窗口时数据从决策日志载入（含详情）
- macOS 12 fallback：无图表但文本列表正常
