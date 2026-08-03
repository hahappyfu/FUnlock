import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                        .frame(width: 64, height: 64)

                    Text("FUnlock")
                        .font(.title2.bold())

                    Text("version \(versionString)")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            Section {
                Button(t("about_visit_homepage")) {
                    NSWorkspace.shared.open(URL(string: "https://github.com/hahappyfu/FUnlock")!)
                }
                Button(t("about_check_releases")) {
                    NSWorkspace.shared.open(URL(string: "https://github.com/hahappyfu/FUnlock/releases")!)
                }
            }

            Section {
                Button(t("done")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 300)
    }

    private var versionString: String {
        guard let info = Bundle.main.infoDictionary,
              let version = info["CFBundleShortVersionString"] as? String,
              let build = info["CFBundleVersion"] as? String else { return "" }
        return "\(version) (\(build))"
    }
}
