// RangeRailView.swift
// 交互式距离标尺：单根 -95…-30 dBm 校准轨道 + 双拖拽手柄 + 2×2 精密步进器 + 图例 + 脏态应用栏
// 规格：docs/superpowers/specs/2026-11-24-precision-instrument-ui-redesign-spec.md §5

import SwiftUI

// MARK: - 纯几何（可单测，不依赖视图）

enum RangeRailGeometry {
    static var minRSSI: Int { SignalHysteresisEngine.rssiRange.lowerBound }
    static var maxRSSI: Int { SignalHysteresisEngine.rssiRange.upperBound }
    private static var span: Double { Double(maxRSSI - minRSSI) }

    /// 左端 = 远（-95），右端 = 近（-30）
    static func position(forRSSI rssi: Int, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        let clamped = min(max(rssi, minRSSI), maxRSSI)
        return CGFloat(Double(clamped - minRSSI) / span) * width
    }

    static func rssi(forX x: CGFloat, width: CGFloat) -> Int {
        guard width > 0 else { return minRSSI }
        let ratio = Double(min(max(x, 0), width)) / Double(width)
        let value = Double(minRSSI) + ratio * span
        return min(max(Int(value.rounded()), minRSSI), maxRSSI)
    }

    /// 锁定阈值必须先钳范围，再强制 lock < unlock；unlock 为禁用哨兵时不施加序关系
    static func clampLock(_ lock: Int, unlock: Int) -> Int {
        var value = min(max(lock, minRSSI), maxRSSI)
        if unlock != SignalHysteresisEngine.unlockDisabled {
            value = min(value, unlock - 1)
        }
        return min(max(value, minRSSI), maxRSSI)
    }

    /// 解锁阈值变化后的锁定联动：
    /// - 用户手动改过锁定 → 只修正越界，不覆盖用户选择
    /// - 否则按 lockUnlockDelayGap 拉开
    static func linkedLock(forUnlock unlock: Int, currentLock: Int, userModified: Bool) -> Int {
        if unlock == SignalHysteresisEngine.unlockDisabled {
            return clampLock(currentLock, unlock: unlock)
        }
        if userModified {
            return clampLock(currentLock, unlock: unlock)
        }
        return clampLock(unlock - lockUnlockDelayGap, unlock: unlock)
    }

    static func hysteresisGap(lock: Int, unlock: Int) -> Int {
        max(unlock - lock, 0)
    }

    static func isBufferNarrow(lock: Int, unlock: Int) -> Bool {
        hysteresisGap(lock: lock, unlock: unlock) < lockUnlockDelayGap
    }
}

// MARK: - 视图

struct RangeRailView: View {
    var manager: FUnManager

    @State private var draftLock: Int
    @State private var draftUnlock: Int
    @State private var draftWake: Int
    @State private var draftPre: Int
    @State private var unlockEnabled: Bool
    /// 用户是否单独拖动/输入过锁定手柄：true 时解锁联动不再覆盖
    @State private var lockUserModified = false
    @State private var isDragging = false
    @FocusState private var focusedHandle: Handle?

    private enum Handle: Hashable { case lock, unlock }

    private let railHeight: CGFloat = 46
    private let trackHeight: CGFloat = 8
    private let trackTop: CGFloat = 19

