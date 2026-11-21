import ContainerKit
import SwiftUI

struct ImagesView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var showInfrastructure = false
    @State private var selection: ImageSummary.ID?
    @State private var isPullPresented = false
    @State private var pendingDelete: ImageSummary?
    @State private var confirmPrune = false
    @State private var sortOrder = [KeyPathComparator(\ImageSummary.reference)]

    private var filtered: [ImageSummary] {
        model.images
            .filter { showInfrastructure || !$0.isInfrastructure }
            .filter { search.isEmpty || $0.reference.localizedCaseInsensitiveContains(search) }
            .sorted(using: sortOrder)
    }

    private var totalSize: Int64 { model.images.reduce(0) { $0 + $1.sizeBytes } }

    var body: some View {
        Group {
            if filtered.isEmpty && search.isEmpty {
                EmptyStateView(title: "No images", symbol: "square.stack.3d.up",
                               message: "Pull an image from Docker Hub, GitHub Container Registry or any OCI registry.") {
                    Button("Pull Image…") { isPullPresented = true }.buttonStyle(.borderedProminent)
                }
            } else {
                Table(filtered, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Repository", value: \.reference) { image in
                        HStack(spacing: 6) {
                            if model.isBusy(image.id) { ProgressView().controlSize(.mini) }
                            Text(Format.friendlyImage(image.repository)).fontWeight(.medium)
                        }
                    }
                    .width(min: 180, ideal: 260)
                    TableColumn("Tag") { image in Text(image.tag).foregroundStyle(.secondary) }
                        .width(min: 60, ideal: 90)
                    TableColumn("Digest") { image in Text(Format.shortDigest(image.digest)).monospaced().foregroundStyle(.secondary) }
                        .width(110)
                    TableColumn("Platforms") { image in Text(image.platforms.joined(separator: ", ")).foregroundStyle(.secondary).lineLimit(1) }
                        .width(min: 80, ideal: 120)
                    TableColumn("Size", value: \.sizeBytes) { image in Text(Format.bytes(image.sizeBytes)).monospacedDigit() }
                        .width(80)
                    TableColumn("Created") { image in Text(Format.relative(image.createdAt)).foregroundStyle(.secondary) }
                        .width(min: 90, ideal: 110)
                    TableColumn("In use") { image in
                        let count = model.containersUsing(image).count
                        Text(count == 0 ? "" : "\(count)").foregroundStyle(.secondary)
                    }
                    .width(50)
                }
                .contextMenu(forSelectionType: ImageSummary.ID.self) { ids in
                    if let id = ids.first, let image = model.images.first(where: { $0.id == id }) {
                        Button("Run…") { runImage(image) }
                        Button("Copy Reference") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(image.reference, forType: .string)
                        }
                        Divider()
                        Button("Delete…", role: .destructive) { pendingDelete = image }
                    }
                } primaryAction: { ids in
                    if let id = ids.first, let image = model.images.first(where: { $0.id == id }) { runImage(image) }
                }
            }
        }
        .navigationTitle("Images")
        .navigationSubtitle("\(model.images.count) images · \(Format.bytes(totalSize))")
        .searchable(text: $search, placement: .toolbar, prompt: "Filter images")
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $showInfrastructure) { Label("Show Runtime Images", systemImage: "gearshape") }
                    .help("Show images the runtime uses internally, such as the VM init filesystem")
                Button { confirmPrune = true } label: { Label("Prune", systemImage: "scissors") }
                    .help("Remove dangling images")
                    .disabled(model.isBusy("images"))
                Button { isPullPresented = true } label: { Label("Pull", systemImage: "arrow.down.circle") }
                    .help("Pull an image")
            }
        }
        .sheet(isPresented: $isPullPresented) { PullImageSheet().environment(model) }
        .confirmationDialog("Delete \(pendingDelete.map { Format.friendlyImage($0.reference) } ?? "")?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { image in
            Button("Delete", role: .destructive) { Task { await model.delete(image) } }
        } message: { image in
            let users = model.containersUsing(image)
            Text(users.isEmpty ? "You can pull it again later." : "Used by \(users.map(\.id).joined(separator: ", ")). Deleting may fail until those containers are removed.")
        }
        .confirmationDialog("Remove dangling images?", isPresented: $confirmPrune) {
            Button("Prune", role: .destructive) { Task { await model.pruneImages() } }
        } message: {
            Text("This runs `container image prune` and removes images that have no tag and aren't used.")
        }
    }

    private func runImage(_ image: ImageSummary) {
        model.runSheetPrefillImage = image.reference
        model.isRunSheetPresented = true
    }
}

struct PullImageSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var reference = ""
    @State private var output: [String] = []
    @State private var isPulling = false
    @State private var failure: String?
    @State private var finished = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pull Image").font(.title3.bold())
            TextField("Image reference", text: $reference, prompt: Text("e.g. postgres:17 or ghcr.io/org/app:1.2"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(pull)
                .disabled(isPulling)
            if !output.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(output.enumerated()), id: \.offset) { index, line in
                                Text(line).font(.system(.caption, design: .monospaced)).id(index)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                    .frame(height: 160)
                    .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
                    .onChange(of: output.count) { proxy.scrollTo(output.count - 1) }
                }
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                if isPulling { ProgressView().controlSize(.small) }
                if finished { Label("Pulled", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                Spacer()
                Button(finished ? "Done" : "Cancel") {
                    task?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                if !finished {
                    Button("Pull", action: pull)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(reference.trimmingCharacters(in: .whitespaces).isEmpty || isPulling)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func pull() {
        let ref = reference.trimmingCharacters(in: .whitespaces)
        guard !ref.isEmpty, !isPulling, let stream = model.pull(ref) else { return }
        isPulling = true
        failure = nil
        output = []
        task = Task {
            do {
                for try await line in stream where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    output.append(line)
                    if output.count > 400 { output.removeFirst(output.count - 400) }
                }
                finished = true
            } catch {
                if !Task.isCancelled { failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            }
            isPulling = false
            await model.didFinishPull()
        }
    }
}
