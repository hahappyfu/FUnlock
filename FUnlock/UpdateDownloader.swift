import Foundation

class UpdateDownloader: NSObject, URLSessionDownloadDelegate {
    enum State {
        case idle
        case downloading(progress: Double)
        case completed(URL)   // 解压后的 FUnlock.app 路径
        case failed(Error)
    }

    var onStateChange: ((State) -> Void)?

    private var downloadTask: URLSessionDownloadTask?
    private var session: URLSession?
    private let tempDir = URL(fileURLWithPath: "/tmp/FUnlock-update")
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

    func download(version: String) {
        cancel()
        targetVersion = version
        let url = URL(string: "https://gitee.com/fuhahah/funlock/releases/download/v\(version)/FUnlock.zip")!

        // 准备临时目录
        try? FileManager.default.removeItem(at: tempDir)
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
            guard let plist = NSDictionary(contentsOf: plistPath),
                  let bundleId = plist["CFBundleIdentifier"] as? String,
                  bundleId == "com.fuhahah.FUnlock" else {
                throw DownloadError.bundleIdMismatch
            }

            // 清理 zip 文件
            try? FileManager.default.removeItem(at: zipPath)

            DispatchQueue.main.async { [weak self] in
                self?.onStateChange?(.completed(appPath))
            }
        } catch {
            try? FileManager.default.removeItem(at: tempDir)
            DispatchQueue.main.async { [weak self] in
                self?.onStateChange?(.failed(error))
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
            self?.onStateChange?(.failed(error))
        }
    }
}
