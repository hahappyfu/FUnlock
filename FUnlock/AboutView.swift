import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .frame(width: 64, height: 64)

            Text("FUnlock")
                .font(.title2.bold())

            Text("version \(versionString)")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Divider()

            Button(t("about_visit_homepage")) {
                NSWorkspace.shared.open(URL(string: "https://gitee.com/fuhahah/FUnlock")!)
            }
            Button(t("about_check_releases")) {
                NSWorkspace.shared.open(URL(string: "https://gitee.com/fuhahah/FUnlock/releases")!)
            }

            Divider()

            Button(t("done")) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(width: 280)
    }

    private var versionString: String {
        guard let info = Bundle.main.infoDictionary,
              let version = info["CFBundleShortVersionString"] as? String,
              let build = info["CFBundleVersion"] as? String else { return "" }
        return "\(version) (\(build))"
    }
}
