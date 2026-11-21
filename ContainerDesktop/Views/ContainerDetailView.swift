import Charts
import ContainerKit
import SwiftUI

struct ContainerDetailView: View {
    @Environment(AppModel.self) private var model
    let container: ContainerSummary

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview", logs = "Logs", stats = "Stats", inspect = "Inspect"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .overview

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
            case .overview: OverviewTab(container: container)
            case .logs: LogsTab(container: container)
            case .stats: StatsTab(container: container)
            case .inspect: InspectTab(container: container)
            }
        }
        .background(.background)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(container.id).font(.title3.bold()).textSelection(.enabled)
                Text(Format.friendlyImage(container.image)).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                StateBadge(state: container.state)
            }
            Spacer()
            HStack(spacing: 6) {
                if container.isRunning {
                    Button { model.openShell(in: container) } label: { Label("Shell", systemImage: "terminal") }
                        .help("Open a shell in Terminal")
                    Button { Task { await model.restart(container) } } label: { Label("Restart", systemImage: "arrow.clockwise") }
                    Button { Task { await model.stop(container) } } label: { Label("Stop", systemImage: "stop.fill") }
                } else {
                    Button { Task { await model.start(container) } } label: { Label("Start", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                }
            }
            .labelStyle(.iconOnly)
            .controlSize(.large)
            .disabled(model.isBusy(container.id))
        }
        .padding(16)
    }
}

// MARK: - Overview

private struct OverviewTab: View {
    @Environment(AppModel.self) private var model
    let container: ContainerSummary

