import ContainerKit
import SwiftUI

/// One row of the container list: a Compose project, a container, or the group of
/// runtime helpers.
struct ContainerRow: Identifiable, Hashable {
    enum Kind: Hashable {
        case project(ComposeProject)
        case container(ContainerSummary, inProject: Bool)
        case helpers(count: Int)
    }

    let kind: Kind

    static let helpersID = "group:helpers"

    var id: String {
        switch kind {
        case .project(let p): p.id
        case .container(let c, _): c.id
        case .helpers: Self.helpersID
        }
    }
}

struct ContainersView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @AppStorage("showStoppedContainers") private var showStopped = true
    @AppStorage("showHelperContainers") private var showHelpers = false
    @State private var pendingDelete: ContainerSummary?
    @State private var pendingProjectDelete: ComposeProject?
    @State private var collapsed: Set<String> = [ContainerRow.helpersID]

    private func isVisible(_ c: ContainerSummary, projectMatches: Bool = false) -> Bool {
        guard showStopped || c.isRunning else { return false }
        return search.isEmpty || projectMatches
            || c.id.localizedCaseInsensitiveContains(search)
            || c.image.localizedCaseInsensitiveContains(search)
            || (c.composeService?.localizedCaseInsensitiveContains(search) ?? false)
    }

    private struct Visible {
        var projects: [(project: ComposeProject, rows: [ContainerSummary])] = []
        var standalone: [ContainerSummary] = []
        var helpers: [ContainerSummary] = []
    }

    private var visible: Visible {
        let grouping = model.grouping
        var result = Visible()
        for project in grouping.projects {
            let matches = !search.isEmpty && project.name.localizedCaseInsensitiveContains(search)
            var rows = project.services.filter { isVisible($0, projectMatches: matches) }
            if showHelpers { rows += project.helpers.filter { isVisible($0, projectMatches: matches) } }
            if !rows.isEmpty { result.projects.append((project, rows)) }
        }
        result.standalone = grouping.standalone.filter { isVisible($0) }
        if showHelpers { result.helpers = grouping.helpers.filter { isVisible($0) } }
        return result
    }

    var body: some View {
        @Bindable var model = model
        Group {
            if model.containers.isEmpty {
                EmptyStateView(title: "No containers", symbol: "shippingbox",
                               message: "Run an image to create your first container.") {
                    Button("Run Container…") { model.isRunSheetPresented = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                HSplitView {
                    table
                        .frame(minWidth: 460)
                    detail
                }
            }
        }
        .navigationTitle("Containers")
        .navigationSubtitle(subtitle)
        .searchable(text: $search, placement: .toolbar, prompt: "Filter containers")
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Toggle("Show Stopped Containers", isOn: $showStopped)
                    Toggle("Show Runtime Helpers", isOn: $showHelpers)
                } label: { Label("View Options", systemImage: "line.3.horizontal.decrease.circle") }
                    .help("Choose which containers to show")
                Button { model.isRunSheetPresented = true } label: { Label("Run", systemImage: "plus") }
                    .help("Run a new container (⌘N)")
            }
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.id ?? "")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { container in
            Button(container.isRunning ? "Stop and Delete" : "Delete", role: .destructive) {
                Task { await model.delete(container) }
            }
        } message: { container in
            Text(container.isRunning ? "The container is running. It will be stopped first. Its filesystem is removed; named volumes are kept." : "Its filesystem is removed; named volumes are kept.")
        }
        .confirmationDialog(
            "Delete the \(pendingProjectDelete?.name ?? "") project's containers?",
            isPresented: Binding(get: { pendingProjectDelete != nil }, set: { if !$0 { pendingProjectDelete = nil } }),
            presenting: pendingProjectDelete
        ) { project in
            Button("Delete \(project.services.count) Containers", role: .destructive) {
                Task { await model.deleteProject(project) }
            }
        } message: { _ in
            Text("Running services are stopped first. Volumes and networks are kept, like `docker compose rm`. Run `docker compose up` to recreate them.")
        }
    }

    private var subtitle: String {
        let projects = model.grouping.projects.count
        let base = "\(model.runningCount) running · \(model.containers.count) total"
        return projects > 0 ? base + " · \(projects) project\(projects == 1 ? "" : "s")" : base
    }

    @ViewBuilder
    private var detail: some View {
        if let id = model.selectedContainerID {
            if id.hasPrefix("project:"), let project = model.project(named: String(id.dropFirst("project:".count))) {
                ProjectDetailView(project: project)
                    .environment(model) // HSplitView panes are separate AppKit hosts
                    .id(project.id)
                    .frame(minWidth: 380, idealWidth: 480)
            } else if let container = model.containers.first(where: { $0.id == id }) {
                ContainerDetailView(container: container)
                    .environment(model)
                    .id(container.id)
                    .frame(minWidth: 380, idealWidth: 460)
            }
        }
    }

    private func expansion(_ id: String) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(id) },
                set: { if $0 { collapsed.remove(id) } else { collapsed.insert(id) } })
    }

    private var table: some View {
        @Bindable var model = model
        let visible = visible
        return Table(of: ContainerRow.self, selection: $model.selectedContainerID) {
            TableColumn("Name") { row in NameCell(model: model, row: row) }
                .width(min: 150, ideal: 200)
            TableColumn("Image") { row in
                switch row.kind {
                case .project(let p):
                    Text("\(p.services.count) service\(p.services.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                case .container(let c, _):
                    Text(Format.friendlyImage(c.image)).foregroundStyle(.secondary).lineLimit(1)
                case .helpers: EmptyView()
                }
            }
            .width(min: 110, ideal: 180)
            TableColumn("State") { row in
                switch row.kind {
                case .project(let p): ProjectStateBadge(project: p)
                case .container(let c, _): StateBadge(state: c.state)
                case .helpers: EmptyView()
                }
            }
            .width(100)
            TableColumn("CPU") { row in
                Text(cpu(row)).monospacedDigit()
            }
            .width(60)
            TableColumn("Memory") { row in
                Text(memory(row)).monospacedDigit()
            }
            .width(80)
            TableColumn("Ports") { row in
                Text(ports(row)).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 80, ideal: 130)
            TableColumn("") { row in
                switch row.kind {
                case .project(let p):
                    ProjectRowActions(model: model, project: p, onDelete: { pendingProjectDelete = p })
                case .container(let c, _):
                    RowActions(model: model, container: c, onDelete: { pendingDelete = c })
                case .helpers: EmptyView()
                }
            }
            .width(70)
        } rows: {
            ForEach(visible.projects, id: \.project.id) { entry in
                DisclosureTableRow(ContainerRow(kind: .project(entry.project)), isExpanded: expansion(entry.project.id)) {
                    ForEach(entry.rows) { c in
                        TableRow(ContainerRow(kind: .container(c, inProject: true)))
                    }
                }
            }
            ForEach(visible.standalone) { c in
                TableRow(ContainerRow(kind: .container(c, inProject: false)))
            }
            if !visible.helpers.isEmpty {
                DisclosureTableRow(ContainerRow(kind: .helpers(count: visible.helpers.count)), isExpanded: expansion(ContainerRow.helpersID)) {
                    ForEach(visible.helpers) { c in
                        TableRow(ContainerRow(kind: .container(c, inProject: false)))
                    }
                }
            }
        }
        .contextMenu(forSelectionType: ContainerRow.ID.self) { ids in
            if let id = ids.first {
                if id.hasPrefix("project:"), let p = model.project(named: String(id.dropFirst("project:".count))) {
                    ProjectMenuItems(model: model, project: p, onDelete: { pendingProjectDelete = p })
                } else if let c = model.containers.first(where: { $0.id == id }) {
                    ContainerMenuItems(model: model, container: c, onDelete: { pendingDelete = c })
                }
            }
        } primaryAction: { ids in
            model.selectedContainerID = ids.first
        }
    }

    // MARK: Aggregates

    private func members(_ row: ContainerRow) -> [ContainerSummary] {
        switch row.kind {
        case .project(let p): p.services
        case .container(let c, _): [c]
        case .helpers: []
        }
    }

    private func cpu(_ row: ContainerRow) -> String {
        let running = members(row).filter(\.isRunning)
        guard !running.isEmpty else { return "—" }
        let samples = running.compactMap { model.stats[$0.id]?.cpuUtilization }
        return samples.isEmpty ? "—" : Format.percent(samples.reduce(0, +))
    }

    private func memory(_ row: ContainerRow) -> String {
        let running = members(row).filter(\.isRunning)
        guard !running.isEmpty else { return "—" }
        let samples = running.compactMap { model.stats[$0.id]?.memoryUsageBytes }
        return samples.isEmpty ? "—" : Format.bytes(samples.reduce(0, +))
    }

    private func ports(_ row: ContainerRow) -> String {
        switch row.kind {
        case .project(let p):
            p.services.flatMap(\.ports).map { String($0.hostPort) }.joined(separator: ", ")
        case .container(let c, _):
            c.ports.map(\.display).joined(separator: ", ")
        case .helpers: ""
        }
    }
}

