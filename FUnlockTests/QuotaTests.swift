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
}
