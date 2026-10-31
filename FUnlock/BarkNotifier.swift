// FUnlock/BarkNotifier.swift
// Bark 推送通道：与 iMessage 通知并存、独立开关。server/key 可配置，send 经 30s 防抖后 POST /:key。
import Foundation

final class BarkNotifier: @unchecked Sendable {
    static let shared = BarkNotifier()
    private init() {}

    enum Defaults {
        static let key = "swMSCpBr9baWGYCiu6ijoK"
        static let server = "https://api.day.app"
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
}
