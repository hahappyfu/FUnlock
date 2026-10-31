// FUnlock/BarkNotifier.swift
// Bark 推送通道：与 iMessage 通知并存、独立开关。server/key 可配置，send 经 30s 防抖后 POST /:key。
import Foundation

/// Bark 通知单例
///
/// 线程契约（@unchecked Sendable 依据）：
/// - `lastSendTime`（防抖时间戳）的所有读写均由 `lock`（NSLock）保护；
/// - `queue` / `debounceInterval` / `lock` 为 let，初始化后不再变化；
/// - `configStore` / `nowProvider` / `requestSender` 仅测试进程在调用 send/sendTestNotification
///   之前注入（见属性注释），运行期只读。
final class BarkNotifier: @unchecked Sendable {
    /// 手动测试发送结果。用嵌套类型避免全局污染 String 的 Error 遵循。
    struct SendError: Error {
        let message: String
    }

    static let shared = BarkNotifier()
    private init() {}

    private enum Keys {
        static let enabled = "barkNotify"
        static let key = "barkNotifyKey"
        static let server = "barkNotifyServer"
    }

    enum Defaults {
        static let key = "swMSCpBr9baWGYCiu6ijoK"
        static let server = "https://api.day.app"
    }

    private let queue = DispatchQueue(label: "com.funlock.bark", qos: .utility)
    private let debounceInterval: TimeInterval = 30.0
    private var lastSendTime: [String: Date] = [:]
    private let lock = NSLock()

    /// 测试注入点：配置存储（默认 ConfigStore.shared）。
    /// 仅测试进程在调用 send/sendTestNotification 之前设置；运行期恒为默认值，不要在生产代码赋值。
    var configStore: ConfigStore = .shared

    /// 测试注入点：时间源（默认 Date.init），供 30s 防抖窗口边界测试推进假时钟。
    /// 仅测试进程在调用 send 之前设置；运行期恒为默认值，不要在生产代码赋值。
    var nowProvider: () -> Date = Date.init

    /// 测试注入点：替换真实 HTTP 请求，返回 (HTTP 状态码, 响应体)（默认 nil 走 URLSession）。
    /// 仅测试进程在调用 send/sendTestNotification 之前设置；运行期恒为 nil，不要在生产代码赋值。
    var requestSender: ((URLRequest) -> (Int, Data)?)?

    /// 仅供测试：清空防抖时间戳，避免测试间相互影响。
    func resetDebounceForTesting() {
        lock.lock()
        lastSendTime.removeAll()
        lock.unlock()
    }

    private var enabled: Bool {
        configStore.bool(forKey: Keys.enabled)
    }

    /// 用户配置 key，缺失/为空回退默认 key（预填历史 key 的兜底）。
    private var barkKey: String {
        let raw = Self.normalizeKey(configStore.string(forKey: Keys.key) ?? "")
        return raw.isEmpty ? Defaults.key : raw
    }

    /// 用户配置 server，缺失/为空回退默认 server。
    private var barkServer: String {
        let raw = Self.normalizeServer(configStore.string(forKey: Keys.server) ?? "")
        return raw.isEmpty ? Defaults.server : raw
    }

    static func normalizeServer(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func normalizeKey(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func buildURL(server: String, key: String) -> URL? {
        let base = normalizeServer(server)
        guard !base.isEmpty, !key.isEmpty else { return nil }
        let encoded = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        return URL(string: base + "/" + encoded)
    }

    /// 语义化事件发送：锁屏/解锁时由调用方触发。失败静默记日志（不打 URL，防 key 泄漏）。
    /// 防抖按事件类型（lock/unlock/test）各 30 秒，失败同样占用窗口。
    func send(_ event: IMEvent) {
        guard enabled else { return }

        let typeKey: String
        switch event {
        case .locked: typeKey = "lock"
        case .unlocked: typeKey = "unlock"
        case .test: typeKey = "test"
        }

        let now = nowProvider()
        lock.lock()
        if let last = lastSendTime[typeKey], now.timeIntervalSince(last) < debounceInterval {
            lock.unlock()
            return
        }
        lastSendTime[typeKey] = now
        lock.unlock()

        // compose 在调用线程执行（IMEvent 非 Sendable，不跨隔离域传递）
        let (title, body) = IMMessageComposer.compose(event)
        queue.async { [weak self] in
            guard let self = self else { return }
            guard let request = self.makeRequest(title: title, body: body) else {
                AppLog.error(.app, "barkSendFailed", [("error", "url invalid")])
                return
            }
            if let (status, _) = self.runRequest(request), status != 200 {
                AppLog.error(.app, "barkSendFailed", [("status", "\(status)")])
            }
        }
    }

    /// 手动连通性测试：发送并返回结果（成功 .success, 失败 .failure+原因）。
    /// 绕过 30s 防抖、不写 lastSendTime —— 测试就是要反复验证。
    /// 方法标注 @MainActor：completion 在主线程回调（同隔离域调用，无跨域发送）。
    @MainActor
    func sendTestNotification(title: String, message: String,
                              completion: @escaping @MainActor (Result<Void, BarkNotifier.SendError>) -> Void) {
        guard enabled else {
            Task { @MainActor in
                completion(.failure(BarkNotifier.SendError(message: "Bark 通知开关未开启，请先开启")))
            }
            return
        }
        guard let url = Self.buildURL(server: barkServer, key: barkKey) else {
            Task { @MainActor in
                completion(.failure(BarkNotifier.SendError(message: "服务器地址无效，请检查 Bark 服务器地址")))
            }
            return
        }
        Task { @MainActor in
            let status = await self.runOnQueue(Self.makeRequest(url: url, title: title, body: message))
            if status == 200 {
                completion(.success(()))
            } else {
                completion(.failure(BarkNotifier.SendError(message: "发送失败：HTTP \(status)")))
            }
        }
    }

    /// 组装 Bark 推送请求（POST JSON：title/body/group/level）。
    private static func makeRequest(url: URL, title: String, body: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "title": title,
            "body": body,
            "group": "funlock",
            "level": "timeSensitive",
        ])
        return request
    }

    private func makeRequest(title: String, body: String) -> URLRequest? {
        guard let url = Self.buildURL(server: barkServer, key: barkKey) else { return nil }
        return Self.makeRequest(url: url, title: title, body: body)
    }

    /// 在串行队列上执行请求，并以 continuation 桥接为 async（保持 queue 串行契约）。
    private func runOnQueue(_ request: URLRequest) async -> Int {
        await withCheckedContinuation { cont in
            queue.async {
                let result = self.runRequest(request)
                cont.resume(returning: result?.0 ?? 0)
            }
        }
    }

    /// 阻塞执行 HTTP 请求，返回 (状态码, 响应体)。仅允许从 queue 队列内调用。
    private func runRequest(_ request: URLRequest) -> (Int, Data)? {
        if let sender = requestSender {
            return sender(request)
        }
        let semaphore = DispatchSemaphore(value: 0)
        var result: (Int, Data)?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            result = (status, data ?? Data())
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return result
    }
}
