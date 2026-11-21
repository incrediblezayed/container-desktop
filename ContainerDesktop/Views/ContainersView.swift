import ContainerKit
import SwiftUI

struct ContainersView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var showStopped = true
    @State private var pendingDelete: ContainerSummary?
    @State private var sortOrder = [KeyPathComparator(\ContainerSummary.id)]

    private var filtered: [ContainerSummary] {
        let base = model.containers.filter { showStopped || $0.isRunning }
        let matched = search.isEmpty ? base : base.filter {
            $0.id.localizedCaseInsensitiveContains(search) || $0.image.localizedCaseInsensitiveContains(search)
        }
        return matched.sorted(using: sortOrder)
    }

    private var selected: ContainerSummary? {
        model.containers.first { $0.id == model.selectedContainerID }
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
                        .frame(minWidth: 420)
                    if let selected {
                        ContainerDetailView(container: selected)
                            .environment(model) // HSplitView panes are separate AppKit hosts
                            .id(selected.id)
                            .frame(minWidth: 360, idealWidth: 440)
                    }
                }
            }
        }
        .navigationTitle("Containers")
        .navigationSubtitle("\(model.runningCount) running · \(model.containers.count) total")
        .searchable(text: $search, placement: .toolbar, prompt: "Filter containers")
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $showStopped) { Label("Show Stopped", systemImage: "eye") }
                    .help("Show stopped containers")
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
    }

    private var table: some View {
        @Bindable var model = model
        return Table(filtered, selection: $model.selectedContainerID, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.id) { c in
                HStack(spacing: 6) {
                    if model.isBusy(c.id) { ProgressView().controlSize(.mini) }
                    Text(c.id).fontWeight(.medium)
                }
            }
            .width(min: 120, ideal: 160)
            TableColumn("Image", value: \.image) { c in
                Text(Format.friendlyImage(c.image)).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 120, ideal: 200)
            TableColumn("State") { c in StateBadge(state: c.state) }
                .width(90)
            TableColumn("CPU") { c in
                Text(c.isRunning ? Format.percent(model.stats[c.id]?.cpuUtilization) : "—").monospacedDigit()
            }
            .width(60)
            TableColumn("Memory") { c in
                Text(c.isRunning ? Format.bytes(model.stats[c.id]?.memoryUsageBytes) : "—").monospacedDigit()
            }
            .width(80)
            TableColumn("Ports") { c in
                Text(c.ports.map(\.display).joined(separator: ", ")).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 80, ideal: 120)
            TableColumn("") { c in
                RowActions(model: model, container: c, onDelete: { pendingDelete = c })
            }
            .width(70)
        }
        .contextMenu(forSelectionType: ContainerSummary.ID.self) { ids in
            if let id = ids.first, let c = model.containers.first(where: { $0.id == id }) {
                ContainerMenuItems(model: model, container: c, onDelete: { pendingDelete = c })
            }
        } primaryAction: { ids in
            model.selectedContainerID = ids.first
        }
    }
}

/// Table cells and context menus are hosted by AppKit, which doesn't reliably carry
/// SwiftUI's environment into them (rows created during an update crashed with
/// "No Observable object of type AppModel found"), so they take the model explicitly.
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
