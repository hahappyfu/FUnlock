import XCTest
@testable import FUnlock

@MainActor
final class ThreeStageUnlockIntegrationTests: XCTestCase {
    private var savedKeepAlive: Any?
    private var savedPreferWatch: Any?
    private var savedWatchObserved: Any?
    private var savedWakeOnProx: Any?

    override func setUp() async throws {
        try await super.setUp()
        let defs = ConfigStore.shared.defaults
        savedKeepAlive = defs.object(forKey: "keepAliveWhilePresent")
        savedPreferWatch = defs.object(forKey: "preferNativeWatchUnlock")
        savedWatchObserved = defs.object(forKey: "watchAutoUnlockObserved")
        savedWakeOnProx = defs.object(forKey: "wakeOnProximity")
    }

    override func tearDown() async throws {
        let defs = ConfigStore.shared.defaults
        func restore(_ val: Any?, forKey key: String) {
            if let val { defs.set(val, forKey: key) } else { defs.removeObject(forKey: key) }
        }
        restore(savedKeepAlive, forKey: "keepAliveWhilePresent")
        restore(savedPreferWatch, forKey: "preferNativeWatchUnlock")
        restore(savedWatchObserved, forKey: "watchAutoUnlockObserved")
        restore(savedWakeOnProx, forKey: "wakeOnProximity")
        SecurityService.fetchPasswordOverride = nil
        SystemInteractionService.sessionDictProvider = nil
        SystemInteractionService.frontmostBundleIDProvider = nil
        SystemInteractionService.screensaverRunningProvider = nil
        SystemInteractionService.displayPoweredOnProvider = nil
        SystemInteractionService.injectPasswordOverride = nil
        SystemInteractionService.verifyUnlockOverride = nil
        SystemInteractionService.lockActionOverride = nil
        try await super.tearDown()
    }

    func testConfigStoreDefaultsAndExportableKeysIncludeL0AndL1() {
        XCTAssertTrue(ConfigStore.defaultBool(for: "keepAliveWhilePresent"))
        XCTAssertTrue(ConfigStore.defaultBool(for: "preferNativeWatchUnlock"))
        XCTAssertTrue(ConfigStore.exportableKeys.contains("keepAliveWhilePresent"))
        XCTAssertTrue(ConfigStore.exportableKeys.contains("preferNativeWatchUnlock"))
    }

    func testPowerKeepAliveAdapterRenewsWithin900sAndReleasesOverLimit() {
        var renewCount = 0
        var releaseCount = 0
        let adapter = PowerKeepAliveAdapter(
            renewHandler: { renewCount += 1 },
            releaseHandler: { releaseCount += 1 }
        )

        var engine = EngineState(
            monitoredUUID: UUID(),
            presence: true,
            effectiveRSSI: -55,
            screen: .unlocked,
            systemPower: .awake
        )
        let config = EngineConfig(unlockRSSI: -60, keepAliveWhilePresent: true)
        let t0 = Date(timeIntervalSince1970: 1_000)

        let active1 = adapter.evaluate(state: &engine, idleSeconds: 120, config: config, now: t0)
        XCTAssertTrue(active1)
        XCTAssertEqual(renewCount, 1)
        XCTAssertEqual(releaseCount, 0)

        let active2 = adapter.evaluate(state: &engine, idleSeconds: 905, config: config, now: t0.addingTimeInterval(30))
        XCTAssertFalse(active2)
        XCTAssertEqual(releaseCount, 1)
    }

    func testIdleSleepLatchBlocksPreWakeUntilUnlocked() {
        let fun = FUn()
        fun.presence = true
        fun.unlockRSSI = -60
        fun.updateSmoothedRSSIForTesting(-52)
        let manager = FUnManager(fun: fun)
        ConfigStore.shared.set(true, forKey: "wakeOnProximity")

        manager.onDisplaySleep(idleSeconds: 950)
        XCTAssertTrue(manager.idleSleepLatched)

        manager.onRSSIUpdated(rssi: -52, active: true)
        XCTAssertFalse(manager.orchestrator.displayWakeRequested, "空闲熄屏锁存期禁止信号波动误触预唤醒")

        manager.onUserUnlockedClearLatchForTesting()
        XCTAssertFalse(manager.idleSleepLatched)
    }

    func testL1WatchCooperationSkipsInjectionWhenSessionUnlocksInWindowThenFallsBackToL2OnTimeout() async {
        SystemInteractionService.screensaverRunningProvider = { false }
        SystemInteractionService.displayPoweredOnProvider = { true }
        SystemInteractionService.frontmostBundleIDProvider = { "com.apple.loginwindow" }
        SecurityService.fetchPasswordOverride = { .success("l1-test-pw") }
        defer {
            SecurityService.fetchPasswordOverride = nil
            SystemInteractionService.frontmostBundleIDProvider = nil
        }

        var injectionCalls = 0
        SystemInteractionService.injectPasswordOverride = { _ in
            injectionCalls += 1
            return true
        }
        SystemInteractionService.verifyUnlockOverride = { _, _ in .init(unlock: true) }

        final class TestClock {
            var now: Date
            init(_ now: Date) { self.now = now }
        }
        let clock = TestClock(Date(timeIntervalSince1970: 10_000))
        let fun = FUn()
        fun.presence = true
        fun.unlockRSSI = -60
        fun.updateSmoothedRSSIForTesting(-55)
        let manager = FUnManager(fun: fun, nowProvider: { clock.now })
        manager.lockBufferDuration = 0
        manager.unlockCooldownDuration = 0
        manager.l1WaitDurationForTesting = 0.08
        manager.l1PollIntervalForTesting = 0.02
        ConfigStore.shared.set(true, forKey: "preferNativeWatchUnlock")
        manager.watchAutoUnlockObserved = true
        manager.state.screen = .locked(reason: .away)

        // Scenario 1: Starts locked (call 1..2), then session unlocks natively mid-L1 window -> 0 L2 injections
        var lockReadCount = 0
        SystemInteractionService.sessionDictProvider = {
            lockReadCount += 1
            return ["CGSSessionScreenIsLocked": lockReadCount <= 2 ? 1 : 0]
        }
        await manager.orchestrator.tryUnlock()
        XCTAssertEqual(injectionCalls, 0, "L1 窗口内系统由手表原生解锁时必须零密码注入")

        // Scenario 2: Advance mock clock past 5s debounce, session remains locked past L1 timeout -> L2 runs
        clock.now = clock.now.addingTimeInterval(10)
        manager.state.screen = .locked(reason: .away)
        manager.stateMachine.resetToActive()
        SystemInteractionService.sessionDictProvider = { ["CGSSessionScreenIsLocked": 1] }
        await manager.orchestrator.tryUnlock()
        XCTAssertEqual(injectionCalls, 1, "L1 超时仍未解锁必须自动降级到 L2 密码注入")
    }

    func testNegativeSignalAdapterTriggersFastPollBoost() {
        var receivedSources: [NegativeHintSource] = []
        let adapter = NegativeSignalAdapter { source in
            receivedSources.append(source)
        }
        adapter.emit(.audioOutputDisconnected)
        XCTAssertEqual(receivedSources, [.audioOutputDisconnected])

        let fun = FUn()
        let uuid = UUID()
        fun.startMonitor(uuid: uuid)
        fun.presence = true
        fun.applyNegativeHint(.networkChanged)
        XCTAssertTrue(fun.scheduler.isScheduled(.activePoll))
    }
}