    init(manager: FUnManager) {
        self.manager = manager
        let disabled = manager.unlockRSSI == FUn.UNLOCK_DISABLED
        let unlock = disabled ? min(manager.lockRSSI + lockUnlockDelayGap,
                                    SignalHysteresisEngine.rssiRange.upperBound)
                              : manager.unlockRSSI
        _draftLock = State(initialValue: manager.lockRSSI)
        _draftUnlock = State(initialValue: unlock)
        _unlockEnabled = State(initialValue: !disabled)
        _draftWake = State(initialValue: Self.setting("wakeAdvance", default: FUn.defaultWakeAdvance))
        _draftPre = State(initialValue: Self.setting("preUnlockTrigger", default: FUn.defaultPreUnlockTrigger))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FUnlockTheme.Space.sm) {
            rail
            legend
            steppers
            Hairline()
            actionBar
        }
        .onAppear(perform: syncFromStores)
    }

    // MARK: - 轨道

    private var rail: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                track
                zones(width: width)
                offsetTicks(width: width)
                needle(width: width)
                lockHandle(width: width)
                if unlockEnabled {
                    unlockHandle(width: width)
                }
            }
            .coordinateSpace(name: "rail")
        }
        .frame(height: railHeight)
    }

    private var track: some View {
        RoundedRectangle(cornerRadius: trackHeight / 2)
            .fill(FUnlockTheme.Surface.well.color)
            .frame(height: trackHeight)
            .overlay(
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .strokeBorder(FUnlockTheme.Surface.borderStrong.color, lineWidth: 1)
            )
            .offset(y: trackTop)
    }

    private func zones(width: CGFloat) -> some View {
        let lockX = RangeRailGeometry.position(forRSSI: draftLock, width: width)
        let unlockX = unlockEnabled
            ? RangeRailGeometry.position(forRSSI: draftUnlock, width: width)
            : width
        return ZStack(alignment: .leading) {
            Rectangle()
                .fill(FUnlockTheme.State.dangerFill.color.opacity(0.08))
                .frame(width: lockX, height: trackHeight)
            Rectangle()
                .fill(FUnlockTheme.State.amberFill.color.opacity(0.12))
                .frame(width: max(unlockX - lockX, 0), height: trackHeight)
                .offset(x: lockX)
            Rectangle()
                .fill(FUnlockTheme.State.safeFill.color.opacity(0.08))
                .frame(width: max(width - unlockX, 0), height: trackHeight)
                .offset(x: unlockX)
        }
        .frame(width: width, height: trackHeight, alignment: .leading)
        .clipShape(Capsule())
        .offset(y: trackTop)
        .allowsHitTesting(false)
    }

    /// 唤醒提前 / 预解锁触发刻度：两套虚线样式区分，不在轨道上叠文字
    private func offsetTicks(width: CGFloat) -> some View {
        Group {
            if unlockEnabled {
                tick(width: width, value: draftUnlock - draftWake, dash: [4, 3])
                tick(width: width, value: draftUnlock - draftPre, dash: [1, 3])
            }
        }
        .allowsHitTesting(false)
    }

    private func tick(width: CGFloat, value: Int, dash: [CGFloat]) -> some View {
        let x = RangeRailGeometry.position(forRSSI: value, width: width)
        return Path { path in
            path.move(to: CGPoint(x: x, y: trackTop - 4))
            path.addLine(to: CGPoint(x: x, y: trackTop + trackHeight + 4))
        }
        .stroke(FUnlockTheme.Text.tertiary.color, style: StrokeStyle(lineWidth: 1, dash: dash))
    }

    private func needle(width: CGFloat) -> some View {
        Group {
            if let rssi = manager.rssi, rssi >= RangeRailGeometry.minRSSI - 5 {
                let x = RangeRailGeometry.position(forRSSI: rssi, width: width)
                Rectangle()
                    .fill(FUnlockTheme.Text.primary.color)
                    .frame(width: 2, height: trackHeight + 12)
                    .position(x: x, y: trackTop + trackHeight / 2)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - 手柄

    private func lockHandle(width: CGFloat) -> some View {
        let x = RangeRailGeometry.position(forRSSI: draftLock, width: width)
        return handle(.lock, x: x, color: FUnlockTheme.State.dangerFill.color, value: draftLock,
                      label: t("lock"), width: width)
    }

    private func unlockHandle(width: CGFloat) -> some View {
        let x = RangeRailGeometry.position(forRSSI: draftUnlock, width: width)
        return handle(.unlock, x: x, color: FUnlockTheme.State.safeFill.color, value: draftUnlock,
                      label: t("unlock"), width: width)
    }

    private func handle(_ id: Handle, x: CGFloat, color: Color, value: Int,
                        label: String, width: CGFloat) -> some View {
        Capsule()
            .fill(color)
            .frame(width: 14, height: 20)
            .overlay(
                Capsule().strokeBorder(FUnlockTheme.Surface.card.color, lineWidth: 2)
            )
            .overlay(
                Capsule()
                    .strokeBorder(focusedHandle == id ? FUnlockTheme.Accent.base.color : .clear,
                                  lineWidth: 2)
                    .padding(-3)
            )
            .frame(width: 24, height: 32)
            .contentShape(Rectangle())
            .position(x: x, y: trackTop + trackHeight / 2)
            .gesture(dragGesture(id, width: width))
            .focusable()
            .focused($focusedHandle, equals: id)
            .focusEffectDisabled()
            .onKeyPress { press in keyAdjust(press, handle: id) }
            .accessibilityElement()
            .accessibilityLabel(Text(label))
            .accessibilityValue(Text("\(value) dBm"))
            .accessibilityAdjustableAction { direction in
                adjust(id, by: direction == .increment ? 1 : -1)
            }
    }

    private func dragGesture(_ id: Handle, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("rail"))
            .onChanged { drag in
                isDragging = true
                let rssi = RangeRailGeometry.rssi(forX: drag.location.x, width: width)
                switch id {
                case .lock:
                    draftLock = RangeRailGeometry.clampLock(
                        rssi, unlock: unlockEnabled ? draftUnlock : FUn.UNLOCK_DISABLED)
                    lockUserModified = true
                case .unlock:
                    draftUnlock = min(max(rssi, RangeRailGeometry.minRSSI + 1),
                                      RangeRailGeometry.maxRSSI)
                    draftLock = RangeRailGeometry.linkedLock(forUnlock: draftUnlock,
                                                             currentLock: draftLock,
                                                             userModified: lockUserModified)
                }
            }
            .onEnded { _ in isDragging = false }
    }

    private func keyAdjust(_ press: KeyPress, handle id: Handle) -> KeyPress.Result {
        let step = press.modifiers.contains(.shift) ? 5 : 1
        switch press.key {
        case .leftArrow:
            adjust(id, by: -step)
            return .handled
        case .rightArrow:
            adjust(id, by: step)
            return .handled
        case .home:
            setValue(id, to: id == .lock
                     ? RangeRailGeometry.minRSSI
                     : RangeRailGeometry.minRSSI + 1)
            return .handled
        case .end:
            setValue(id, to: id == .lock
                     ? (unlockEnabled ? draftUnlock - 1 : RangeRailGeometry.maxRSSI)
                     : RangeRailGeometry.maxRSSI)
            return .handled
        default:
            return .ignored
        }
    }

    private func adjust(_ id: Handle, by delta: Int) {
        let target = (id == .lock ? draftLock : draftUnlock) + delta
        setValue(id, to: target)
    }

    private func setValue(_ id: Handle, to value: Int) {
        switch id {
        case .lock:
            draftLock = RangeRailGeometry.clampLock(
                value, unlock: unlockEnabled ? draftUnlock : FUn.UNLOCK_DISABLED)
            lockUserModified = true
        case .unlock:
            let clamped = min(max(value, RangeRailGeometry.minRSSI + 1), RangeRailGeometry.maxRSSI)
            draftUnlock = clamped
            draftLock = RangeRailGeometry.linkedLock(forUnlock: clamped,
                                                     currentLock: draftLock,
                                                     userModified: lockUserModified)
        }
    }

    // MARK: - 图例

    private var legend: some View {
        HStack(spacing: FUnlockTheme.Space.sm) {
            legendItem(color: FUnlockTheme.State.dangerFill.color, text: t("lock"))
            legendItem(color: FUnlockTheme.State.amberFill.color, text: t("hysteresis_band"))
            legendItem(color: FUnlockTheme.State.safeFill.color, text: t("unlock"))
            HStack(spacing: 4) {
                Rectangle()
                    .fill(FUnlockTheme.Text.primary.color)
                    .frame(width: 2, height: 10)
                Text(manager.rssi.map { "\($0) dBm" } ?? "-- dBm")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(FUnlockTheme.Text.secondary.color)
            }
            Spacer(minLength: 0)
            if unlockEnabled && RangeRailGeometry.isBufferNarrow(lock: draftLock, unlock: draftUnlock) {
                Label("\(RangeRailGeometry.hysteresisGap(lock: draftLock, unlock: draftUnlock)) dB",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(FUnlockTheme.State.dangerText.color)
                    .help(t("hysteresis_band"))
            }
        }
        .font(.caption2)
    }

    private func legendItem(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .foregroundStyle(FUnlockTheme.Text.secondary.color)
        }
    }

    // MARK: - 步进器

    private var steppers: some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                            GridItem(.flexible(), alignment: .leading)],
                  alignment: .leading,
                  spacing: FUnlockTheme.Space.sm) {
            stepperCell(title: t("lock"), value: draftLock,
                        range: RangeRailGeometry.minRSSI...(-31), unit: "dBm") { next in
                setValue(.lock, to: next)
            }
            if unlockEnabled {
                stepperCell(title: t("unlock"), value: draftUnlock,
                            range: (RangeRailGeometry.minRSSI + 1)...RangeRailGeometry.maxRSSI,
                            unit: "dBm") { next in
                    setValue(.unlock, to: next)
                }
            } else {
                disabledUnlockCell
            }
            stepperCell(title: t("wake_advance"), value: draftWake,
                        range: SignalHysteresisEngine.offsetRange, unit: "dB",
                        detail: unlockEnabled ? "→ \(draftUnlock - draftWake) dBm" : nil) { next in
                draftWake = next
            }
            stepperCell(title: t("pre_unlock_trigger"), value: draftPre,
                        range: SignalHysteresisEngine.offsetRange, unit: "dB",
                        detail: unlockEnabled ? "→ \(draftUnlock - draftPre) dBm" : nil) { next in
                draftPre = next
            }
        }
    }

    private func stepperCell(title: String, value: Int, range: ClosedRange<Int>,
                             unit: String, detail: String? = nil,
                             onSet: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(FUnlockTheme.Text.secondary.color)
            HStack(spacing: 4) {
                stepButton("minus") { onSet(max(value - 1, range.lowerBound)) }
                TextField("", value: Binding(
                    get: { value },
                    set: { onSet(min(max($0, range.lowerBound), range.upperBound)) }
                ), format: .number)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .font(.body.monospacedDigit())
                    .frame(width: 52)
                    .precisionField()
                stepButton("plus") { onSet(min(value + 1, range.upperBound)) }
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(FUnlockTheme.Text.tertiary.color)
            }
            if let detail {
                Text(detail)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(FUnlockTheme.Text.tertiary.color)
            }
        }
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption2.weight(.bold))
                .foregroundStyle(FUnlockTheme.Text.secondary.color)
                .frame(width: 22, height: 24)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: FUnlockTheme.Radius.sm)
                        .fill(FUnlockTheme.Surface.well.color)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: FUnlockTheme.Radius.sm)
                        .strokeBorder(FUnlockTheme.Surface.border.color, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(symbol == "plus" ? "+" : "−"))
    }

    private var disabledUnlockCell: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t("unlock"))
                .font(.caption)
                .foregroundStyle(FUnlockTheme.Text.secondary.color)
            HStack(spacing: 6) {
                Text(t("disabled"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(FUnlockTheme.Text.secondary.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(FUnlockTheme.Surface.well.color))
                    .overlay(Capsule().strokeBorder(FUnlockTheme.Surface.borderStrong.color, lineWidth: 1))
                InstrumentButton(title: t("enabled"), kind: .secondary, action: enableUnlock)
            }
        }
    }

    private func enableUnlock() {
        unlockEnabled = true
        draftUnlock = min(max(draftLock + lockUnlockDelayGap, RangeRailGeometry.minRSSI + 1),
                          RangeRailGeometry.maxRSSI)
        draftLock = RangeRailGeometry.clampLock(draftLock, unlock: draftUnlock)
        lockUserModified = false
    }

    // MARK: - 脏态应用栏

    private var actionBar: some View {
        HStack(spacing: FUnlockTheme.Space.xs) {
            Text(t("distance_threshold"))
                .font(.caption)
                .foregroundStyle(FUnlockTheme.Text.tertiary.color)
            Spacer(minLength: 0)
            InstrumentButton(title: t("cancel"), kind: .ghost, isEnabled: !isApplied,
                             action: revert)
            InstrumentButton(title: isApplied ? t("applied") : t("apply_thresholds"),
                             systemImage: isApplied ? "checkmark" : nil,
                             kind: .primary, isEnabled: !isApplied, action: apply)
        }
    }

    private var isApplied: Bool {
        let unlockMatches = unlockEnabled
            ? manager.unlockRSSI == draftUnlock
            : manager.unlockRSSI == FUn.UNLOCK_DISABLED
        return unlockMatches
            && manager.lockRSSI == draftLock
            && Self.setting("wakeAdvance", default: FUn.defaultWakeAdvance) == draftWake
            && Self.setting("preUnlockTrigger", default: FUn.defaultPreUnlockTrigger) == draftPre
    }

    // MARK: - 读写

    private func apply() {
        // 顺序与既有导入路径一致：unlock 先写（内部可能联动 lock），再以用户锁定值覆盖
        manager.setUnlockRSSI(unlockEnabled ? draftUnlock : FUn.UNLOCK_DISABLED)
        manager.setLockRSSI(draftLock)
        manager.setWakeAdvance(draftWake)
        manager.setPreUnlockTrigger(draftPre)
        lockUserModified = false
        syncFromStores()
    }

    private func revert() {
        syncFromStores()
    }

    private func syncFromStores() {
        let disabled = manager.unlockRSSI == FUn.UNLOCK_DISABLED
        unlockEnabled = !disabled
        draftLock = manager.lockRSSI
        draftUnlock = disabled
            ? min(max(draftLock + lockUnlockDelayGap, RangeRailGeometry.minRSSI + 1),
                  RangeRailGeometry.maxRSSI)
            : manager.unlockRSSI
        draftWake = Self.setting("wakeAdvance", default: FUn.defaultWakeAdvance)
        draftPre = Self.setting("preUnlockTrigger", default: FUn.defaultPreUnlockTrigger)
        lockUserModified = false
    }

    private static func setting(_ key: String, default fallback: Int) -> Int {
        SignalHysteresisEngine.clampOffset(ConfigStore.shared.object(forKey: key) as? Int ?? fallback)
    }
}
