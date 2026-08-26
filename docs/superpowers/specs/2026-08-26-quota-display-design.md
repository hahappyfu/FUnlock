# FUnlock · OpenCode 套餐余量显示 设计规格

日期：2026-08-26
状态：已评审（三节设计均获用户批准）
来源：deepseek-harness 的 opencodego-quota Web 插件方案（PLAN.md / SPEC.md）移植到 FUnlock 原生应用，总体设计重新制定
分支：feat/2026-08-26

## 1. 背景与目标

opencode 中转套餐的用量数据由既有 bridge（Node 脚本，LaunchAgent 常驻）每 30s 抓取并写入
`~/.clawd/opencode-go-bridge-cache.json`。本设计把套餐余量以苹果风视觉集成进 FUnlock：

1. **菜单栏弹窗卡片**：点 FUnlock 菜单栏图标弹出的小窗里常驻一张套餐余量卡。
2. **主窗口总览页区块**：与设备/信号信息并列的完整余量卡。
3. **迷你卡 + 点击展开详情**：两处形态统一——默认一行百分比 + 进度条，点击展开三窗口详情。

非目标：接管 bridge 进程生命周期、独立抓取 API、多账号、设置页开关、历史曲线。

## 2. 已确认决策记录

| 决策点 | 结论 |
|---|---|
| 放置位置 | C 方案：弹窗 + 总览页两处都要 |
| 数据获取 | 保留 Node bridge 抓取，FUnlock 纯读缓存 |
| 缓存路径 | 直接读 `~/.clawd/opencode-go-bridge-cache.json`，不建独立缓存 |
| bridge 生命周期 | 维持 LaunchAgent 现状（RunAtLoad + KeepAlive），FUnlock 零进程管理 |
| UI 形态 | 迷你卡 + 点击展开详情（两处一致） |
| Swift 架构 | 方案一：QuotaService 单服务轮询 + QuotaCard 共享组件 |

## 3. 数据层：QuotaService

```swift
// QuotaService.swift — ObservableObject，AppDelegate 创建持有
final class QuotaService: ObservableObject {
    @Published private(set) var snapshot: QuotaSnapshot = .empty
    // init 即读一次 + Timer(30s, main RunLoop common 模式) 续读
    // Timer 触发后派发后台队列（utility QoS）读文件+解析，
    // 完成后切回主线程更新 @Published（主线程零同步 I/O）
    // 解析失败 → logDebug + 保上次成功快照
}
```

### 缓存时间字段语义（2026-08-26 实证）

| 字段 | 实际类型 | 换算 |
|---|---|---|
| `at` | Unix 毫秒数（如 1787713741779） | `fetchedAt = Date(timeIntervalSince1970: at / 1000)` |
| `quota.*.resetInSec` | 相对剩余秒数（如 8931） | `resetAt = Date().addingTimeInterval(resetInSec)` |

实现约定：**不使用 JSONDecoder 的 dateDecodingStrategy**——`at` 用 `Double` 直接接毫秒再显式换算，
`resetAt` 由相对秒数计算得出（它不是绝对时间戳，strategy 无从表达）。

### 快照模型

```swift
struct QuotaSnapshot {
    let fetchedAt: Date?          // 缓存内 at 字段
    let expired: Bool             // fetchedAt 距今 > 10min
    let available: Bool           // 文件缺失/全空 → false
    let windows: [QuotaWindow]    // 固定顺序：5h / weekly / monthly
}

struct QuotaWindow {
    let key: String               // "5h" | "weekly" | "monthly"
    let used: Double
    let limit: Double
    let percent: Double           // 自算 used/limit*100，封顶 100；limit≤0 → 0
    let resetAt: Date?            // 读取时刻 + resetInSec*1000
}
```

### 归一化语义（继承原方案，有历史单测护体）

- `expired`：`at` 缺失或距今 >10min 即 true；available 保持 true，旧数字照常展示。
- 全空输入（无 at 且无窗口）→ `EMPTY = {available:false, fetchedAt:nil, expired:true, windows:[]}`。
- percent 由 FUnlock 自算（缓存内 percent 字段恒为 0 的 bug 值，不采信）。
- limit 非有限正数 → percent=0（除零保护）；used>limit → 封顶 100。

### 容错清单

- JSON 截断/脏读 → try/catch 保上次成功快照 + logDebug
- ENOENT 文件缺失 → `.empty` 空态，绝不抛未捕获异常
- RPC/网络不存在（纯文件读取），无网络错误面