    var body: some View {
        Form {
            LabeledContent("Uptime", value: container.isRunning ? Format.uptime(since: container.startedAt) : "—")
            LabeledContent("Created", value: Format.relative(container.createdAt))
            if let address = container.primaryAddress {
                LabeledContent("IP address") { Text(address).textSelection(.enabled).monospaced() }
            }
            LabeledContent("Resources", value: "\(container.cpus.map { "\($0) CPU" } ?? "—") · \(Format.bytes(container.memoryBytes))")
            if let platform = container.platform, !platform.isEmpty {
                LabeledContent("Platform", value: platform + (container.rosetta ? " (Rosetta)" : ""))
            }
            if !container.command.isEmpty {
                LabeledContent("Command") {
                    Text(container.command.joined(separator: " ")).monospaced().textSelection(.enabled).lineLimit(3)
                }
            }

            if !container.ports.isEmpty {
                SwiftUI.Section("Ports") {
                    ForEach(container.ports, id: \.self) { port in
                        HStack {
                            Text(port.display).monospaced()
                            Spacer()
                            if port.proto == "tcp", container.isRunning {
                                Link("Open", destination: URL(string: "http://localhost:\(port.hostPort)")!)
                            }
                        }
                    }
                }
            }

            if !container.mounts.isEmpty {
                SwiftUI.Section("Mounts") {
                    ForEach(container.mounts, id: \.self) { mount in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mount.destination).monospaced()
                            Text("\(mount.kind): \(mount.source)\(mount.readOnly ? " (read-only)" : "")")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
            }

            if !container.environment.isEmpty {
                SwiftUI.Section("Environment") {
                    ForEach(container.environment, id: \.self) { entry in
                        Text(entry).monospaced().font(.callout).textSelection(.enabled).lineLimit(2)
                    }
                }
            }

            if !container.labels.isEmpty {
                SwiftUI.Section("Labels") {
                    ForEach(container.labels.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        LabeledContent(key, value: value)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Logs

@Observable
@MainActor
final class LogStream {
    private(set) var lines: [String] = []
    private(set) var isStreaming = false
    private(set) var failure: String?
    static let maxLines = 5_000
    @ObservationIgnored private var task: Task<Void, Never>?

    func start(_ stream: AsyncThrowingStream<String, Error>?) {
        task?.cancel()
        lines = []
        failure = nil
        guard let stream else { return }
        isStreaming = true
        task = Task { [weak self] in
            var batch: [String] = []
            var lastFlush = ContinuousClock.now
            do {
                for try await line in stream {
                    batch.append(line)
                    // Batch UI updates; a chatty container can emit thousands of lines a second.
                    if batch.count >= 200 || ContinuousClock.now - lastFlush > .milliseconds(100) {
                        self?.append(batch)
                        batch.removeAll(keepingCapacity: true)
                        lastFlush = .now
                    }
                }
                self?.append(batch)
            } catch {
                self?.append(batch)
                if !Task.isCancelled { self?.failure = error.localizedDescription }
            }
            self?.isStreaming = false
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isStreaming = false
    }

    func clear() { lines.removeAll() }

    private func append(_ batch: [String]) {
        guard !batch.isEmpty else { return }
        lines.append(contentsOf: batch)
        if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
    }
}

private struct LogsTab: View {
    @Environment(AppModel.self) private var model
    let container: ContainerSummary
    @State private var stream = LogStream()
    @State private var filter = ""
    @State private var follow = true

    private var visible: [(offset: Int, element: String)] {
        let all = Array(stream.lines.enumerated())
        return filter.isEmpty ? all : all.filter { $0.element.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                Toggle("Follow", isOn: $follow)
                    .toggleStyle(.checkbox)
                Button { stream.clear() } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Clear")
                Button { copyAll() } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("Copy logs")
            }
            .padding(10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visible, id: \.offset) { item in
                            Text(item.element.isEmpty ? " " : item.element)
                                .font(.system(.callout, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(item.offset)
                        }
                    }
                    .padding(10)
                }
                .overlay {
                    if stream.lines.isEmpty {
                        if let failure = stream.failure {
                            ContentUnavailableView("Couldn't read logs", systemImage: "exclamationmark.triangle", description: Text(failure))
                        } else if !stream.isStreaming {
                            ContentUnavailableView("No output", systemImage: "text.alignleft")
                        }
                    }
                }
                .onChange(of: stream.lines.count) {
                    if follow, let last = visible.last { proxy.scrollTo(last.offset, anchor: .bottom) }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .task(id: "\(container.id)-\(container.isRunning)") {
            stream.start(model.logs(for: container, follow: container.isRunning))
        }
        .onDisappear { stream.stop() }
    }

    private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(visible.map(\.element).joined(separator: "\n"), forType: .string)
    }
}

// MARK: - Stats

private struct StatsTab: View {
    @Environment(AppModel.self) private var model
    let container: ContainerSummary

    var body: some View {
        let history = model.statsHistory[container.id] ?? []
        let latest = model.stats[container.id]
        Group {
            if !container.isRunning {
                ContentUnavailableView("Not running", systemImage: "chart.xyaxis.line", description: Text("Start the container to see live resource usage."))
            } else if history.isEmpty {
                ProgressView("Sampling…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                            GridRow {
                                Metric(title: "CPU", value: Format.percent(latest?.cpuUtilization))
                                Metric(title: "Memory", value: "\(Format.bytes(latest?.memoryUsageBytes)) / \(Format.bytes(latest?.memoryLimitBytes))")
                                Metric(title: "Processes", value: latest?.numProcesses.map(String.init) ?? "—")
                            }
                            GridRow {
                                Metric(title: "Net in / out", value: "\(Format.bytes(latest?.networkRxBytes)) / \(Format.bytes(latest?.networkTxBytes))")
                                Metric(title: "Disk read / write", value: "\(Format.bytes(latest?.blockReadBytes)) / \(Format.bytes(latest?.blockWriteBytes))")
                            }
                        }

                        ChartCard(title: "CPU (% of one core)") {
                            Chart(history) { point in
                                AreaMark(x: .value("Time", point.date), y: .value("CPU", (point.sample.cpuUtilization ?? 0) * 100))
                                    .foregroundStyle(.blue.opacity(0.2))
                                LineMark(x: .value("Time", point.date), y: .value("CPU", (point.sample.cpuUtilization ?? 0) * 100))
                                    .foregroundStyle(.blue)
                            }
                            .chartYScale(domain: 0...max(100, history.map { ($0.sample.cpuUtilization ?? 0) * 100 }.max() ?? 100))
                        }

                        ChartCard(title: "Memory (MiB)") {
                            Chart(history) { point in
                                let mib = Double(point.sample.memoryUsageBytes ?? 0) / 1_048_576
                                AreaMark(x: .value("Time", point.date), y: .value("Memory", mib))
                                    .foregroundStyle(.purple.opacity(0.2))
                                LineMark(x: .value("Time", point.date), y: .value("Memory", mib))
                                    .foregroundStyle(.purple)
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
    }
}

private struct Metric: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body.monospacedDigit())
        }
    }
}

private struct ChartCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour().minute().second()) } }
                .frame(height: 140)
        }
    }
}

// MARK: - Inspect

private struct InspectTab: View {
    @Environment(AppModel.self) private var model
    let container: ContainerSummary
    @State private var text: String?

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text ?? "")
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .overlay { if text == nil { ProgressView() } }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: container.id) { text = await model.inspect(container) }
    }
}
