import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetScaffold(title: t("about_funlock")) { dismiss() } content: {
            VStack(alignment: .leading, spacing: FUnlockTheme.Space.sm) {
                FUnlockCard {
                    VStack(spacing: FUnlockTheme.Space.xs) {
                        Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                            .frame(width: 64, height: 64)
                        Text("FUnlock")
                            .font(.title2.weight(.semibold))
                        Text("\(t("about_version")) \(versionString)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(FUnlockTheme.Text.secondary.color)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, FUnlockTheme.Space.xs)
                }

                FUnlockCard {
                    VStack(alignment: .leading, spacing: FUnlockTheme.Space.xs) {
                        InstrumentButton(title: t("about_visit_homepage"), systemImage: "globe",
                                         kind: .secondary) {
                            NSWorkspace.shared.open(URL(string: "https://github.com/hahappyfu/FUnlock")!)
                        }
                        Hairline()
                        InstrumentButton(title: t("about_check_releases"), systemImage: "arrow.down.circle",
                                         kind: .secondary) {
                            NSWorkspace.shared.open(URL(string: "https://github.com/hahappyfu/FUnlock/releases")!)
                        }
                    }
                }

                SheetFooter {
                    InstrumentButton(title: t("done"), kind: .primary) { dismiss() }
                }
            }
        }
        .frame(width: 340, height: 400)
    }

    private var versionString: String {
        guard let info = Bundle.main.infoDictionary,
              let version = info["CFBundleShortVersionString"] as? String,
              let build = info["CFBundleVersion"] as? String else { return "" }
        return "\(version) (\(build))"
    }
}
