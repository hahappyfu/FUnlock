import Foundation

/// Event logging (events.log) and user script execution (event script)
final class ScriptRunner {
    static let shared = ScriptRunner()
    private init() {}

    // MARK: - Event Logging

    /// Append an event to ~/Library/Application Support/FUnlock/events.log
    func logEvent(_ event: String, rssi: Int? = nil) {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return }
        let logDir = dir.appendingPathComponent("FUnlock", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logFile = logDir.appendingPathComponent("events.log")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let rssiStr = rssi.map { String($0) } ?? "N/A"
        let line = "\(formatter.string(from: Date())) | \(event) | RSSI: \(rssiStr)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile.path) {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logFile)
            }
        }
    }

    // MARK: - User Script Execution

    /// Run the user's ~/Library/Application Scripts/FUnlock/event script with context args
    func runScript(_ arg: String, rssi: Int? = nil, deviceName: String? = nil, uuid: UUID? = nil) {
        guard let directory = try? FileManager.default.url(for: .applicationScriptsDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return }
        let file = directory.appendingPathComponent("event")
        let process = Process()
        process.executableURL = file
        var args = [arg]
        if let r = rssi { args.append(String(r)) }
        if let name = deviceName { args.append(name) }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        args.append(formatter.string(from: Date()))
        process.arguments = args
        try? process.run()
    }
}
