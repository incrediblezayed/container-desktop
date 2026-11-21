import ContainerKit
import SwiftUI

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Container Desktop").font(.headline)
                Spacer()
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }

            if model.phase == .ready {
                if model.containers.isEmpty {
                    Text("No containers yet.").foregroundStyle(.secondary).font(.callout)
                } else {
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(model.containers.prefix(12)) { container in
                                MenuBarRow(container: container)
                            }
                        }
                    }
                    .frame(maxHeight: 300)
                }
            } else if model.phase == .systemStopped {
                Button("Start Container System") { Task { await model.startSystem() } }
            }

            Divider()
            HStack {
                Button("Open Container Desktop") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .frame(width: 320)
    }

    private var statusText: String {
        switch model.phase {
        case .ready: "\(model.runningCount) running"
        case .systemStopped: "Stopped"
        case .startingSystem: "Starting…"
        case .cliMissing: "Not installed"
        case .locating: "…"
        }
    }
}

private struct MenuBarRow: View {
    @Environment(AppModel.self) private var model
    let container: ContainerSummary

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(container.state.tint).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 0) {
                Text(container.id).lineLimit(1)
                Text(Format.friendlyImage(container.image)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if container.isRunning, let cpu = model.stats[container.id]?.cpuUtilization {
                Text(Format.percent(cpu)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if model.isBusy(container.id) {
                ProgressView().controlSize(.mini)
            } else {
                Button {
                    Task { container.isRunning ? await model.stop(container) : await model.start(container) }
                } label: {
                    Image(systemName: container.isRunning ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.borderless)
                .help(container.isRunning ? "Stop" : "Start")
            }
        }
        .padding(.vertical, 2)
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var cliPath = UserDefaults.standard.string(forKey: "cliPath") ?? ""

    var body: some View {
        Form {
            SwiftUI.Section {
                TextField("container CLI path", text: $cliPath, prompt: Text(CLIRunner.locate()?.path ?? "/usr/local/bin/container"))
                HStack {
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = false
                        if panel.runModal() == .OK, let url = panel.url { cliPath = url.path }
                    }
                    Spacer()
                    Button("Apply") {
                        model.cliPathOverride = cliPath
                        Task { await model.bootstrap() }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } footer: {
                Text("Leave empty to find it automatically in /usr/local/bin or /opt/homebrew/bin.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(.vertical, 8)
    }
}
