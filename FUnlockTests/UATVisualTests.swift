import XCTest
import SwiftUI
import AppKit
@testable import FUnlock

@MainActor
final class UATVisualTests: XCTestCase {
    func testCaptureAllScreenshots() throws {
        let fun = FUn()
        let manager = FUnManager(fun: fun)
        manager.monitoredDeviceName = "Apple Watch Series 7"

        let outputDir = "/tmp/uat_screenshots"
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

        // 1. Capture MenuBarPopoverView
        let popoverView = MenuBarPopoverView(manager: manager, fun: fun, onAction: { _ in })
            .frame(width: 282)
        saveView(view: popoverView, size: NSSize(width: 282, height: 380), to: "\(outputDir)/00_menubar_popover.png")

        // 2. Capture all 7 tabs of MainWindowView
        let tabs: [(MenuTab, String)] = [
            (.overview, "01_overview"),
            (.basic, "02_basic"),
            (.unlock, "03_unlock"),
            (.lock, "04_lock"),
            (.network, "05_network"),
            (.config, "06_config"),
            (.diagnostics, "07_diagnostics")
        ]

        for (tab, filename) in tabs {
            let mainView = MainWindowView(manager: manager, fun: fun, initialTab: tab)
                .frame(width: 620, height: 520)
            saveView(view: mainView, size: NSSize(width: 620, height: 520), to: "\(outputDir)/\(filename).png")
        }
    }

    private func saveView<V: View>(view: V, size: NSSize, to path: String) {
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentViewController = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.view.frame = NSRect(origin: .zero, size: size)
        hosting.view.layoutSubtreeIfNeeded()

        // Allow SwiftUI layout pass to settle
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))

        let targetView = hosting.view
        if let rep = targetView.bitmapImageRepForCachingDisplay(in: targetView.bounds) {
            targetView.cacheDisplay(in: targetView.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
                print("[UAT] Successfully wrote: \(path)")
            }
        }
        window.orderOut(nil)
    }
}
