import AppKit
import SwiftUI

@main
struct TartDeskApp: App {
    @State private var model = TartDeskViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: model)
                .frame(minWidth: 1080, minHeight: 720)
                .background(WindowConfigurator())
        }
    }
}

private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            configure(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            configure(window)
        }
    }

    private func configure(_ window: NSWindow) {
        window.minSize = NSSize(width: 1080, height: 720)
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
