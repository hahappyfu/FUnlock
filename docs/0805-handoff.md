# Handoff — FUnlock「解锁好慢」排查收尾与分支推送（2026-08-05）

## 上下文

- 项目：FUnlock（macOS 蓝牙解锁，Apple Watch 近身自动解锁/离开锁定），SwiftUI + CoreBluetooth
- 分支：`feat/diagnostics-tab`，本地已领先远端 **16 个提交**（2.8.1 ~ 2.8.21），本次会话需推送
- 历史交接文档：`docs/0803handoff.md`、`docs/0804-handoff.md`（本会话之前的背景）
- 工作语言：全程中文；用户要求：**改代码前先说明情况+方案，用户确认后才动手**；每轮改动 git 提交

## 本会话完成内容（已提交，勿重复实现）

| 提交 | 版本 | 内容 |
|------|------|------|
| `39f9874` | 2.8.18 | 走近时解锁爬升区启用 0.5s 快速轮询（FUn.swift `didReadRSSI`） |
| `5837b41` | 2.8.19 | AppleScript 注入回车 `keystroke return` → `key code 36` + 注入级别埋点 |
| `afbdcca` | 2.8.20 | 设备图标按名推断统一（`deviceIconName(for:)` 公共函数） |
| `f3aa885` | 2.8.21 | 时序埋点限流+句柄缓存（FUnlock CPU 40%→4.7%） |

（2.8.1~2.8.16 为更早的菜单重设计/阈值修复系列，见 `git log`）

## 关键诊断结论（本轮核心发现）

**「解锁好慢」= 两层原因，均已修复：**

1. **感知层慢**（走近等几十秒）：走回时采样 8s 间隔 + Kalman 平滑每采样只爬 1-2dB + 解锁门槛写死 `stair=-50`（需贴脸）。实测走回 102 秒才达标。→ 修复 1（2.8.18）：信号进入 `[stair-15, stair)` 爬升区即 0.5s 快速轮询。
2. **注入层回车失效**（密码在框里但不自动解锁）：**重要教训——决策日志的 `unlockSuccess` 是乐观记录（注入即记），不代表真解锁**。铁证：12:16 两次、15:21 一次注入全部 verifyUnlock 失败，均为用户手动解锁。根因：AppleScript `keystroke return` 对登录窗口无效。→ 修复 2（2.8.19）。2.8.19 后 15:35 实测：`keystrokeLevel1=SUCCESS` → `userUnlocked`（系统通知，真解锁）→ 无 unlockFailed。

**证据文件**（运行时产物）：`/tmp/funlock_timing.log`（时序埋点，限流后约 0.9 行/秒）、`~/Library/Logs/FUnlock/decisions.jsonl`（决策）、`shadow_telemetry.csv`（遥测）。

## 未完成 / 可选后续（供下个会话评估）

1. **verifyUnlock 竞态误报**（设计脆弱点）：锁屏时 `CGSessionCopyCurrentDictionary()` 可能返回 nil → 2 秒窗口误报 `unlock=false`。当前靠 `stillLocked=false` 兜底分支（FUnManager.swift tryUnlock 内）救场，但值得修。
2. **可选提速项**（均需用户确认）：
   - Kalman 上升加速（SignalPipeline.swift，Q=0.008/R=0.5，上升时增益 ~0.15）
   - stair 自适应：`max(unlockRSSI+10, -50)`（当前写死 -50，FUn.swift:157）
3. **埋点清理**：2.8.19 起的 `timingLog` 埋点仍在（限流后开销小），"解锁好慢"验证完成且无回归后可移除
4. **未提交文件**：`docs/menu-bar-prototype.html` 是无关注释性改动（旧的菜单原型），推送时**不要**纳入

## 环境事实与惯例（重要）

- 部署流程：PlistBuddy 设版本 → Release 构建 → 320 全量测试 → 部署（quit/pkill/rm -rf/cp -R/codesign -v/open/pgrep）→ 恢复 `CFBundleVersion=1258` → conventional commit
- 测试：`xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' test`；**BLE 集成测试（如 testFullPowerCycle）偶发失败，单独重跑通常通过，与改动无关**
- 推送命令：`unset GITHUB_TOKEN; gh auth switch --user hahappyfu >/dev/null 2>&1; git -c credential.helper='!/opt/homebrew/bin/gh auth git-credential' push github feat/diagnostics-tab`
- 调试通道坑：`/tmp/funlock_debug.log` 永不生成（DebugLog.swift 的 FileHandle 不创建文件，logDebug 全丢）；`/usr/bin/log show` 无输出（权限）；zsh `log` 内建会吞参数需用全路径
- 当前用户阈值：解锁 -65 / 锁定 -85（用户可调，读取以实际为准）

## 建议技能（下个会话）

- `systematic-debugging`：继续 verifyUnlock 竞态或提速项排查（先证据后修复）
- `verification-before-completion`：部署/修复后必须跑测试+看埋点再宣称完成
- `requesting-code-review`：推送前对 16 个提交做一次复查（或直接 `source-command-code-review`）
- `source-command-chinese-git-workflow`：如需处理 GitHub 凭据/推送问题