## 4. UI 层：QuotaCard 组件

一个组件两处挂载，观察同一个 QuotaService。

### 4.1 视觉

- 苹果风：SF 字体栈（系统默认）、圆角卡、微投影。
- **迷你态**：⚡ 图标 + 「OpenCode 套餐」+ 百分比数字 + 4px 高进度条。
- **展开态**：三窗口行（标签「5 小时/本周/本月」+ 6px 进度条 + `used / limit` 数值 + 重置倒计时）+ 页脚灰字刷新说明。
- 点击迷你态 ↔ 展开态切换，带动画；原生卡片内嵌展开（无 document 监听需求）。

### 4.2 四态渲染

| 状态 | 判定 | 表现 |
|---|---|---|
| 正常 | `available && !expired` | 阈值色进度条 + 「刚刚更新」绿点 |
| 过期 | fetchedAt 距今 >10min | 琥珀点「数据过期」，旧数字照常显示 |
| 无数据 | 文件缺失/解析失败且无旧值 | 灰条 `#ececf0` + `--` + 红点，高度不变零跳动 |
| 加载中 | 首次读取未完成 | 同高骨架灰条 |

空态设计原则：任何异常都不得改变卡片布局高度（继承自用户评审要求）。

### 4.3 颜色唯一事实源

```swift
func quotaColor(percent: Double) -> Color {
    if percent > 80 { return Color(red: 1.0, green: 0.231, blue: 0.188) }   // #FF3B30 红
    if percent >= 50 { return Color(red: 1.0, green: 0.624, blue: 0.039) }  // #FF9F0A 琥珀
    return Color(red: 0.204, green: 0.780, blue: 0.349)                     // #34C759 绿
}
```

进度条一律调用此函数取色，禁止硬编码。边界单测覆盖 49.9 / 50 / 80 / 80.1。

### 4.4 本地化

所有文案走现有 `t()` 函数（FUnlockUtils.swift:4）。新增 key（约 8 个）：

```
quota_title / quota_5h / quota_weekly / quota_monthly /
quota_reset_in / quota_updated_just_now / quota_expired / quota_no_data
quota_footer_hint
```

中英 strings 文件同步补齐。

## 5. 挂载点与装配

```swift
// AppDelegate：创建持有（与 manager 同款生命周期）
let quotaService = QuotaService()

// 弹窗（AppDelegate.swift:485 现有调用点加参数）
MenuBarPopoverView(manager:..., fun:..., quota: quotaService) { ... }

// 总览页经 MainWindowView 透传
MainWindowView(manager:..., fun:..., quota: quotaService)
```

挂载位置：

1. 弹窗：`actionRows` 与 `quitRow` 之间的 Divider 分隔区。
2. 总览页：设备状态卡之后新增「套餐余量」Section。

生命周期：应用全程 30s 轮询（Timer 主 RunLoop common 模式，读取在后台队列执行）；bridge 停了自然进过期/无数据态。

前提备注：FUnlock 当前未开启 App Sandbox（entitlements 已核实无 app-sandbox 键），
读 `~/.clawd/` 无障碍；若未来开沙盒需重新评估该路径的访问方案。

## 6. 测试策略

1. 归一化单测（`FUnlockTests`）：正常 JSON / 截断 JSON / 缺文件 / limit≤0 /
   used>limit 封顶 / percent 自算非 bug 值 / 过期边界 10min / EMPTY 输入
2. `quotaColor` 边界单测：49.9 / 50 / 80 / 80.1
3. 手动验收：
   - 两处显示数值一致且与本机缓存一致
   - 写坏缓存文件（`echo '{broken' > …`）→ 不崩、保持旧值
   - bridge 停止（`launchctl unload`）→ 琥珀过期态；恢复后自动接续
   - 展开/收起动画流畅、布局无跳动

## 7. 文件清单

| 操作 | 文件 |
|---|---|
| 新增 | `FUnlock/QuotaService.swift` |
| 新增 | `FUnlock/QuotaCard.swift` |
| 修改 | `FUnlock/AppDelegate.swift`（装配） |
| 修改 | `FUnlock/MenuBarPopover.swift`（挂载） |
| 修改 | `FUnlock/MainWindowView.swift`（透传） |
| 修改 | `FUnlock/OverviewView.swift`(挂载) |
| 修改 | `FUnlock/Base.lproj/Localizable.strings` + `zh-Hans.lproj/Localizable.strings` |
| 新增 | `FUnlockTests/QuotaServiceTests.swift` |
