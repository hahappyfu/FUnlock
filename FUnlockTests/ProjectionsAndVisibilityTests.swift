import XCTest
@testable import FUnlock

@MainActor
final class ProjectionsAndVisibilityTests: XCTestCase {
    func testSignalDataStoreRecordSnapshotAndClearWorkSynchronouslyWithoutTimer() {
        let store = SignalDataStore.shared
        store.clear()
        XCTAssertTrue(store.snapshot().isEmpty)

        store.record(
            rawRSSI: -58,
            kalmanEstimate: -59.2,
            effectiveRSSI: -59.0,
            slope: -0.4,
            isAnomalous: false,
            event: nil
        )
        let snap = store.snapshot()
        XCTAssertEqual(snap.count, 1)
        XCTAssertEqual(snap.first?.rawRSSI, -58)
        XCTAssertEqual(store.samples.count, 1)

        store.clear()
        XCTAssertTrue(store.snapshot().isEmpty)
    }

    func testLiveSignalProjectionSuppressesUpdatesWhileHiddenAndSyncsWhenVisible() {
        let store = SignalDataStore.shared
        store.clear()
        store.record(rawRSSI: -52, kalmanEstimate: -52, effectiveRSSI: -52, slope: 0, isAnomalous: false)

        let projection = LiveSignalProjection()
        XCTAssertFalse(projection.isVisible)

        projection.ingestRSSI(-48, smoothed: -49)
        XCTAssertNil(projection.rssi, "窗口不可见时不应刷新 live 信号投影")

        projection.setVisible(true, store: store, currentRSSI: -48, smoothedRSSI: -49)
        XCTAssertTrue(projection.isVisible)
        XCTAssertEqual(projection.rssi, -48)
        XCTAssertEqual(projection.smoothedRSSI, -49)
        XCTAssertEqual(projection.samples.count, 1)

        projection.ingestRSSI(-45, smoothed: -46)
        XCTAssertEqual(projection.rssi, -45)

        projection.setVisible(false, store: store)
        XCTAssertFalse(projection.isVisible)
        store.clear()
    }

    func testStatusProjectionSyncsDiscreteStateFromManager() {
        let fun = FUn()
        let manager = FUnManager(fun: fun)
        let projection = StatusProjection()

        manager.monitoredDeviceName = "Apple Watch"
        manager.updateConnected(true)
        manager.state.screen = .locked(reason: .away)
        projection.sync(from: manager)

        XCTAssertEqual(projection.monitoredDeviceName, "Apple Watch")
        XCTAssertTrue(projection.connected)
        XCTAssertEqual(projection.screenState, .locked(reason: .away))
    }
}
