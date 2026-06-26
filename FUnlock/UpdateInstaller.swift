import Cocoa

enum UpdateInstaller {
    enum InstallError: LocalizedError {
        case scriptCreationFailed
        case processLaunchFailed

        var errorDescription: String? {
            switch self {
            case .scriptCreationFailed: return "安装脚本创建失败"
            case .processLaunchFailed: return "安装脚本启动失败"
            }
        }
    }

    /// 生成安装脚本并启动，然后退出 app
    static func install(appPath: URL) throws {
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

        // 设置可执行权限
        chmod(scriptPath)

        // 启动脚本（脱离父进程）
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

        // 退出 app
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
