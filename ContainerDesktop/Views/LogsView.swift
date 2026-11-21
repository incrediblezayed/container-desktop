import AppKit
import ContainerKit
import SwiftUI
import UniformTypeIdentifiers

/// A container whose output is shown; `name` is the prefix when several are merged.
struct LogSource: Hashable {
    var name: String?
    var container: ContainerSummary
}

// MARK: - Stream

@Observable
@MainActor
final class LogStream {
    private(set) var lines: [LogLine] = []
    private(set) var isStreaming = false
    private(set) var failure: String?
    private(set) var errorCount = 0
    private(set) var warningCount = 0
    let maxLines: Int
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private var active = 0
    @ObservationIgnored private var pending: [(source: String?, text: String)] = []
    @ObservationIgnored private var flushScheduled = false
    /// Bumped on every start so tasks from an earlier stream can't touch the new one.
    @ObservationIgnored private var generation = 0

    init(maxLines: Int = 5_000) { self.maxLines = maxLines }

    func start(_ sources: [(name: String?, stream: AsyncThrowingStream<String, Error>)]) {
        stop()
        lines = []
        failure = nil
        errorCount = 0
        warningCount = 0
        active = sources.count
        isStreaming = !sources.isEmpty
        generation += 1
        let generation = generation
        for source in sources {
            tasks.append(Task { [weak self] in
                do {
                    for try await line in source.stream {
                        guard self?.generation == generation else { return }
                        self?.enqueue(line, from: source.name)
                    }
                } catch {
                    if !Task.isCancelled, self?.generation == generation { self?.failure = error.localizedDescription }
                }
                guard self?.generation == generation else { return }
                self?.flush()
                self?.finishedOne()
            })
        }
    }

    /// Lines are shown in batches: a chatty container can print thousands a second, but a
    /// quiet one must still appear promptly, so a short timer flushes whatever is waiting.
    private func enqueue(_ line: String, from source: String?) {
        pending.append((source, line))
        if pending.count >= 500 { flush(); return }
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            self?.flush()
        }
    }

    private func flush() {
        flushScheduled = false
        guard !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        append(batch)
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
        pending.removeAll()
        isStreaming = false
    }

    func clear() {
        lines.removeAll()
        errorCount = 0
        warningCount = 0
    }

    private func finishedOne() {
        active -= 1
        if active <= 0 { isStreaming = false }
    }

    private func append(_ batch: [(source: String?, text: String)]) {
        guard !batch.isEmpty else { return }
        var parsed: [LogLine] = []
        parsed.reserveCapacity(batch.count)
        for (source, raw) in batch {
            let line = LogLine(id: nextID, source: source, raw: raw)
            nextID += 1
            if line.level == .error { errorCount += 1 } else if line.level == .warning { warningCount += 1 }
            parsed.append(line)
        }
        lines.append(contentsOf: parsed)
        if lines.count > maxLines {
            let dropped = lines.prefix(lines.count - maxLines)
            for line in dropped {
                if line.level == .error { errorCount -= 1 } else if line.level == .warning { warningCount -= 1 }
            }
            lines.removeFirst(dropped.count)
        }
    }
}

// MARK: - View

struct LogsView: View {
    @Environment(AppModel.self) private var model
    let sources: [LogSource]

    enum LevelFilter: String, CaseIterable, Identifiable {
        case all = "All levels", warnings = "Warnings and errors", errors = "Errors only"
        var id: String { rawValue }
        func allows(_ level: LogLevel?) -> Bool {
            switch self {
            case .all: true
            case .warnings: (level ?? .info) >= .warning
            case .errors: level == .error
            }
        }
    }

    @State private var stream: LogStream
    @State private var filter = ""
    @State private var levelFilter = LevelFilter.all
    @State private var sourceFilter: String?
    @State private var follow = true
    @State private var wrap = true
    @State private var bootLog = false

    init(sources: [LogSource]) {
        self.sources = sources
        _stream = State(initialValue: LogStream(maxLines: sources.count > 1 ? 10_000 : 5_000))
    }

    private var isMerged: Bool { sources.count > 1 }
    private var anyRunning: Bool { sources.contains { $0.container.isRunning } }
    private var prefixWidth: Int { sources.compactMap(\.name).map(\.count).max() ?? 0 }

