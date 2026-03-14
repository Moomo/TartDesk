import AppKit
import SwiftUI

@main
struct TartDeskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var model = TartDeskViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: model)
                .frame(minWidth: 960, minHeight: 700)
                .onAppear {
                    configureMainWindow()
                }
        }
    }

    private func configureMainWindow() {
        guard let window = NSApp.windows.first else { return }
        window.title = "TartDesk"
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.collectionBehavior.remove(.fullScreenAuxiliary)
        window.tabbingMode = .preferred
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = false
        window.backgroundColor = .windowBackgroundColor
        window.standardWindowButton(.zoomButton)?.isEnabled = true
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }
}
