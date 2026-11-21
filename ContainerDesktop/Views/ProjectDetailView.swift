import ContainerKit
import SwiftUI

/// A Compose project: its services at a glance, and their logs merged like `docker compose logs`.
struct ProjectDetailView: View {
    @Environment(AppModel.self) private var model
    let project: ComposeProject

    enum Tab: String, CaseIterable, Identifiable {
        case services = "Services", logs = "Logs"
        var id: String { rawValue }
    }

    @State private var tab: Tab = {
        #if DEBUG
        if let name = UserDefaults.standard.string(forKey: "debugTab"), let tab = Tab(rawValue: name) { return tab }
        #endif
        return .services
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            Divider()
            switch tab {
            case .services: services
            case .logs: LogsView(sources: project.services.map { LogSource(name: $0.displayName, container: $0) })
            }
        }
        .background(.background)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Label(project.name, systemImage: "square.stack.3d.up.fill")
                    .font(.title3.bold())
                    .textSelection(.enabled)
                if let dir = project.workingDirectory {
                    Text(dir.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Text("\(project.runningCount) of \(project.services.count) services running")
                    .font(.callout)
            }
            Spacer()
            HStack(spacing: 6) {
                if project.isRunning {
                    Button { Task { await model.restartProject(project) } } label: { Label("Restart", systemImage: "arrow.clockwise") }
                        .help("Restart all services")
                    Button { Task { await model.stopProject(project) } } label: { Label("Stop", systemImage: "stop.fill") }
                        .help("Stop all services")
                }
                if project.state != .running {
                    Button { Task { await model.startProject(project) } } label: { Label("Start", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                        .help("Start all services in dependency order, waiting for health checks")
                }
            }
            .labelStyle(.iconOnly)
            .controlSize(.large)
            .disabled(model.isBusy(project.id))
        }
        .padding(16)
    }

    private var services: some View {
        Form {
            SwiftUI.Section("Services") {
                ForEach(project.services) { service in
                    Button { model.selectedContainerID = service.id } label: {
                        ServiceRow(model: model, service: service, project: project)
                    }
                    .buttonStyle(.plain)
                    .help("Show \(service.id)")
                }
            }
            if !project.helpers.isEmpty {
                SwiftUI.Section {
                    ForEach(project.helpers) { helper in
                        HStack {
                            Image(systemName: "gearshape").foregroundStyle(.secondary)
                            Text(helper.id).foregroundStyle(.secondary)
                            Spacer()
                            StateBadge(state: helper.state)
                        }
                    }
                } header: {
                    Text("Runtime helpers")
                } footer: {
                    Text("Socktainer runs a small DNS server per network so services can reach each other by name. It keeps running when you stop the project, because services remember its address.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !project.configFiles.isEmpty {
                SwiftUI.Section("Compose files") {
                    ForEach(project.configFiles, id: \.self) { file in
                        HStack {
                            Text(file.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .monospaced().font(.callout)
                                .lineLimit(1).truncationMode(.middle)
                                .textSelection(.enabled)
                            Spacer()
                            Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: file)) }
                                .buttonStyle(.link)
                        }
                    }
                    if let dir = project.workingDirectory {
                        HStack {
                            Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: dir)) }
                            Button("Open in Terminal") { ProjectFolder.openInTerminal(dir) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ServiceRow: View {
    let model: AppModel
    let service: ContainerSummary
    let project: ComposeProject

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(service.state.tint).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(service.displayName).fontWeight(.medium)
                    if model.isBusy(service.id) { ProgressView().controlSize(.mini) }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if service.isRunning, let stats = model.stats[service.id] {
                Text("\(Format.percent(stats.cpuUtilization)) · \(Format.bytes(stats.memoryUsageBytes))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private var detail: String {
        var parts = [Format.friendlyImage(service.image)]
        if !service.ports.isEmpty { parts.append(service.ports.map(\.display).joined(separator: ", ")) }
        let deps = service.composeDependencies.map { dep in
            switch dep.condition {
            case .healthy: "\(dep.service) (healthy)"
            case .completedSuccessfully: "\(dep.service) (done)"
            default: dep.service
            }
        }
        if !deps.isEmpty { parts.append("needs " + deps.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}
