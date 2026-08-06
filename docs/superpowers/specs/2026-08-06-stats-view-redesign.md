# StatsView 视觉升级设计（2026-08-06）

## 背景与目标

FUnlock 的"解锁统计"弹窗（`StatsView.swift`，440×560）当前为系统默认 Form 风格：三张无质感小卡片、图表阈值线无文字标注、X 轴固定刻度易重叠、底部事件列表无详情且无容器。本次按 macOS 原生质感做一次视觉升级，同时修正数据源与统计口径。

**范围**：仅 `StatsView`（统计弹窗）。`DiagnosticsView`（决策时间线页）不动。slope 模式图保持现状。

## 已确认的视觉决策（用户逐项选择）

| 区域 | 决策 |
|---|---|
| 顶部三卡片 | **B 克制无背景**：大圆体数字（`.rounded` bold ≈34pt）为视觉重心，彩色图标（绿解锁/橙锁定/蓝周计）+ 次级灰小标题，无卡片底色，间距 10-12 |
| 图表阈值线 | **A 线端文字标签**：绿=解锁、橙=锁定（动态当前值），参考线右端加同色 `.caption2` 标签「解锁 -65」「锁定 -80」 |
| 事件列表 | **A 时间戳在左**：圆角卡片容器（白底/窗口背景、轻阴影、圆角 8），行 = 等宽时间戳（Menlo ~10pt）→ 图标 → 名称（medium）→ 详情（次级灰，lineLimit 1-2） |
| 整体 | 保留窗口尺寸、grouped 分区结构、标题栏与"完成"按钮、图表高度 ~200 |

## 数据与统计

- **数据源切换**：统计数字与事件列表均改用 `DecisionLogger`（`logger.events`，`loadHistory()` 载入），替代 `events.log` 解析。详情字段（如「信号升至 -62 dBm」）取自 `event.detail`；`event.rssi`/`event.device` 在 detail 为空时拼入。
- **统计口径（只计成功）**：
  - 今日解锁 = `category == .unlock && outcome == .success`
  - 今日锁定 = `category == .lock && outcome == .success`
  - 本周解锁 = 本周（周一起）同解锁口径
- 事件列表显示最近 **10 条**，时间倒序。
- 图标配色复用 `DiagnosticsView.icon(for:)` 的映射（解锁成功绿锁 / 锁定成功橙锁；其余按原映射），需将该函数提取为共享（如移到 `DecisionLogger.swift` 扩展或 `FUnlockUtils`）。

## 图表区改动（SignalChartView）

1. **X 轴自适应间隔**：按数据窗口跨度选择 `AxisMarks(values: .stride(by:by:))` 间隔：
   - 窗口 < 5 分钟 → 30 秒
   - < 30 分钟 → 5 分钟
   - ≥ 30 分钟 → 15 分钟
   - 标签格式 `时:分`（`.dateTime.hour().minute()`）
2. **阈值线标注**：两条 RuleMark（现有）改为右侧 `annotation(position: .trailing)` 或对齐末端放置小字标签，显示当前动态值（`unlockThreshold` / `lockThreshold`，即 `SignalDataStore` 快照值）。
3. 事件竖线、异常点、曲线系列、Y 轴 -100...-20 保持不动。

## macOS 12 fallback

无 Charts 分支保留文本列表结构，但数据源同步切 `DecisionLogger`（否则与主路径不一致）。

## 本地化

新增 key（zh-Hans 中文 + Base 英文，其余语言 fallback Base）：
- `stats_recent_10`（"最新 10 条"）
- 若引入新文案（如图表标注无需文案）按需补充；复用现有 `stats_today_unlocks` / `stats_today_locks` / `stats_week_unlocks` / `stats_signal_diagnostics` / `stats_recent_events`。

## 测试

- 新增统计口径单测：今日/本周/只计成功（成功与 skipped 区分）、跨天边界（昨日事件不计入今日）。
- 全量 `xcodebuild test` 回归通过。
- 视觉部分人工验收（弹出统计窗口核对卡片/图表标注/列表排版）。

## 明确不做（YAGNI）

- 不加第三条"唤醒/预解锁"参考线
- 不改 DiagnosticsView、不改 slope 图
- 不加事件分页/筛选
- 不改窗口尺寸与结构层级
