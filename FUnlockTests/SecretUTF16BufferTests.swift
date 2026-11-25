import XCTest
@testable import FUnlock

final class SecretUTF16BufferTests: XCTestCase {
    func testUTF8ConversionZeroesInputDataStreamsBatchesAndWipesCleanly() throws {
        let original = "p@ss 中文🔐!"
        var raw = Data(original.utf8)
        let expectedUnits = Array(original.utf16)

        let buffer = try XCTUnwrap(SecretUTF16Buffer(utf8Data: &raw))
        XCTAssertTrue(raw.allSatisfy { $0 == 0 }, "构造 SecretUTF16Buffer 后源 UTF-8 Data 必须立即清零")
        XCTAssertEqual(buffer.count, expectedUnits.count)
        XCTAssertFalse(buffer.isWiped)

        var streamed: [UniChar] = []
        let ok = buffer.forEachCGEventBatch(maxUnits: 3) { ptr, count in
            streamed.append(contentsOf: UnsafeBufferPointer(start: ptr, count: count))
            return true
        }
        XCTAssertTrue(ok)
        XCTAssertEqual(streamed, expectedUnits)

        buffer.wipe()
        XCTAssertTrue(buffer.isWiped)
        var invokedAfterWipe = false
        let afterWipe = buffer.forEachCGEventBatch(maxUnits: 3) { _, _ in
            invokedAfterWipe = true
            return true
        }
        XCTAssertFalse(afterWipe)
        XCTAssertFalse(invokedAfterWipe)
    }

    func testPhysicalKeyActivePreemptsInjectionBeforeDispatching() throws {
        var raw = Data("secret123".utf8)
        let buffer = try XCTUnwrap(SecretUTF16Buffer(utf8Data: &raw))
        defer {
            buffer.wipe()
            SystemInteractionService.physicalKeyActiveProvider = nil
        }

        SystemInteractionService.physicalKeyActiveProvider = { true }
        let injected = SystemInteractionService.shared.injectKeyStrokes(buffer, isSecureCheck: { true })
        XCTAssertFalse(injected, "检测到物理按键活动时必须立即熔断按键注入")
    }

    @MainActor
    func testSecurityServiceFetchPasswordBufferRoundTrip() throws {
        let service = SecurityService(serviceName: "com.fuhahah.FUnlock.test.secretbuffer")
        service.deletePassword()
        defer { service.deletePassword() }

        XCTAssertNil(service.storePassword("Buffer#2026"))
        let result = service.fetchPasswordBuffer(warn: false)
        guard case .success(let maybeBuffer) = result else {
            return XCTFail("Expected .success, got \(result)")
        }
        let buffer = try XCTUnwrap(maybeBuffer)
        XCTAssertEqual(buffer.count, "Buffer#2026".utf16.count)
        buffer.wipe()
        XCTAssertTrue(buffer.isWiped)
    }

    func testPresenceKeepAliveCFunctionsAreIdempotentAndCrashFree() {
        funlock_renewPresenceKeepAlive()
        funlock_renewPresenceKeepAlive()
        funlock_releasePresenceKeepAlive()
        funlock_releasePresenceKeepAlive()
    }

    @MainActor
    func testInjectPasswordBufferWithPreludeWipesBufferWhenDisplayAsleepOrKeyPreempted() async throws {
        var raw1 = Data("pw123".utf8)
        let buf1 = try XCTUnwrap(SecretUTF16Buffer(utf8Data: &raw1))
        SystemInteractionService.displayPoweredOnProvider = { false }
        SystemInteractionService.physicalKeyActiveProvider = nil
        defer {
            SystemInteractionService.displayPoweredOnProvider = nil
            SystemInteractionService.physicalKeyActiveProvider = nil
        }
        let task = Task { @MainActor in
            await SystemInteractionService.shared.injectPasswordBufferWithPrelude(buf1, isSecureCheck: { true })
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let ok1 = await task.value
        XCTAssertFalse(ok1)
        XCTAssertTrue(buf1.isWiped, "前奏中止/取消后也必须立即 wipe 缓冲")

        var raw2 = Data("pw456".utf8)
        let buf2 = try XCTUnwrap(SecretUTF16Buffer(utf8Data: &raw2))
        SystemInteractionService.displayPoweredOnProvider = { true }
        SystemInteractionService.physicalKeyActiveProvider = { true }
        let ok2 = await SystemInteractionService.shared.injectPasswordBufferWithPrelude(buf2, isSecureCheck: { true })
        XCTAssertFalse(ok2)
        XCTAssertTrue(buf2.isWiped, "按键抢占中止后也必须立即 wipe 缓冲")
    }
}
