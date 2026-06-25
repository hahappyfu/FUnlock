# FUnlock SF Symbols 图标映射表

> 目标：macOS 13+ 兼容，仅使用 SF Symbols 1/2 已有的符号。
> 所有图标通过 `Image(systemName:)` 调用，颜色使用 Apple 标准色板。

---

## 1. 侧边栏 Tab

| Tab | SF Symbol | 颜色 | 说明 |
|-----|-----------|------|------|
| 总览 | `gauge.medium` | `.primary` | 信号仪表盘，gauge 比 clock 更贴合"仪表/总览"语义 |
| 设备 | `antenna.radiowaves.left.and.right` | `.primary` | 复用现有 BLE 扫描图标 |
| 基础 | `gearshape` | `.primary` | 系统设置齿轮 |
| 解锁 | `lock.open` | `.primary` | 开锁，与设置页面保持一致 |
| 锁定 | `lock` | `.primary` | 上锁 |
| 网络 | `network` | `.primary` | 通用网络图标，与 `wifi` 做区分 |
| 配置 | `folder` | `.primary` | 配置文件夹 |

**注**：设计文档原定 `wifi` 给设备 tab，但设备是 BLE 不是 Wi-Fi，改为 `antenna.radiowaves.left.and.right`；网络 tab 用 `network` 避免重复。

---

## 2. 设备状态栏（固定顶部）

| 元素 | SF Symbol | 颜色 | 说明 |
|------|-----------|------|------|
| 已连接 | 绿色圆点 `Circle()` | `.green` | 保持现有圆点，不用图标 |
| 已断开 | 橙色圆点 `Circle()` | `.orange` | 同上 |
| 未绑定 — 扫描提示 | `magnifyingglass` | `.secondary` | 放大镜表示搜索 |
| 未绑定 — 扫描中 | `arrow.triangle.2.circlepath` | `.accentColor` | 旋转刷新，表示正在扫描 |
| 绑定按钮 | `plus.circle` | `.accentColor` | 绑定操作 |

---

## 3. 设备列表行

| 元素 | SF Symbol | 颜色 | 说明 |
|------|-----------|------|------|
| 设备图标 | `iphone` | `.accentColor` | iPhone 设备 |
| 导航箭头 | `chevron.right` | `.secondary` | 列表项进入指示 |

---

## 4. 信号仪表区

| 元素 | SF Symbol | 颜色 | 说明 |
|------|-----------|------|------|
| 校准向导 | `wand.and.stars` | `.accentColor` | 魔棒 = 智能校准 |
| 锁定阈值标签 | `lock.fill` | `.orange` | 锁定阈值 |
| 解锁阈值标签 | `lock.open.fill` | `.green` | 解锁阈值 |
| 滑块 - 按钮 | `minus.circle` / `plus.circle` | `.accentColor` | 调整阈值数值 |
| 应用阈值（未生效） | `arrow.down.circle.fill` | `.accentColor` | 下载/应用 |
| 应用阈值（已生效） | `checkmark.circle.fill` | `.green` | 确认/已应用 |

---

## 5. 基础设置 Tab

| 设置项 | SF Symbol | 颜色 | 说明 |
|--------|-----------|------|------|
| 启用 | `power` | `.accentColor` | 电源开关 |
| 开机自启 | `arrow.up.circle` | `.accentColor` | 启动时自动加载 |

---

## 6. 解锁行为 Tab

| 设置项 | SF Symbol | 颜色 | 说明 |
|--------|-----------|------|------|
| 靠近时唤醒 | `display` | `.accentColor` | 唤醒显示器 |
| 唤醒但不解锁 | `lock.open` | `.accentColor` | 开锁但保持锁定状态 |
| 使用屏保 | `sparkles.tv` | `.accentColor` | 屏保动画效果 |

---

## 7. 锁定行为 Tab

| 设置项 | SF Symbol | 颜色 | 说明 |
|--------|-----------|------|------|
| 暂停媒体 | `pause.circle` | `.accentColor` | 暂停播放 |
| 关闭显示器 | `moon.fill` | `.accentColor` | 休眠/暗色 |
| 延迟锁定 | `keyboard` | `.accentColor` | 输入活动检测 |
| 手动锁后不解锁 | `hand.raised.fill` | `.accentColor` | 手动干预 |

---

## 8. 网络 Tab

| 设置项 | SF Symbol | 颜色 | 说明 |
|--------|-----------|------|------|
| Wi-Fi 暂停 | `wifi` | `.accentColor` | Wi-Fi 连接 |
| 被动模式 | `antenna.radiowaves.left.and.right` | `.accentColor` | 被动监听信号 |

---

## 9. 配置 Tab

| 元素 | SF Symbol | 颜色 | 说明 |
|------|-----------|------|------|
| 配置文件图标 | `folder.badge.gearshape` | `.accentColor` | 带齿轮标记的文件夹 |
| 新建配置 | `plus.circle` | `.accentColor` | 添加新配置 |

---

## 10. 底部固定栏

| 按钮 | SF Symbol | 颜色 | 说明 |
|------|-----------|------|------|
| 立即锁定 | `lock.fill` | `.orange` (tint) | 锁定按钮 |
| 退出 | `power` | `.red` (tint) | 退出应用 |

---

## 11. Toast 通知

| 场景 | SF Symbol | 颜色 | 说明 |
|------|-----------|------|------|
| 蓝牙已连接 | `antenna.radiowaves.left.and.right` | `.green` | 复用天线图标 |
| 蓝牙已断开 | `wifi.slash` | `.orange` | Wi-Fi 断开线 |

**注**：`wifi.slash` 语义上更适合网络断开，BT 断开可改为 `antenna.radiowaves.left.and.right.slash`（需 SF Symbols 3+），保持现有 `wifi.slash` 以确保兼容。

---

## 12. 其他功能按钮

| 按钮 | SF Symbol | 颜色 | 说明 |
|------|-----------|------|------|
| 场景自动化 | `bolt.automation` | `.accentColor` | 自动化闪电 |
| 解锁统计 | `chart.bar` | `.accentColor` | 统计图表 |
| 关于 FUnlock | `info.circle` | `.accentColor` | 信息 |
| 导出诊断 | `square.and.arrow.up` | `.accentColor` | 分享/导出 |

---

## 兼容性说明

- 所有符号均可在 **SF Symbols 1**（macOS 11+）或 **SF Symbols 2**（macOS 12+）中使用
- 目标最低版本 macOS 13+，所有符号完全兼容
- 未使用任何 SF Symbols 3+（macOS 14+）独有的符号
- 颜色统一使用 `Color.accentColor`（蓝色）或 Apple 标准语义色：`.green`、`.orange`、`.red`、`.secondary`

## 与设计文档的差异

| 设计文档原定 | 实际映射 | 原因 |
|-------------|---------|------|
| 总览 tab 用 `clock` | `gauge.medium` | 信号仪表盘语义更贴切 |
| 设备 tab 用 `wifi` | `antenna.radiowaves.left.and.right` | 设备是 BLE 不是 Wi-Fi，避免混淆 |
| 网络 tab 用 `wifi` | `network` | 与设备 tab 图标避免重复 |
