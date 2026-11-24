// PrecisionThemeTests.swift
// Phase 1 TDD：状态语义契约 + Theme Token 尺度 + 明暗动态色

import XCTest
import AppKit
@testable import FUnlock

final class PrecisionThemeTests: XCTestCase {

    // MARK: - StatusPresentation.resolve（6 种组合）

    func testUnlockedResolvesToSafe() {
        let p = StatusPresentation.resolve(screen: .unlocked, connected: true, hasDevice: true)
        XCTAssertEqual(p.tone, .safe)
        XCTAssertEqual(p.titleKey, "mb_unlocked")
        XCTAssertEqual(p.icon, "lock.open.fill")
        XCTAssertNil(p.detailKey)
    }

    func testLockedConnectedResolvesToAmber() {
        let p = StatusPresentation.resolve(screen: .locked(reason: .manual), connected: true, hasDevice: true)
        XCTAssertEqual(p.tone, .amber)
        XCTAssertEqual(p.titleKey, "mb_locked")
        XCTAssertEqual(p.icon, "lock.fill")
    }

    func testLockedDisconnectedResolvesToDanger() {
        let p = StatusPresentation.resolve(screen: .locked(reason: .lost), connected: false, hasDevice: true)
        XCTAssertEqual(p.tone, .danger)
        XCTAssertEqual(p.titleKey, "mb_disconnected")
    }

    func testScreensaverIsStandbyNeutral() {
        let p = StatusPresentation.resolve(screen: .screensaver, connected: true, hasDevice: true)
        XCTAssertEqual(p.tone, .neutral)
        XCTAssertEqual(p.titleKey, "status_standby")
        XCTAssertEqual(p.detailKey, "status_screensaver")
        XCTAssertEqual(p.icon, "moon.zzz.fill")
    }

    func testDisplaySleepingIsStandbyNeutral() {
        let p = StatusPresentation.resolve(screen: .displaySleeping, connected: true, hasDevice: true)
        XCTAssertEqual(p.tone, .neutral)
        XCTAssertEqual(p.titleKey, "status_standby")
        XCTAssertEqual(p.detailKey, "status_display_sleeping")
        XCTAssertEqual(p.icon, "moon.zzz.fill")
    }

    func testNoDeviceIsNeutral() {
        let p = StatusPresentation.resolve(screen: .unlocked, connected: false, hasDevice: false)
        XCTAssertEqual(p.tone, .neutral)
        XCTAssertEqual(p.titleKey, "no_device")
    }

    func testStandbyParityBetweenScreensaverAndDisplaySleeping() {
        let a = StatusPresentation.resolve(screen: .screensaver, connected: true, hasDevice: true)
        let b = StatusPresentation.resolve(screen: .displaySleeping, connected: true, hasDevice: true)
        XCTAssertEqual(a.tone, b.tone, "屏保与息屏必须同色，不得一个灰一个橙")
        XCTAssertEqual(a.icon, b.icon)
        XCTAssertEqual(a.titleKey, b.titleKey)
        XCTAssertNotEqual(a.detailKey, b.detailKey, "详情文案仍应能区分两种待机原因")
    }

    // MARK: - 尺度 token

    func testRadiusScale() {
        XCTAssertEqual(FUnlockTheme.Radius.sm, 6)
        XCTAssertEqual(FUnlockTheme.Radius.md, 10)
        XCTAssertEqual(FUnlockTheme.Radius.lg, 12)
        XCTAssertEqual(FUnlockTheme.Radius.pill, 9999)
    }

    func testSpaceScale() {
        XCTAssertEqual(FUnlockTheme.Space.xxs, 4)
        XCTAssertEqual(FUnlockTheme.Space.xs, 8)
        XCTAssertEqual(FUnlockTheme.Space.sm, 12)
        XCTAssertEqual(FUnlockTheme.Space.md, 16)
        XCTAssertEqual(FUnlockTheme.Space.lg, 20)
        XCTAssertEqual(FUnlockTheme.Space.xl, 24)
    }

    // MARK: - 动态色（Light / Dark）

    private struct RGB: Equatable {
        let r: Int, g: Int, b: Int
        init(_ hex: UInt32) {
            r = Int((hex >> 16) & 0xFF)
            g = Int((hex >> 8) & 0xFF)
            b = Int(hex & 0xFF)
        }
    }

