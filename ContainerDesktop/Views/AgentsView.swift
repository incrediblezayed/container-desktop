import AppKit
import ContainerKit
import SwiftUI

/// Connect AI coding agents to the MCP server built into the app.
struct AgentsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("mcpAllowChanges") private var allowChanges = true
    @State private var claude: URL?
    @State private var status: AgentIntegration.ClaudeStatus?
    @State private var working = false
    @State private var copied: String?

    private var readOnly: Bool { !allowChanges }

    var body: some View {
        Form {
            SwiftUI.Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Let AI agents manage your containers", systemImage: "sparkles")
                        .font(.headline)
                    Text("Container Desktop includes an MCP server. Agents like Claude Code can use it to list projects, read logs filtered to errors, find out why a stack is broken, and start, stop or restart services in dependency order, just like the buttons here.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                Toggle(isOn: $allowChanges) {
                    Text("Allow changes")
                    Text("Start, stop, restart, and run commands inside containers. Turn off to let agents only look.")
                }
            }

            if !AgentIntegration.isInstalledInApplications {
                SwiftUI.Section {
                    Label("Move Container Desktop to the Applications folder first. Agents launch the server from this copy's location, so they stop working if it moves.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            SwiftUI.Section {
                LabeledContent("Status") { statusLabel }
                HStack {
                    switch status {
                    case .notInstalled:
                        Button("Get Claude Code") { NSWorkspace.shared.open(URL(string: "https://code.claude.com/docs/en/setup")!) }
                    case .connected(let current):
                        if current != readOnly {
                            Button("Apply Change") { connect() }.buttonStyle(.borderedProminent)
                        }
                        Button("Disconnect", role: .destructive) { disconnect() }
                    case .outdated:
                        Button("Reconnect") { connect() }.buttonStyle(.borderedProminent)
                        Button("Disconnect", role: .destructive) { disconnect() }
                    case .notConnected:
                        Button("Add to Claude Code") { connect() }.buttonStyle(.borderedProminent)
                    case nil:
                        EmptyView()
                    }
                    if working { ProgressView().controlSize(.small) }
                    Spacer()
                }
                .disabled(working)
                copyRow(AgentIntegration.claudeCommand(readOnly: readOnly), label: "Command")
            } header: {
                Text("Claude Code")
            } footer: {
                Text("Adds the server for your user, so every project sees it. Start a new Claude Code session, or run /mcp, to pick it up.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            SwiftUI.Section {
                copyRow(AgentIntegration.clientConfig(readOnly: readOnly), label: "Configuration")
            } header: {
                Text("Other MCP clients")
            } footer: {
                Text("Claude Desktop, Cursor, VS Code and most other clients accept this in their MCP settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let engine = model.engine {
                SwiftUI.Section("Tools agents get") {
                    ForEach(ContainerTools.all(controller: ProjectController(engine: engine), readOnly: readOnly), id: \.name) { tool in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(tool.title).fontWeight(.medium)
                                Text(tool.name).font(.caption.monospaced()).foregroundStyle(.secondary)
                                if !tool.annotations.readOnly {
                                    Text("changes things").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(.orange.opacity(0.15), in: Capsule()).foregroundStyle(.orange)
                                }
                            }
                            Text(tool.description).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("AI Agents")
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await reload() }
        }
    }

    @ViewBuilder private var statusLabel: some View {
        switch status {
        case nil: ProgressView().controlSize(.small)
        case .notInstalled: Text("Claude Code isn't installed").foregroundStyle(.secondary)
        case .notConnected: Text("Not connected").foregroundStyle(.secondary)
        case .outdated: Label("Connected to another copy of the app", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
        case .connected(let readOnly):
            Label(readOnly ? "Connected, read-only" : "Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    private func copyRow(_ text: String, label: String) -> some View {
        HStack(alignment: .top) {
            Text(text)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied == text ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = text
            }
            .help("Copy the \(label.lowercased())")
        }
    }

    private func reload() async {
        claude = await AgentIntegration.locateClaude()
        status = AgentIntegration.claudeStatus(claude: claude)
    }

    private func connect() {
        guard let claude else { return }
        run("Couldn't add Container Desktop to Claude Code") { try await AgentIntegration.connectClaude(claude, readOnly: readOnly) }
    }

    private func disconnect() {
        guard let claude else { return }
        run("Couldn't remove Container Desktop from Claude Code") { try await AgentIntegration.disconnectClaude(claude) }
    }

    private func run(_ title: String, _ action: @escaping () async throws -> Void) {
        working = true
        Task {
            do { try await action() } catch { model.report(title, error) }
            await reload()
            working = false
        }
    }
}
