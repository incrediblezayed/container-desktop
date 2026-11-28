import ContainerKit
import SwiftUI

/// Launched through `Main`, which hands `--mcp` launches to the MCP server instead.
struct ContainerDesktopApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Container Desktop", id: "main") {
            RootView()
                .environment(model)
                .task { await model.bootstrap() }
                .frame(minWidth: 860, minHeight: 520)
        }
        .defaultSize(width: 1100, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Run Container…") { model.isRunSheetPresented = true }
                    .keyboardShortcut("n")
                    .disabled(model.phase != .ready)
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh") { model.kick() }
                    .keyboardShortcut("r")
                Divider()
                ForEach(Array(Section.allCases.enumerated()), id: \.element) { index, section in
                    Button(section.title) { model.section = section }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                }
            }
        }

        WindowGroup("Logs", id: "logs", for: LogWindowTarget.self) { $target in
            if let target {
                LogWindow(target: target)
                    .environment(model)
            }
        }
        .defaultSize(width: 1000, height: 640)

        MenuBarExtra {
            MenuBarContent()
                .environment(model)
        } label: {
            Label("Container Desktop", systemImage: model.runningCount > 0 ? "shippingbox.fill" : "shippingbox")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
