import AppKit
import ContainerKit
import SwiftUI

/// Logs in their own window, for reading side by side or in full screen.
struct LogWindow: View {
    @Environment(AppModel.self) private var model
    let target: LogWindowTarget

    /// Looked up live, so a restarted container keeps streaming.
    private var sources: [LogSource] {
        target.entries.compactMap { entry in
            model.containers.first { $0.id == entry.id }.map { LogSource(name: entry.name, container: $0) }
        }
    }

    var body: some View {
        Group {
            if sources.isEmpty {
                if model.containers.isEmpty {
                    ProgressView()
                } else {
                    ContentUnavailableView("Container not found", systemImage: "shippingbox",
                                           description: Text("It may have been deleted."))
                }
            } else {
                LogsView(sources: sources, isWindow: true)
            }
        }
        .frame(minWidth: 520, minHeight: 320)
        .navigationTitle(target.title)
        .background(WindowAccessor { window in
            if target.fullScreen, !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        })
    }
}

/// Hands over the hosting NSWindow once the view is in one.
private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { Probe(onWindow: onWindow) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        let onWindow: (NSWindow) -> Void
        private var done = false
        init(onWindow: @escaping (NSWindow) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !done else { return }
            done = true
            // Let the window finish appearing before resizing it.
            DispatchQueue.main.async { self.onWindow(window) }
        }
    }
}
