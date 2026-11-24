// MenuTabRoutingTests.swift
// 锁定 7 → 4 分区的兼容路由：新 key 与旧 key 都不得静默失效

import XCTest
@testable import FUnlock

final class MenuTabRoutingTests: XCTestCase {

    func testRawValues() {
        XCTAssertEqual(MenuTab.overview.rawValue, "overview")
        XCTAssertEqual(MenuTab.behavior.rawValue, "behavior")
        XCTAssertEqual(MenuTab.scenarios.rawValue, "scenarios")
        XCTAssertEqual(MenuTab.diagnostics.rawValue, "diagnostics")
    }

    func testAllCasesOrder() {
        XCTAssertEqual(MenuTab.allCases, [.overview, .behavior, .scenarios, .diagnostics])
    }

    func testResolveNewKeys() {
        XCTAssertEqual(MenuTab.resolve("overview"), .overview)
        XCTAssertEqual(MenuTab.resolve("behavior"), .behavior)
        XCTAssertEqual(MenuTab.resolve("scenarios"), .scenarios)
        XCTAssertEqual(MenuTab.resolve("diagnostics"), .diagnostics)
    }

    func testResolveLegacyBehaviorKeys() {
        for key in ["basic", "unlock", "lock"] {
            XCTAssertEqual(MenuTab.resolve(key), .behavior, "旧 key \(key) 应路由到行为与通知")
        }
    }

    func testResolveLegacyScenarioKeys() {
        for key in ["network", "config"] {
            XCTAssertEqual(MenuTab.resolve(key), .scenarios, "旧 key \(key) 应路由到场景与配置")
        }
    }

    func testResolveUnknownReturnsNil() {
        XCTAssertNil(MenuTab.resolve(""))
        XCTAssertNil(MenuTab.resolve("settings"))
        XCTAssertNil(MenuTab.resolve("OVERVIEW"))
    }

    func testResolveRoundTripsEveryCase() {
        for tab in MenuTab.allCases {
            XCTAssertEqual(MenuTab.resolve(tab.rawValue), tab)
        }
    }

    /// 诊断页 `.goToTab` 与外部 DistributedNotification 依赖的旧 key 全集
    func testAllLegacyTabKeysStillRoute() {
        let legacy = ["basic", "unlock", "lock", "network", "config"]
        for key in legacy {
            XCTAssertNotNil(MenuTab.resolve(key), "旧入口 \(key) 不得变成死链")
        }
    }
}