// MARK: - Cells

/// Table cells and context menus are hosted by AppKit, which doesn't reliably carry
/// SwiftUI's environment into them (rows created during an update crashed with
/// "No Observable object of type AppModel found"), so they take the model explicitly.
private struct NameCell: View {
    let model: AppModel
    let row: ContainerRow

    var body: some View {
        HStack(spacing: 6) {
            switch row.kind {
            case .project(let p):
                if model.isBusy(p.id) { ProgressView().controlSize(.mini) }
                Image(systemName: "square.stack.3d.up.fill").foregroundStyle(.tint)
                Text(p.name).fontWeight(.semibold)
                    .help(p.workingDirectory ?? p.name)
            case .container(let c, let inProject):
                if model.isBusy(c.id) { ProgressView().controlSize(.mini) }
                if c.isHelper {
                    Image(systemName: "gearshape").foregroundStyle(.secondary)
                    Text(c.id).foregroundStyle(.secondary)
                } else {
                    Text(inProject ? c.displayName : c.id).fontWeight(.medium)
                        .help(c.id)
                }
            case .helpers(let count):
                Image(systemName: "gearshape.2").foregroundStyle(.secondary)
                Text("Runtime helpers (\(count))").foregroundStyle(.secondary)
                    .help("DNS servers and builders that Socktainer and BuildKit create")
            }
        }
    }
}