    private var aqua: NSAppearance { NSAppearance(named: .aqua)! }
    private var darkAqua: NSAppearance { NSAppearance(named: .darkAqua)! }

    private func rgb(_ color: NSColor, file: StaticString = #filePath, line: UInt = #line) -> RGB {
        guard let c = color.usingColorSpace(.sRGB) else {
            XCTFail("无法转换为 sRGB", file: file, line: line)
            return RGB(0)
        }
        return RGB(UInt32((c.redComponent * 255).rounded()) << 16
                 | UInt32((c.greenComponent * 255).rounded()) << 8
                 | UInt32((c.blueComponent * 255).rounded()))
    }

    func testCanvasResolvesToSpecHex() {
        XCTAssertEqual(rgb(FUnlockTheme.Surface.canvas.resolved(aqua)), RGB(0xF4F6F8))
        XCTAssertEqual(rgb(FUnlockTheme.Surface.canvas.resolved(darkAqua)), RGB(0x0D1117))
    }

    func testAccentResolvesToSpecHex() {
        XCTAssertEqual(rgb(FUnlockTheme.Accent.base.resolved(aqua)), RGB(0x0369A1))
        XCTAssertEqual(rgb(FUnlockTheme.Accent.base.resolved(darkAqua)), RGB(0x38BDF8))
        XCTAssertEqual(rgb(FUnlockTheme.Accent.onAccent.resolved(aqua)), RGB(0xFFFFFF))
        XCTAssertEqual(rgb(FUnlockTheme.Accent.onAccent.resolved(darkAqua)), RGB(0x082F49))
    }

    func testCoreSurfaceTokensDifferBetweenAppearances() {
        let tokens: [(String, FUnlockTheme.DynamicToken)] = [
            ("canvas", FUnlockTheme.Surface.canvas),
            ("sidebar", FUnlockTheme.Surface.sidebar),
            ("card", FUnlockTheme.Surface.card),
            ("well", FUnlockTheme.Surface.well),
            ("border", FUnlockTheme.Surface.border),
            ("textPrimary", FUnlockTheme.Text.primary),
            ("textSecondary", FUnlockTheme.Text.secondary),
        ]
        for (name, token) in tokens {
            XCTAssertNotEqual(rgb(token.resolved(aqua)), rgb(token.resolved(darkAqua)),
                              "\(name) 必须随外观切换")
        }
    }

    func testTextPrimaryResolvesToSpecHex() {
        XCTAssertEqual(rgb(FUnlockTheme.Text.primary.resolved(aqua)), RGB(0x0F172A))
        XCTAssertEqual(rgb(FUnlockTheme.Text.primary.resolved(darkAqua)), RGB(0xF1F5F9))
        XCTAssertEqual(rgb(FUnlockTheme.Text.secondary.resolved(aqua)), RGB(0x475569))
        XCTAssertEqual(rgb(FUnlockTheme.Text.secondary.resolved(darkAqua)), RGB(0x94A3B8))
    }

    func testStateTokensResolveToSpecHex() {
        XCTAssertEqual(rgb(FUnlockTheme.State.safeText.resolved(aqua)), RGB(0x15803D))
        XCTAssertEqual(rgb(FUnlockTheme.State.safeFill.resolved(aqua)), RGB(0x16A34A))
        XCTAssertEqual(rgb(FUnlockTheme.State.amberText.resolved(aqua)), RGB(0xB45309))
        XCTAssertEqual(rgb(FUnlockTheme.State.amberFill.resolved(aqua)), RGB(0xD97706))
        XCTAssertEqual(rgb(FUnlockTheme.State.dangerText.resolved(aqua)), RGB(0xDC2626))
        XCTAssertEqual(rgb(FUnlockTheme.State.safeText.resolved(darkAqua)), RGB(0x22C55E))
        XCTAssertEqual(rgb(FUnlockTheme.State.amberText.resolved(darkAqua)), RGB(0xF59E0B))
        XCTAssertEqual(rgb(FUnlockTheme.State.dangerText.resolved(darkAqua)), RGB(0xF87171))
    }
}
