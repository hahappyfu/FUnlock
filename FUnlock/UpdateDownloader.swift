import Foundation

/// @unchecked Sendable 依据：任务与状态回调仅在主队列访问（delegateQueue = .main）
final class UpdateDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    enum State: Equatable {
        case idle
        case downloading(progress: Double)
        case completed(URL)   // 解压后的 FUnlock.app 路径
        case failed(String)   // 错误描述
    }

    var onStateChange: ((State) -> Void)?

    private var downloadTask: URLSessionDownloadTask?
    private var session: URLSession?
    private var tempDir: URL = UpdateDownloader.makeUpdateDirectory()
    private var targetVersion: String = ""

    enum DownloadError: LocalizedError {
        case unzipFailed
        case bundleIdMismatch
        case appNotFound

        var errorDescription: String? {
            switch self {
            case .unzipFailed: return "解压失败"
            case .bundleIdMismatch: return "Bundle ID 不匹配"
            case .appNotFound: return "FUnlock.app 未找到"
            }
        }
    }

    // MARK: - 纯函数（供单元测试）

    static func makeDownloadURL(version: String) -> URL {
        URL(string: "https://github.com/hahappyfu/FUnlock/releases/download/v\(version)/FUnlock.zip")!
    }

    /// 私有临时目录：每次调用独立 UUID，避免固定路径竞态与多用户权限漏洞
    static func makeUpdateDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("FUnlock-update-\(UUID().uuidString)")
    }

    /// 校验解压后 app 的 Bundle ID 与当前运行实例一致（防恶意换装）
    static func bundleIdMatches(expected: String, plistURL: URL) -> Bool {
        guard let plist = NSDictionary(contentsOf: plistURL),
              let bundleId = plist["CFBundleIdentifier"] as? String else {
            return false
        }
        return bundleId.caseInsensitiveCompare(expected) == .orderedSame
    }

    func download(version: String) {
        cancel()
        targetVersion = version
        let url = UpdateDownloader.makeDownloadURL(version: version)

        // 每次下载使用独立的私有临时目录，杜绝 /tmp 固定路径竞态与多用户权限漏洞
        tempDir = UpdateDownloader.makeUpdateDirectory()
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let config = URLSessionConfiguration.default
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        downloadTask = session?.downloadTask(with: url)
        downloadTask?.resume()

        onStateChange?(.downloading(progress: 0))
    }

    func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        session?.invalidateAndCancel()
        session = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let zipPath = tempDir.appendingPathComponent("FUnlock.zip")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                // 移动下载文件到临时目录
                try FileManager.default.moveItem(at: location, to: zipPath)

                // 解压
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                process.arguments = ["-o", zipPath.path, "-d", tempDir.path]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()

                guard process.terminationStatus == 0 else {
                    throw DownloadError.unzipFailed
                }

                // 校验 FUnlock.app 存在且 Bundle ID 正确
                let appPath = tempDir.appendingPathComponent("FUnlock.app")
                guard FileManager.default.fileExists(atPath: appPath.path) else {
                    throw DownloadError.appNotFound
                }

                let plistPath = appPath.appendingPathComponent("Contents/Info.plist")
                let expectedBundleId = Bundle.main.bundleIdentifier ?? "com.fuhahah.Funlock"
                guard UpdateDownloader.bundleIdMatches(expected: expectedBundleId, plistURL: plistPath) else {
                    throw DownloadError.bundleIdMismatch
                }

                // 清理 zip 文件
                try? FileManager.default.removeItem(at: zipPath)

                DispatchQueue.main.async {
                    self.onStateChange?(.completed(appPath))
                }
            } catch {
                try? FileManager.default.removeItem(at: self.tempDir)
                DispatchQueue.main.async {
                    self.onStateChange?(.failed(error.localizedDescription))
                }
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(.downloading(progress: progress))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(.failed(error.localizedDescription))
        }
    }
}
