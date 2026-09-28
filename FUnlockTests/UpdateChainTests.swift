// UpdateDownloader/UpdateInstaller 更新链测试(Wave 2 Agent A 填充)
import XCTest
@testable import FUnlock

/// 更新链单元测试:URL/临时目录构造、bundleId 防换装校验、TeamId 解析、
/// 安装脚本结构、semver 比较、delegate 进度/失败回调与 24h 节流。
/// 只测纯逻辑与 delegate 回调,不发真实网络请求、不执行安装脚本。
@MainActor
final class UpdateChainTests: XCTestCase {

    // MARK: - UpdateDownloader.makeDownloadURL

    func testMakeDownloadURLBuildsGitHubReleaseURL() {
        let url = UpdateDownloader.makeDownloadURL(version: "1.2.3")
        XCTAssertEqual(
            url.absoluteString,
            "https://github.com/hahappyfu/FUnlock/releases/download/v1.2.3/FUnlock.zip"
        )
    }

    // MARK: - UpdateDownloader.makeUpdateDirectory

    func testMakeUpdateDirectoryIsUniquePrivateTempPath() {
        let a = UpdateDownloader.makeUpdateDirectory()
        let b = UpdateDownloader.makeUpdateDirectory()
        XCTAssertTrue(a.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        XCTAssertTrue(a.lastPathComponent.hasPrefix("FUnlock-update-"))
        XCTAssertNotEqual(a, b, "每次调用必须是独立 UUID 目录")
    }

    func testMakeUpdateDirectoryIsCreatable() throws {
        let dir = UpdateDownloader.makeUpdateDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    // MARK: - UpdateDownloader.bundleIdMatches(防恶意换装校验)

    /// 在临时目录造一个假 app bundle(Contents/Info.plist),返回 app 路径
    private func makeFakeApp(bundleId: String?) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateChainTests-\(UUID().uuidString)", isDirectory: true)
        let appDir = root.appendingPathComponent("FUnlock.app", isDirectory: true)
        let contents = appDir.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var plist: [String: Any] = [:]
        if let bundleId { plist["CFBundleIdentifier"] = bundleId }
        try (plist as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return appDir
    }

    func testBundleIdMatchesAcceptsCaseInsensitiveMatch() throws {
        let app = try makeFakeApp(bundleId: "COM.FUHAHAH.FUNLOCK")
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        XCTAssertTrue(UpdateDownloader.bundleIdMatches(expected: "com.fuhahah.Funlock", plistURL: plistURL))
    }

    func testBundleIdMatchesRejectsDifferentBundleId() throws {
        let app = try makeFakeApp(bundleId: "com.evil.hijack")
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        XCTAssertFalse(UpdateDownloader.bundleIdMatches(expected: "com.fuhahah.Funlock", plistURL: plistURL))
    }

    func testBundleIdMatchesRejectsMissingPlist() {
        XCTAssertFalse(UpdateDownloader.bundleIdMatches(
            expected: "com.fuhahah.Funlock",
            plistURL: URL(fileURLWithPath: "/nonexistent/UpdateChainTests/Info.plist")
        ))
    }

    func testBundleIdMatchesRejectsPlistWithoutBundleIdKey() throws {
        let app = try makeFakeApp(bundleId: nil)
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        XCTAssertFalse(UpdateDownloader.bundleIdMatches(expected: "com.fuhahah.Funlock", plistURL: plistURL))
    }

    // MARK: - UpdateDownloader delegate 回调(进度 / 失败)

    func testDidWriteDataReportsProgress() {
        let downloader = UpdateDownloader()
        var states: [UpdateDownloader.State] = []
        let exp = expectation(description: "progress state fires")
        downloader.onStateChange = { state in
            states.append(state)
            if case .downloading = state { exp.fulfill() }
        }
        downloader.urlSession(.shared, downloadTask: URLSessionDownloadTask(),
                              didWriteData: 50, totalBytesWritten: 50, totalBytesExpectedToWrite: 100)
        wait(for: [exp], timeout: 2)
        guard case .downloading(let progress) = states.first else {
            return XCTFail("期望 .downloading,实际 \(states)")
        }
        XCTAssertEqual(progress, 0.5, accuracy: 0.0001)
    }

    func testDidWriteDataIgnoresZeroExpectedBytes() {
        let downloader = UpdateDownloader()
        let exp = expectation(description: "totalBytesExpectedToWrite=0 不应发状态")
        exp.isInverted = true
        downloader.onStateChange = { _ in exp.fulfill() }
        downloader.urlSession(.shared, downloadTask: URLSessionDownloadTask(),
                              didWriteData: 50, totalBytesWritten: 50, totalBytesExpectedToWrite: 0)
        wait(for: [exp], timeout: 0.3)
    }

    func testDidCompleteWithErrorReportsFailure() {
        let downloader = UpdateDownloader()
        var states: [UpdateDownloader.State] = []
        let exp = expectation(description: "failed state fires")
        downloader.onStateChange = { state in
            states.append(state)
            exp.fulfill()
        }
        let error = NSError(domain: "UpdateChainTests", code: 42,
                            userInfo: [NSLocalizedDescriptionKey: "网络中断"])
        downloader.urlSession(.shared, task: URLSessionTask(), didCompleteWithError: error)
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(states.first, .failed("网络中断"))
    }

    func testDidCompleteWithoutErrorEmitsNothing() {
        let downloader = UpdateDownloader()
        let exp = expectation(description: "无 error 的完成回调不应发状态")
        exp.isInverted = true
        downloader.onStateChange = { _ in exp.fulfill() }
        downloader.urlSession(.shared, task: URLSessionTask(), didCompleteWithError: nil)
        wait(for: [exp], timeout: 0.3)
    }

    // MARK: - UpdateInstaller.parseTeamId

    func testParseTeamIdExtractsFromCodesignOutput() {
        let output = """
        Executable=/tmp/FUnlock.app/Contents/MacOS/FUnlock
        Identifier=com.fuhahah.Funlock
        Format=app bundle with Mach-O thin (arm64)
        CodeDirectory v=20500 size=1234 flags=0x10000(runtime) hashes=10+5 location=embedded
        TeamIdentifier=ABC123XYZ9
        """
        XCTAssertEqual(UpdateInstaller.parseTeamId(fromOutput: output), "ABC123XYZ9")
    }

    func testParseTeamIdReturnsNilWhenLineMissing() {
        XCTAssertNil(UpdateInstaller.parseTeamId(fromOutput: "Identifier=com.foo\nHashes=123"))
    }

    func testParseTeamIdReturnsNilForWhitespaceOnlyValue() {
        // 空值守卫的真实可达路径:纯空白值 trim 后为空 → nil
        XCTAssertNil(UpdateInstaller.parseTeamId(fromOutput: "TeamIdentifier=   "))
    }

    func testParseTeamIdReturnsNilForBareEquals() {
        // 修复(2026-09-28):"TeamIdentifier="(空值)必须返回 nil——此前 split 丢弃末尾空段
        // 使 .last 取到标签串 "TeamIdentifier",两侧都未签名时会双空比较误报匹配
        XCTAssertNil(UpdateInstaller.parseTeamId(fromOutput: "TeamIdentifier="))
    }

    func testParseTeamIdTrimsWhitespace() {
        XCTAssertEqual(UpdateInstaller.parseTeamId(fromOutput: "TeamIdentifier=  ABC123  "), "ABC123")
    }

    // MARK: - UpdateInstaller.makeInstallScript(只断言脚本结构,不执行)

    func testMakeInstallScriptStagesAtomicSwapAndCleansUp() throws {
        let appPath = URL(fileURLWithPath: "/tmp/FUnlock-update-abc/FUnlock.app")
        let script = UpdateInstaller.makeInstallScript(appPath: appPath)

        XCTAssertTrue(script.hasPrefix("#!/bin/bash"))
        XCTAssertTrue(script.contains("APP=\"/Applications/FUnlock.app\""))
        XCTAssertTrue(script.contains("STAGING=\"/Applications/FUnlock.app.staging\""))
        XCTAssertTrue(script.contains("UPDATE=\"\(appPath.path)\""))
        // 原子替换顺序:先复制到 staging,复制成功后才允许删除旧版
        let cpRange = try XCTUnwrap(script.range(of: "cp -R \"$UPDATE\" \"$STAGING\""))
        let rmAppRange = try XCTUnwrap(script.range(of: "rm -rf \"$APP\""))
        XCTAssertLessThan(cpRange.lowerBound, rmAppRange.lowerBound, "必须先复制到 staging 再删除旧版")
        XCTAssertTrue(script.contains("mv \"$STAGING\" \"$APP\""))
        XCTAssertTrue(script.contains("open \"$APP\""))
        XCTAssertTrue(script.contains("rm -rf \"\(appPath.deletingLastPathComponent().path)\""))
    }

    // MARK: - UpdateChecker.compareVersions(semver 新版本判定)

    func testCompareVersionsSameVersionIsOrderedSame() {
        XCTAssertEqual(UpdateChecker.compareVersions("1.2.3", "1.2.3"), .orderedSame)
    }

    func testCompareVersionsHigherPatchIsDescending() {
        XCTAssertEqual(UpdateChecker.compareVersions("1.2.4", "1.2.3"), .orderedDescending)
        XCTAssertEqual(UpdateChecker.compareVersions("1.2.3", "1.2.4"), .orderedAscending)
    }

    func testCompareVersionsIsNumericNotLexicographic() {
        XCTAssertEqual(UpdateChecker.compareVersions("1.10.0", "1.9.0"), .orderedDescending)
        XCTAssertEqual(UpdateChecker.compareVersions("0.9", "0.10"), .orderedAscending)
    }

    func testCompareVersionsPadsMissingComponentsWithZero() {
        XCTAssertEqual(UpdateChecker.compareVersions("1.2", "1.2.0"), .orderedSame)
        XCTAssertEqual(UpdateChecker.compareVersions("1.2.1", "1.2"), .orderedDescending)
    }

    func testCompareVersionsDropsNonNumericComponents() {
        // 行为锚定:非数字段被整段丢弃("3-beta" 不是 Int),"1.2.3-beta" 只剩 [1,2],
        // 少一段按 0 补齐,故比 "1.2.3" 小(带 prerelease 后缀的 tag 视为旧版)
        XCTAssertEqual(UpdateChecker.compareVersions("1.2.3-beta", "1.2.3"), .orderedAscending)
    }

    // MARK: - UpdateChecker.check() 24h 节流

    func testCheckThrottledWithin24hDoesNotNotify() throws {
        let suiteName = "UpdateChainTests.checkThrottle.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")

        let checker = UpdateChecker(defaults: defaults)
        let exp = expectation(description: "24h 内不应触发新版本回调")
        exp.isInverted = true
        checker.onNewVersion = { _ in exp.fulfill() }
        checker.check()
        wait(for: [exp], timeout: 0.5)
    }
}