private struct ProjectStateBadge: View {
    let project: ComposeProject

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(project.state == .partial ? "\(project.runningCount)/\(project.services.count) running" : (project.isRunning ? "Running" : "Stopped"))
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch project.state {
        case .running: .green
        case .partial: .orange
        case .stopped: .secondary
        }
    }
}

private struct RowActions: View {
    let model: AppModel
    let container: ContainerSummary
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            if container.isRunning {
                Button { Task { await model.stop(container) } } label: { Image(systemName: "stop.fill") }
                    .help("Stop")
            } else {
                Button { Task { await model.start(container) } } label: { Image(systemName: "play.fill") }
                    .help("Start")
            }
            Button(action: onDelete) { Image(systemName: "trash") }
                .help("Delete")
        }
        .buttonStyle(.borderless)
        .disabled(model.isBusy(container.id))
    }
}

private struct ProjectRowActions: View {
    let model: AppModel
    let project: ComposeProject
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            // One-shot services (migrations, bucket setup) exit on their own, so a healthy
            // project is often only partly running; offer Stop whenever anything runs.
            if project.isRunning {
                Button { Task { await model.stopProject(project) } } label: { Image(systemName: "stop.fill") }
                    .help("Stop all services")
            } else {
                Button { Task { await model.startProject(project) } } label: { Image(systemName: "play.fill") }
                    .help("Start all services in dependency order")
            }
            Button(action: onDelete) { Image(systemName: "trash") }
                .help("Delete the project's containers")
        }
        .buttonStyle(.borderless)
        .disabled(model.isBusy(project.id))
    }
}

struct ContainerMenuItems: View {
    let model: AppModel
    let container: ContainerSummary
    let onDelete: () -> Void

    var body: some View {
        if container.isRunning {
            Button("Stop") { Task { await model.stop(container) } }
            Button("Restart") { Task { await model.restart(container) } }
            Button("Kill") { Task { await model.kill(container) } }
            Divider()
            Button("Open Shell in Terminal") { model.openShell(in: container) }
            ForEach(container.ports.filter { $0.proto == "tcp" }, id: \.self) { port in
                Button("Open localhost:\(port.hostPort)") {
                    if let url = URL(string: "http://localhost:\(port.hostPort)") { NSWorkspace.shared.open(url) }
                }
            }
        } else {
            Button("Start") { Task { await model.start(container) } }
        }
        Divider()
        Button("Copy ID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(container.id, forType: .string)
        }
        Divider()
        Button("Delete…", role: .destructive, action: onDelete)
    }
}

struct ProjectMenuItems: View {
    let model: AppModel
    let project: ComposeProject
    let onDelete: () -> Void

    var body: some View {
        if project.state != .running {
            Button("Start All") { Task { await model.startProject(project) } }
        }
        if project.isRunning {
            Button("Stop All") { Task { await model.stopProject(project) } }
            Button("Restart All") { Task { await model.restartProject(project) } }
        }
        if let dir = project.workingDirectory {
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: dir)) }
            Button("Open in Terminal") { ProjectFolder.openInTerminal(dir) }
        }
        Divider()
        Button("Delete Containers…", role: .destructive, action: onDelete)
    }
}

enum ProjectFolder {
    static func openInTerminal(_ path: String) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}
