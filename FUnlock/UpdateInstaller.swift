import Cocoa

enum UpdateInstaller {
    enum InstallError: LocalizedError {
        case scriptCreationFailed
        case processLaunchFailed
        case signatureInvalid

        var errorDescription: String? {
            switch self {
            case .scriptCreationFailed: return "安装脚本创建失败"
            case .processLaunchFailed: return "安装脚本启动失败"
            case .signatureInvalid: return "下载的应用签名验证失败"
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

        let script = """
        #!/bin/bash
        sleep 2
        APP="/Applications/FUnlock.app"
        UPDATE="\(appPath.path)"

        if [ -d "$UPDATE" ]; then
            rm -rf "$APP"
            cp -R "$UPDATE" "$APP"
            open "$APP"
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