    private var visible: [LogLine] {
        stream.lines.filter { line in
            (sourceFilter == nil || line.source == sourceFilter)
                && levelFilter.allows(line.level)
                && (filter.isEmpty || line.text.localizedCaseInsensitiveContains(filter))
        }
    }

    /// Restart the streams when what we stream from changes.
    private var streamKey: String {
        sources.map { "\($0.container.id):\($0.container.isRunning)" }.joined(separator: ",") + (bootLog ? ":boot" : "")
    }

    var body: some View {
        let visible = visible
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollViewReader { proxy in
                ScrollView(wrap ? .vertical : [.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(visible) { line in
                            LogLineRow(line: line, highlight: filter, prefixWidth: isMerged ? prefixWidth : 0, wrap: wrap)
                                .id(line.id)
                        }
                    }
                    .padding(10)
                }
                .onScrollGeometryChange(for: Bool.self) { geo in
                    geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 24
                } action: { _, atBottom in
                    // Scrolling up pauses following; scrolling back to the end resumes it.
                    if follow != atBottom { follow = atBottom }
                }
                .overlay { emptyState(visible.isEmpty) }
                .overlay(alignment: .bottomTrailing) {
                    if !follow, !visible.isEmpty {
                        Button {
                            follow = true
                            proxy.scrollTo(visible.last?.id, anchor: .bottom)
                        } label: { Label("Latest", systemImage: "arrow.down.to.line") }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .padding(12)
                            .help("Jump to the newest line and keep following")
                    }
                }
                .onChange(of: stream.lines.last?.id) {
                    if follow, let last = visible.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            Divider()
            footer(visibleCount: visible.count)
        }
        .task(id: streamKey) {
            stream.start(sources.compactMap { source in
                model.logs(for: source.container, follow: source.container.isRunning && !bootLog, boot: bootLog)
                    .map { (name: isMerged ? source.name ?? source.container.id : nil, stream: $0) }
            })
        }
        .onDisappear { stream.stop() }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            TextField("Filter", text: $filter)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 100)
            if isMerged {
                Picker("Service", selection: $sourceFilter) {
                    Text("All services").tag(String?.none)
                    ForEach(sources.compactMap(\.name), id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Picker("Level", selection: $levelFilter) {
                ForEach(LevelFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Menu {
                Toggle("Wrap Lines", isOn: $wrap)
                if !isMerged {
                    Toggle("Show VM Boot Log", isOn: $bootLog)
                }
                Divider()
                Button("Copy Visible Lines") { copy(visible) }
                Button("Save Logs…") { save() }
                Divider()
                Button("Clear") { stream.clear() }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("More")
        }
        .padding(10)
    }

    private func footer(visibleCount: Int) -> some View {
        HStack(spacing: 12) {
            if stream.isStreaming, anyRunning, !bootLog {
                Label("Live", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(.green)
            }
            if bootLog { Text("VM boot log").foregroundStyle(.secondary) }
            Text(visibleCount == stream.lines.count ? "\(stream.lines.count) lines" : "\(visibleCount) of \(stream.lines.count) lines")
                .foregroundStyle(.secondary)
            Spacer()
            if stream.warningCount > 0 {
                Button { levelFilter = .warnings } label: {
                    Label("\(stream.warningCount)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .help("Show warnings and errors")
            }
            if stream.errorCount > 0 {
                Button { levelFilter = .errors } label: {
                    Label("\(stream.errorCount)", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                }
                .help("Show errors only")
            }
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .monospacedDigit()
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func emptyState(_ isEmpty: Bool) -> some View {
        if isEmpty {
            if let failure = stream.failure, stream.lines.isEmpty {
                ContentUnavailableView("Couldn't read logs", systemImage: "exclamationmark.triangle", description: Text(failure))
            } else if !stream.lines.isEmpty {
                ContentUnavailableView.search(text: filter)
            } else if !stream.isStreaming {
                ContentUnavailableView("No output", systemImage: "text.alignleft")
            }
        }
    }

    private func plainText(_ lines: [LogLine]) -> String {
        lines.map { line in
            guard isMerged, let source = line.source else { return line.text }
            return source.padding(toLength: prefixWidth, withPad: " ", startingAt: 0) + " | " + line.text
        }.joined(separator: "\n")
    }

    private func copy(_ lines: [LogLine]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(plainText(lines), forType: .string)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.log, .plainText]
        let base = sources.count == 1 ? sources[0].container.id : (sources.first?.container.composeProject ?? "containers")
        panel.nameFieldStringValue = "\(base).log"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try plainText(stream.lines).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            model.report("Couldn't save the logs", error)
        }
    }
}

// MARK: - Line

private struct LogLineRow: View {
    let line: LogLine
    let highlight: String
    let prefixWidth: Int
    let wrap: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if prefixWidth > 0, let source = line.source {
                Text(source.padding(toLength: prefixWidth, withPad: " ", startingAt: 0) + " │ ")
                    .foregroundStyle(LogColors.source(source))
            }
            Text(attributed)
                .lineLimit(wrap ? nil : 1)
                .fixedSize(horizontal: !wrap, vertical: false)
            if wrap { Spacer(minLength: 0) }
        }
        .font(.system(.callout, design: .monospaced))
        .textSelection(.enabled)
        .padding(.vertical, 1)
        .padding(.horizontal, 4)
        .background(rowTint, in: RoundedRectangle(cornerRadius: 3))
    }

    private var rowTint: Color {
        switch line.level {
        case .error: .red.opacity(0.08)
        case .warning: .orange.opacity(0.07)
        default: .clear
        }
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        if line.text.isEmpty { return AttributedString(" ") }
        let hasColor = line.runs.contains { $0.style.foreground != nil }
        for run in line.runs {
            var part = AttributedString(run.text)
            if let color = run.style.foreground.map(LogColors.color) {
                part.foregroundColor = color
            } else if !hasColor {
                // No colours of its own: tint by level so problems stand out.
                switch line.level {
                case .error: part.foregroundColor = .red
                case .warning: part.foregroundColor = .orange
                case .debug, .trace: part.foregroundColor = .secondary
                default: break
                }
            }
            if run.style.dim { part.foregroundColor = .secondary }
            if run.style.bold { part.inlinePresentationIntent = .stronglyEmphasized }
            if run.style.italic { part.inlinePresentationIntent = (part.inlinePresentationIntent ?? []).union(.emphasized) }
            if run.style.underline { part.underlineStyle = .single }
            result += part
        }
        if !highlight.isEmpty {
            var searchStart = result.startIndex
            while let range = result[searchStart...].range(of: highlight, options: .caseInsensitive) {
                result[range].backgroundColor = .yellow.opacity(0.45)
                searchStart = range.upperBound
            }
        }
        return result
    }
}

enum LogColors {
    /// Terminal colours mapped to system colours so they work in light and dark mode.
    static func color(_ c: ANSIColor) -> Color {
        switch c {
        case .palette(let n):
            switch n % 8 {
            case 0: return .secondary
            case 1: return Color(nsColor: .systemRed)
            case 2: return Color(nsColor: .systemGreen)
            case 3: return Color(nsColor: .systemYellow)
            case 4: return Color(nsColor: .systemBlue)
            case 5: return Color(nsColor: .systemPurple)
            case 6: return Color(nsColor: .systemTeal)
            default: return .primary
            }
        case .extended(let n):
            if n >= 232 {
                let v = 0.3 + Double(n - 232) / 23 * 0.6
                return Color(white: v)
            }
            let i = n - 16
            let levels: [Double] = [0, 0.37, 0.53, 0.69, 0.84, 1]
            return Color(red: levels[i / 36], green: levels[(i / 6) % 6], blue: levels[i % 6])
        case .rgb(let r, let g, let b):
            return Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
        }
    }

    private static let sourcePalette: [Color] = [.blue, .green, .purple, .orange, .teal, .pink, .indigo, .mint, .brown, .cyan]

    /// A stable colour per service, like `docker compose logs`.
    static func source(_ name: String) -> Color {
        let hash = name.unicodeScalars.reduce(UInt32(5381)) { ($0 &<< 5) &+ $0 &+ $1.value }
        return sourcePalette[Int(hash % UInt32(sourcePalette.count))]
    }
}
