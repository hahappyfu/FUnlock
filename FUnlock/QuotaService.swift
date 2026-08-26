// QuotaService.swift
// 套餐余量数据内核：读本机 bridge 缓存 → 归一化 → 发布快照。
// 纯观察者：不碰网络、不管 bridge 进程（LaunchAgent 已保活）。
import Foundation
import Combine

// MARK: - 快照模型

struct QuotaWindow: Equatable {
    let key: String        // "5h" | "weekly" | "monthly"
    let used: Double
    let limit: Double
    let percent: Double    // 自算 used/limit*100，封顶 100；缓存内 percent 是恒 0 的 bug 值，不采信
    let resetAt: Date?     // 读取时刻 + resetInSec*1000
}

struct QuotaSnapshot: Equatable {
    let fetchedAt: Date?   // 缓存内 at（Unix 毫秒）
    let expired: Bool      // fetchedAt 缺失或距今 > 10min
    let available: Bool    // 文件缺失/解析失败/全空 → false
    let windows: [QuotaWindow]

    static let empty = QuotaSnapshot(fetchedAt: nil, expired: true, available: false, windows: [])
}

// MARK: - 归一化（纯函数，可单测）

extension QuotaSnapshot {

    /// 把 bridge 缓存原始字节归一化为快照；任何异常输入都返回可用结果，绝不抛出。
    static func normalize(_ data: Data?, now: Date = Date()) -> QuotaSnapshot {
        guard let data, !data.isEmpty,
              let file = try? JSONDecoder().decode(CacheFile.self, from: data),
              let rawQuota = file.quota, !rawQuota.isEmpty
        else { return .empty }

        // at 为 Unix 毫秒数；缺失即视为过期（available 保持 true，旧结构照常给出）
        let fetchedAt = file.at.map { Date(timeIntervalSince1970: $0 / 1000) }
        let expired = fetchedAt.map { now.timeIntervalSince($0) > 600 } ?? true

        // 固定顺序输出，与 JSON 键序无关；缺字段/非法数值的窗口直接剔除
        let windows = ["5h", "weekly", "monthly"].compactMap { key -> QuotaWindow? in
            guard let w = rawQuota[key],
                  let used = w.used, used.isFinite,
                  let limit = w.limit, limit.isFinite
            else { return nil }
            let percent = limit <= 0 ? 0 : min(100, max(0, used / limit * 100))
            let resetAt = w.resetInSec.map { now.addingTimeInterval($0) }
            return QuotaWindow(key: key, used: used, limit: limit, percent: percent, resetAt: resetAt)
        }
        return QuotaSnapshot(fetchedAt: fetchedAt, expired: expired, available: true, windows: windows)
    }

    // 注意：不用 JSONDecoder 的 dateDecodingStrategy——at 是毫秒数用 Double 接，
    // resetInSec 是相对秒数不是绝对时间戳，strategy 无从表达，显式换算更直白。
    private struct CacheFile: Decodable {
        let at: Double?
        let quota: [String: RawWindow]?
    }
    private struct RawWindow: Decodable {
        let used: Double?
        let limit: Double?
        let resetInSec: Double?
    }
}

// MARK: - 轮询服务

/// AppDelegate 创建持有；start() 后每 30s 读一次缓存。
/// 读文件与解码在后台 utility 队列，仅在回主线程时触碰 @Published。
final class QuotaService: ObservableObject {
    @Published private(set) var snapshot: QuotaSnapshot = .empty

    static let cachePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".clawd/opencode-go-bridge-cache.json")

    private let interval: TimeInterval
    private var timer: Timer?

    init(interval: TimeInterval = 30) {
        self.interval = interval
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)   // common 模式：弹窗滚动时不冻结轮询
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 发布决策（纯函数，可单测）：data 为 nil 即读失败 → 返回 nil 表示保留旧快照不发布；
    /// 读到数据则照常归一化发布（内容无效/全空时归一化自身会给出 .empty）。
    func publish(_ data: Data?, previous: QuotaSnapshot) -> QuotaSnapshot? {
        guard let data else { return nil }
        return QuotaSnapshot.normalize(data, now: Date())
    }

    /// 单次刷新：后台读 + 解析，主线程发布。读失败静默保留旧快照。
    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = try? Data(contentsOf: Self.cachePath)
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let next = self.publish(data, previous: self.snapshot) else { return }
                self.snapshot = next
            }
        }
    }
}
