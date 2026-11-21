import ContainerKit
import SwiftUI

// MARK: - Volumes

struct VolumesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: VolumeSummary.ID?
    @State private var isCreating = false
    @State private var pendingDelete: VolumeSummary?

    var body: some View {
        Group {
            if model.volumes.isEmpty {
                EmptyStateView(title: "No volumes", symbol: "externaldrive",
                               message: "Volumes keep data around after a container is deleted.") {
                    Button("Create Volume…") { isCreating = true }.buttonStyle(.borderedProminent)
                }
            } else {
                Table(model.volumes, selection: $selection) {
                    TableColumn("Name") { v in
                        HStack(spacing: 6) {
                            if model.isBusy("volume:\(v.name)") { ProgressView().controlSize(.mini) }
                            Text(v.name).fontWeight(.medium)
                            if v.isAnonymous { Text("anonymous").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    TableColumn("Format") { v in Text(v.format).foregroundStyle(.secondary) }.width(70)
                    TableColumn("Used") { v in Text(Format.bytes(v.allocatedBytes())).monospacedDigit() }.width(80)
                    TableColumn("Capacity") { v in Text(Format.bytes(v.sizeBytes)).monospacedDigit().foregroundStyle(.secondary) }.width(80)
                    TableColumn("Created") { v in Text(Format.relative(v.createdAt)).foregroundStyle(.secondary) }.width(110)
                    TableColumn("Used by") { v in
                        Text(model.containers.filter { $0.mounts.contains { $0.kind == "volume" && $0.source == v.name } }.map(\.id).joined(separator: ", "))
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .contextMenu(forSelectionType: VolumeSummary.ID.self) { ids in
                    if let id = ids.first, let v = model.volumes.first(where: { $0.id == id }) {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: v.source)]) }
                            .disabled(v.source.isEmpty)
                        Divider()
                        Button("Delete…", role: .destructive) { pendingDelete = v }
                    }
                }
            }
        }
        .navigationTitle("Volumes")
        .toolbar {
            Button { isCreating = true } label: { Label("Create", systemImage: "plus") }
        }
        .sheet(isPresented: $isCreating) {
            NamePromptSheet(title: "Create Volume", placeholder: "data", validate: { $0.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil }) { name in
                await model.createVolume(name)
            }
        }
        .confirmationDialog("Delete volume \(pendingDelete?.name ?? "")?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { v in
            Button("Delete", role: .destructive) { Task { await model.delete(v) } }
        } message: { _ in
            Text("All data in the volume is permanently erased.")
        }
    }
}

// MARK: - Networks

struct NetworksView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: NetworkSummary.ID?
    @State private var isCreating = false
    @State private var pendingDelete: NetworkSummary?

    var body: some View {
        Table(model.networks, selection: $selection) {
            TableColumn("Name") { n in
                HStack(spacing: 6) {
                    if model.isBusy("network:\(n.name)") { ProgressView().controlSize(.mini) }
                    Text(n.name).fontWeight(.medium)
                    if n.isBuiltin { Text("built-in").font(.caption).foregroundStyle(.secondary) }
                }
            }
            TableColumn("Mode") { n in Text(n.mode).foregroundStyle(.secondary) }.width(70)
            TableColumn("Subnet") { n in Text(n.subnet ?? "—").monospaced() }.width(min: 120, ideal: 150)
            TableColumn("Gateway") { n in Text(n.gateway ?? "—").monospaced() }.width(min: 100, ideal: 130)
            TableColumn("Containers") { n in
                Text("\(model.containers.filter { $0.networks.contains { $0.network == n.name } }.count)").monospacedDigit()
            }
            .width(80)
        }
        .contextMenu(forSelectionType: NetworkSummary.ID.self) { ids in
            if let id = ids.first, let n = model.networks.first(where: { $0.id == id }), !n.isBuiltin {
                Button("Delete…", role: .destructive) { pendingDelete = n }
            }
        }
        .navigationTitle("Networks")
        .toolbar {
            Button { isCreating = true } label: { Label("Create", systemImage: "plus") }
        }
        .sheet(isPresented: $isCreating) {
            NamePromptSheet(title: "Create Network", placeholder: "backend", validate: { $0.range(of: #"^[a-z0-9](?:[a-z0-9._-]{0,61}[a-z0-9])?$"#, options: .regularExpression) != nil }) { name in
                await model.createNetwork(name)
            }
        }
        .confirmationDialog("Delete network \(pendingDelete?.name ?? "")?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { n in
            Button("Delete", role: .destructive) { Task { await model.delete(n) } }
        }
    }
}

// MARK: - System

struct SystemView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmStop = false

    var body: some View {
        Form {
            SwiftUI.Section("Runtime") {
                LabeledContent("Status") {
                    HStack(spacing: 6) { Circle().fill(.green).frame(width: 7, height: 7); Text("Running") }
                }
                LabeledContent("API server", value: model.status?.serverVersion ?? "—")
                LabeledContent("CLI", value: model.status?.clientVersion ?? "—")
                if let root = model.status?.appRoot {
                    LabeledContent("Data") {
                        Button(root) { NSWorkspace.shared.open(URL(fileURLWithPath: root)) }
                            .buttonStyle(.link)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            SwiftUI.Section("Usage") {
                LabeledContent("Containers", value: "\(model.runningCount) running of \(model.containers.count)")
                LabeledContent("Images", value: "\(model.images.count) · \(Format.bytes(model.images.reduce(Int64(0)) { $0 + $1.sizeBytes }))")
                LabeledContent("Volumes", value: "\(model.volumes.count)")
                LabeledContent("Networks", value: "\(model.networks.count)")
                LabeledContent("Memory in use", value: Format.bytes(model.stats.values.compactMap(\.memoryUsageBytes).reduce(UInt64(0), +)))
            }
            SwiftUI.Section {
                HStack {
                    Button("Stop All Containers") { Task { await model.stopAll() } }
                        .disabled(model.runningCount == 0)
                    Spacer()
                    Button("Stop Container System…", role: .destructive) { confirmStop = true }
                        .disabled(model.isBusy("system"))
                }
            } footer: {
                Text("Stopping the system stops every container and the background services. Nothing runs when no containers are running, so there's no idle VM using memory.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("System")
        .confirmationDialog("Stop the container system?", isPresented: $confirmStop) {
            Button("Stop", role: .destructive) { Task { await model.stopSystem() } }
        } message: {
            Text("All running containers will be stopped.")
        }
    }
}

// MARK: - Shared

struct NamePromptSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let placeholder: String
    let validate: (String) -> Bool
    let onCreate: (String) async -> Void
    @State private var name = ""
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title3.bold())
            TextField("Name", text: $name, prompt: Text(placeholder))
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
            if !name.isEmpty && !validate(name) {
                Text("Use letters, numbers, '.', '_' or '-', starting with a letter or number.")
                    .font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!validate(name) || working)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func create() {
        guard validate(name), !working else { return }
        working = true
        Task {
            await onCreate(name)
            dismiss()
        }
    }
}
