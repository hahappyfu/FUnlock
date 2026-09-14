// FUnlockTests/QuotaTests.swift
import XCTest
import SwiftUI
@testable import FUnlock

// 与规格 §4.3 一致的阈值色基准值（#34C759 / #FF9F0A / #FF3B30）
private let quotaGreen = Color(red: 0.204, green: 0.780, blue: 0.349)
private let quotaAmber = Color(red: 1.0, green: 0.624, blue: 0.039)
private let quotaRed = Color(red: 1.0, green: 0.231, blue: 0.188)

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
        XCTAssertEqual(snap.fetchedAt!.timeIntervalSince(baseDate), 0, accuracy: 0.01)
        XCTAssertEqual(snap.windows.map(\.key), ["5h", "weekly", "monthly"])
        let fiveH = snap.windows[0]
        XCTAssertEqual(fiveH.percent, 50, accuracy: 0.001)   // 600/1200 自算，而非缓存的 0
        XCTAssertEqual(fiveH.resetAt!.timeIntervalSince(baseDate), 8931, accuracy: 0.01)
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

    // MARK: - 修复轮次 1：读缓存失败保留旧快照（publish 决策函数）

    /// 读失败（data == nil，对应文件暂不可读/bridge 重写间隙）→ 决策为 nil 即「跳过发布」，refresh 据此保留旧快照不清空
    func testPublishReadFailureKeepsPrevious() {
        XCTAssertNil(QuotaService().publish(nil))
    }

    /// 读到数据但内容无效 → 照常发布 .empty 进无数据态
    func testPublishUnreadableContentStillGoesEmpty() {
        XCTAssertEqual(QuotaService().publish("{broken".data(using: .utf8)), .empty)
    }

    /// 读到合法内容 → 归一化结果正常发布
    func testPublishReadableContentNormalizesNormally() {
        let snap = QuotaService().publish(validJSON)!
        XCTAssertTrue(snap.available)
        XCTAssertEqual(snap.windows.count, 3)
    }

    // MARK: 展示纯函数

    func testQuotaColorThresholdBoundaries() {
        XCTAssertEqual(quotaColor(percent: 0), quotaGreen)
        XCTAssertEqual(quotaColor(percent: 49.9), quotaGreen)
        XCTAssertEqual(quotaColor(percent: 50), quotaAmber)
        XCTAssertEqual(quotaColor(percent: 80), quotaAmber)
        XCTAssertEqual(quotaColor(percent: 80.1), quotaRed)
        XCTAssertEqual(quotaColor(percent: 100), quotaRed)
    }

    func testHumanizeResetThreeTiersFromSeconds() {
        XCTAssertEqual(humanizeReset(8931), "2 小时 29 分后重置")
        XCTAssertEqual(humanizeReset(5059), "1 小时 24 分后重置")
        XCTAssertEqual(humanizeReset(3600), "1 小时后重置")
        XCTAssertEqual(humanizeReset(431_995), "5 天后重置")
        XCTAssertEqual(humanizeReset(40), "1 分钟内重置")
        XCTAssertEqual(humanizeReset(-1), "1 分钟内重置")
    }

    /// 小时分支的分钟进位边界：余数秒 ≥3570 时 rounded() 得 60，必须向小时进位而非渲染「60 分」
    func testHumanizeResetMinuteCarryOverflow() {
        XCTAssertEqual(humanizeReset(7199), "2 小时后重置")     // 1:59:59 → 进位成 2 小时
        XCTAssertEqual(humanizeReset(86399), "24 小时后重置")   // 23:59:59 → 进位成 24 小时（仍走 hours key）
    }

    func testTimeAgoTextFreshnessWording() {
        XCTAssertEqual(timeAgoText(baseDate.addingTimeInterval(-20), now: baseDate), "刚刚更新")
        XCTAssertEqual(timeAgoText(baseDate.addingTimeInterval(-90), now: baseDate), "更新于 1 分钟前")
        XCTAssertEqual(timeAgoText(baseDate.addingTimeInterval(-11 * 60), now: baseDate), "更新于 11 分钟前")
        XCTAssertEqual(timeAgoText(nil, now: baseDate), "暂无更新")
    }
}
