import ContainerKit
import SwiftUI

struct RunContainerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var spec: RunSpec
    @State private var limitCPU = false
    @State private var cpus = 2
    @State private var limitMemory = false
    @State private var memoryGiB = 2.0
    @State private var isRunning = false
    @State private var failure: String?

    init(prefillImage: String?) {
        _spec = State(initialValue: RunSpec(image: prefillImage ?? ""))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                SwiftUI.Section {
                    TextField("Image", text: $spec.image, prompt: Text("nginx:latest"))
                    if !imageSuggestions.isEmpty {
                        Picker("Local images", selection: $spec.image) {
                            Text("Choose…").tag(spec.image)
                            ForEach(imageSuggestions, id: \.self) { Text(Format.friendlyImage($0)).tag($0) }
                        }
                    }
                    TextField("Name", text: $spec.name, prompt: Text("Optional"))
                    TextField("Command", text: $spec.command, prompt: Text("Use the image's default"))
                }

                SwiftUI.Section("Ports") {
                    ForEach($spec.ports) { $port in
                        HStack {
                            TextField("Host", text: $port.hostPort, prompt: Text("8080")).frame(width: 80)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            TextField("Container", text: $port.containerPort, prompt: Text("80")).frame(width: 80)
                            Picker("", selection: $port.proto) { Text("TCP").tag("tcp"); Text("UDP").tag("udp") }
                                .labelsHidden().frame(width: 80)
                            Spacer()
                            RemoveButton { spec.ports.removeAll { $0.id == port.id } }
                        }
                    }
                    Button("Add Port") { spec.ports.append(.init()) }
                }

                SwiftUI.Section("Volumes") {
                    ForEach($spec.volumes) { $volume in
                        HStack {
                            TextField("Host path or volume", text: $volume.source)
                            Button("Choose…") { chooseFolder { volume.source = $0 } }
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            TextField("Container path", text: $volume.destination, prompt: Text("/data"))
                            Toggle("RO", isOn: $volume.readOnly).toggleStyle(.checkbox).help("Read-only")
                            RemoveButton { spec.volumes.removeAll { $0.id == volume.id } }
                        }
                    }
                    Button("Add Volume") { spec.volumes.append(.init()) }
                }

                SwiftUI.Section("Environment") {
                    ForEach($spec.environment) { $env in
                        HStack {
                            TextField("KEY", text: $env.key).monospaced()
                            Text("=").foregroundStyle(.secondary)
                            TextField("value", text: $env.value).monospaced()
                            RemoveButton { spec.environment.removeAll { $0.id == env.id } }
                        }
                    }
                    Button("Add Variable") { spec.environment.append(.init()) }
                }

                SwiftUI.Section("Resources") {
                    Toggle("Limit CPUs", isOn: $limitCPU)
                    if limitCPU {
                        Stepper("\(cpus) CPU\(cpus == 1 ? "" : "s")", value: $cpus, in: 1...ProcessInfo.processInfo.processorCount)
                    }
                    Toggle("Limit memory", isOn: $limitMemory)
                    if limitMemory {
                        Stepper(String(format: "%.1f GiB", memoryGiB), value: $memoryGiB, in: 0.25...64, step: 0.25)
                    }
                    Text("Each container runs in its own lightweight VM. Without limits it gets the runtime's defaults.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                SwiftUI.Section("Options") {
                    if !model.networks.isEmpty {
                        Picker("Network", selection: $spec.network) {
                            Text("Default").tag("")
                            ForEach(model.networks.filter { !$0.isBuiltin }) { Text($0.name).tag($0.name) }
                        }
                    }
                    Toggle("Remove when stopped", isOn: $spec.removeWhenStopped)
                    Toggle("Use Rosetta for x86-64 binaries", isOn: $spec.rosetta)
                }
            }
            .formStyle(.grouped)

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .textSelection(.enabled)
            }

            HStack {
                if isRunning {
                    ProgressView().controlSize(.small)
                    Text("Pulling and starting… large images can take a while.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Run") { Task { await run() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(spec.image.trimmingCharacters(in: .whitespaces).isEmpty || isRunning)
            }
            .padding(16)
        }
        .frame(width: 620, height: 640)
    }

    private var imageSuggestions: [String] {
        model.images.filter { !$0.isInfrastructure }.map(\.reference)
    }

    private func run() async {
        var spec = spec
        spec.cpus = limitCPU ? cpus : nil
        spec.memoryMiB = limitMemory ? Int(memoryGiB * 1024) : nil
        failure = nil
        do {
            try spec.validate()
        } catch {
            failure = error.localizedDescription
            return
        }
        isRunning = true
        defer { isRunning = false }
        do {
            _ = try await model.run(spec)
            dismiss()
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func chooseFolder(_ completion: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { completion(url.path) }
    }
}

private struct RemoveButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
            .buttonStyle(.borderless)
            .help("Remove")
    }
}
