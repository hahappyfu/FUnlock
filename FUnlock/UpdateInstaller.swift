import Cocoa

enum UpdateInstaller {
    enum InstallError: LocalizedError {
        case scriptCreationFailed
        case processLaunchFailed
        case signatureInvalid
        case teamIdMismatch

        var errorDescription: String? {
            switch self {
            case .scriptCreationFailed: return "安装脚本创建失败"
            case .processLaunchFailed: return "安装脚本启动失败"
            case .signatureInvalid: return "下载的应用签名验证失败"
            case .teamIdMismatch: return "下载应用的开发者身份校验失败"
            }
        }
    }

    /// 校验代码签名后，生成安装脚本并启动，然后退出 app
    static func install(appPath: URL) throws {
        // 代码签名校验
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--verify", "--deep", "--strict", appPath.path]
        codesign.standardOutput = FileHandle.nullDevice
        codesign.standardError = FileHandle.nullDevice
        try codesign.run()
        codesign.waitUntilExit()
        guard codesign.terminationStatus == 0 else {
            throw InstallError.signatureInvalid
        }

        // Team ID 一致性校验：下载应用必须与当前已安装应用属于同一开发者
        guard let installedTeamId = extractTeamId(from: Bundle.main.bundleURL),
              let downloadedTeamId = extractTeamId(from: appPath),
              installedTeamId == downloadedTeamId else {
            throw InstallError.teamIdMismatch
        }

        let script = """
        #!/bin/bash
        sleep 2
        APP="/Applications/FUnlock.app"
        UPDATE="\(appPath.path)"
        STAGING="/Applications/FUnlock.app.staging"

        if [ -d "$UPDATE" ]; then
            rm -rf "$STAGING"
            cp -R "$UPDATE" "$STAGING"      # 先复制到临时位置（与目标同卷，mv 为原子操作）
            if [ -d "$STAGING" ]; then
                rm -rf "$APP"               # 复制成功后才动旧版
                mv "$STAGING" "$APP"
                open "$APP"
            else
                rm -rf "$STAGING"           # 复制失败，清理 staging，旧版保留不动
            fi
        fi
        rm -rf /tmp/FUnlock-update
        """

        let scriptPath = "/tmp/FUnlock-update/install.sh"
        do {
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        } catch {
            throw InstallError.scriptCreationFailed
        }

        chmod(scriptPath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw InstallError.processLaunchFailed
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApplication.shared.terminate(nil)
        }
    }

    /// 通过 codesign -d --verbose=4 提取应用的 TeamIdentifier（信息输出在 stderr）
    private static func extractTeamId(from appURL: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-d", "--verbose=4", appURL.path]
        process.standardOutput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return nil
        }

        // codesign -d 可能以非零状态退出，但签名信息仍会写入 stderr，无需依赖退出码
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8),
              let teamId = output.split(separator: "\n")
                  .first { $0.contains("TeamIdentifier=") }?
                  .split(separator: "=")
                  .last?
                  .trimmingCharacters(in: .whitespaces),
              !teamId.isEmpty else {
            return nil
        }
        return teamId
    }

    private static func chmod(_ path: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/chmod")
        proc.arguments = ["+x", path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
    }
}
