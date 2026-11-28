import AppKit
import ContainerKit
import Foundation
import Observation

/// A message the UI can show; keeps the action that failed so users know what broke.
struct UserFacingError: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}

enum Section: String, CaseIterable, Identifiable, Hashable {
    case containers, images, volumes, networks, system, agents
    var id: String { rawValue }

    var title: String {
        switch self {
        case .containers: "Containers"
        case .images: "Images"
        case .volumes: "Volumes"
        case .networks: "Networks"
        case .system: "System"
        case .agents: "AI Agents"
        }
    }

    var symbol: String {
        switch self {
        case .containers: "shippingbox"
        case .images: "square.stack.3d.up"
        case .volumes: "externaldrive"
        case .networks: "network"
        case .system: "cpu"
        case .agents: "sparkles"
        }
    }
}

/// Single source of truth for the window and the menu bar extra.
@Observable
@MainActor
final class AppModel {
    enum Phase: Equatable {
        case locating
        case cliMissing
        case systemStopped
        case startingSystem
        case ready
    }

    // MARK: State

    private(set) var phase: Phase = .locating
    private(set) var engine: (any ContainerEngine)?
    private(set) var status: SystemStatus?

    private(set) var containers: [ContainerSummary] = []
    private(set) var images: [ImageSummary] = []
    private(set) var volumes: [VolumeSummary] = []
    private(set) var networks: [NetworkSummary] = []
    private(set) var stats: [String: ContainerStatsSample] = [:]
    private(set) var statsHistory: [String: [StatsPoint]] = [:]

    /// Resource IDs with an action in flight, so rows can show progress and disable buttons.
    private(set) var busy: Set<String> = []
    var error: UserFacingError?
    var section: Section = .containers
    var selectedContainerID: ContainerSummary.ID?
    var isRunSheetPresented = false
    var runSheetPrefillImage: String?

    var runningCount: Int { containers.filter(\.isRunning).count }
    var grouping: ContainerGrouping { ContainerGrouping(containers) }

    func project(named name: String) -> ComposeProject? {
        grouping.projects.first { $0.name == name }
    }

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var appIsActive = true
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    @ObservationIgnored
    var cliPathOverride: String? {
        get { UserDefaults.standard.string(forKey: "cliPath").flatMap { $0.isEmpty ? nil : $0 } }
        set { UserDefaults.standard.set(newValue, forKey: "cliPath") }
    }

    init() {
        #if DEBUG
        // UI checks without driving the mouse: `--args -debugSelect project:<name>`.
        selectedContainerID = UserDefaults.standard.string(forKey: "debugSelect")
        if let name = UserDefaults.standard.string(forKey: "debugSection"), let section = Section(rawValue: name) { self.section = section }
        #endif
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appIsActive = true; self?.kick() }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appIsActive = false }
        })
    }

    // MARK: Lifecycle

    func bootstrap() async {
        phase = .locating
        guard let engine = CLIContainerEngine(cliPathOverride: cliPathOverride) else {
            self.engine = nil
            phase = .cliMissing
            return
        }
        self.engine = engine
        await refreshStatus()
        startLoops()
    }

    func startSystem() async {
        guard let engine else { return }
        phase = .startingSystem
        do {
            try await engine.startSystem()
            await refreshStatus()
            await refreshAll()
        } catch {
            phase = .systemStopped
            report("Couldn't start the container system", error)
        }
    }

    func stopSystem() async {
        guard let engine else { return }
        await perform("system", title: "Couldn't stop the container system") {
            try await engine.stopSystem()
        }
        await refreshStatus()
    }

    private func refreshStatus() async {
        guard let engine else { return }
        do {
            let status = try await engine.systemStatus()
            self.status = status
            switch status.state {
            case .running: phase = .ready
            default: if phase != .startingSystem { phase = .systemStopped }
            }
        } catch {
            phase = .systemStopped
        }
    }

    /// Polls cheaply: containers often (they change state), everything else less often.
    /// Slows down when the app is in the background; the menu bar still stays roughly current.
    private func startLoops() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                if self.phase == .ready {
                    await self.refreshContainers()
                    if tick % 4 == 0 { await self.refreshResources() }
                } else if self.phase == .systemStopped, tick % 3 == 0 {
                    await self.refreshStatus()
                    if self.phase == .ready { await self.refreshAll() }
                }
                tick += 1
                let interval: Duration = self.appIsActive ? .seconds(3) : .seconds(15)
                try? await Task.sleep(for: interval)
            }
        }

        statsTask?.cancel()
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // `stats --no-stream` itself blocks ~2s while it samples.
                if self.phase == .ready, self.appIsActive, self.runningCount > 0 {
                    await self.refreshStats()
                } else {
                    try? await Task.sleep(for: .seconds(2))
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Trigger an immediate refresh, e.g. after the app comes to the foreground.
    func kick() {
        Task { await refreshAll() }
    }

    func refreshAll() async {
        guard phase == .ready else { await refreshStatus(); return }
        await refreshContainers()
        await refreshResources()
    }

    func refreshContainers() async {
        guard let engine else { return }
        do {
            let list = try await engine.listContainers()
            containers = list.sorted { ($0.isRunning ? 0 : 1, $0.id) < ($1.isRunning ? 0 : 1, $1.id) }
            if let selected = selectedContainerID, !list.contains(where: { $0.id == selected }) {
                // Project rows are selectable too; keep them while the project exists.
                let projectName = selected.hasPrefix("project:") ? String(selected.dropFirst("project:".count)) : nil
                if projectName == nil || !list.contains(where: { $0.composeProject == projectName }) {
                    selectedContainerID = nil
                }
            }
        } catch {
            await handleRefreshFailure(error)
        }
    }

    private func refreshResources() async {
        guard let engine else { return }
        async let images = try? engine.listImages()
        async let volumes = try? engine.listVolumes()
        async let networks = try? engine.listNetworks()
        if let images = await images { self.images = images.sorted { $0.reference < $1.reference } }
        if let volumes = await volumes { self.volumes = volumes.sorted { $0.name < $1.name } }
        if let networks = await networks { self.networks = networks.sorted { ($0.isBuiltin ? 0 : 1, $0.name) < ($1.isBuiltin ? 0 : 1, $1.name) } }
    }

    private func refreshStats() async {
        guard let engine else { return }
        guard let samples = try? await engine.stats() else { return }
        let now = Date()
        var next: [String: ContainerStatsSample] = [:]
        for sample in samples {
            next[sample.id] = sample
            var history = statsHistory[sample.id] ?? []
            history.append(StatsPoint(date: now, sample: sample))
            if history.count > 90 { history.removeFirst(history.count - 90) }
            statsHistory[sample.id] = history
        }
        stats = next
        // Forget history for containers that are gone.
        let live = Set(containers.map(\.id))
        statsHistory = statsHistory.filter { live.contains($0.key) }
    }

    private func handleRefreshFailure(_ error: Error) async {
        // A failing list usually means the daemon went away; re-check instead of spamming alerts.
        await refreshStatus()
    }

    // MARK: Container actions

    /// Shared with the MCP server, so agents and buttons start things the same way.
    private var controller: ProjectController? { engine.map { ProjectController(engine: $0) } }

    func start(_ container: ContainerSummary) async {
        guard let controller else { return }
        await perform(container.id, title: "Couldn't start \(container.id)") { try await controller.start(container) }
    }

    func stop(_ container: ContainerSummary) async {
        guard let controller else { return }
        await perform(container.id, title: "Couldn't stop \(container.id)") { try await controller.stop(container) }
    }

    func kill(_ container: ContainerSummary) async {
        guard let engine else { return }
        await perform(container.id, title: "Couldn't kill \(container.id)") { try await engine.kill(container: container.id) }
    }

    func restart(_ container: ContainerSummary) async {
        guard let controller else { return }
        await perform(container.id, title: "Couldn't restart \(container.id)") { try await controller.restart(container) }
    }

    func delete(_ container: ContainerSummary) async {
        guard let engine else { return }
        await perform(container.id, title: "Couldn't delete \(container.id)") {
            try await engine.delete(container: container.id, force: container.isRunning)
        }
    }

    func stopAll() async {
        for container in containers where container.isRunning {
            await stop(container)
        }
    }

    /// Returns the new container's ID on success.
    func run(_ spec: RunSpec) async throws -> String {
        guard let engine else { throw ContainerCLIError.binaryNotFound }
        let id = try await engine.run(spec)
        await refreshAll()
        if !id.isEmpty {
            section = .containers
            selectedContainerID = containers.first { $0.id == id }?.id ?? selectedContainerID
        }
        return id
    }

    func openShell(in container: ContainerSummary) {
        guard let engine else { return }
        do {
            try TerminalLauncher.open(command: engine.shellCommand(container: container.id, shell: "sh"), title: container.id)
        } catch {
            report("Couldn't open Terminal", error)
        }
    }

    func logs(for container: ContainerSummary, follow: Bool, boot: Bool = false) -> AsyncThrowingStream<String, Error>? {
        engine?.logs(container: container.id, follow: follow, tail: 1000, boot: boot)
    }

    // MARK: Compose projects

    /// Starts a project the way `docker compose start` would; see `ProjectController`.
    func startProject(_ project: ComposeProject) async {
        guard let controller else { return }
        await performProject(project, title: "Couldn't start \(project.name)") { refresh in
            try await controller.start(project, afterStage: refresh)
        }
    }

    func stopProject(_ project: ComposeProject) async {
        guard let controller else { return }
        await performProject(project, title: "Couldn't stop \(project.name)") { _ in
            try await controller.stop(project)
        }
    }

    func restartProject(_ project: ComposeProject) async {
        guard let controller else { return }
        await performProject(project, title: "Couldn't restart \(project.name)") { refresh in
            try await controller.restart(project, afterStage: refresh)
        }
    }

    /// Deletes the project's containers, and with `removeVolumes` the volumes only it uses.
    func deleteProject(_ project: ComposeProject, removeVolumes: Bool = false) async {
        guard let controller else { return }
        await performProject(project, title: "Couldn't delete \(project.name)") { _ in
            try await controller.delete(project, removeVolumes: removeVolumes)
        }
        if selectedContainerID == project.id { selectedContainerID = nil }
    }

    private func performProject(_ project: ComposeProject, title: String,
                                _ action: (_ refresh: @escaping @Sendable () async -> Void) async throws -> Void) async {
        let ids = [project.id] + project.services.map(\.id) + project.helpers.map(\.id)
        busy.formUnion(ids)
        defer { busy.subtract(ids) }
        do {
            try await action { [weak self] in await self?.refreshContainers() }
        } catch {
            report(title, error)
        }
        await refreshAll()
    }

    func inspect(_ container: ContainerSummary) async -> String {
        guard let engine else { return "" }
        do { return try await engine.inspect(container: container.id) } catch { return error.localizedDescription }
    }

    // MARK: Updates

    /// Newest releases of the runtime pieces, checked at most every few hours.
    private(set) var latestRuntime: Updates.Release?
    private(set) var latestSocktainer: Updates.Release?
    private(set) var socktainerVersion: String?
    @ObservationIgnored private var lastUpdateCheck: Date?

    var cliURL: URL? { (engine as? CLIContainerEngine)?.runner.executableURL }

    var runtimeUpdateAvailable: Bool {
        guard let latest = latestRuntime?.version, let installed = status?.clientVersion else { return false }
        return Updates.isNewer(latest, than: installed) == true
    }

    var socktainerUpdateAvailable: Bool {
        guard let latest = latestSocktainer?.version, let installed = socktainerVersion else { return false }
        return Updates.isNewer(latest, than: installed) == true
    }

    func checkForUpdates(force: Bool = false) async {
        socktainerVersion = Socktainer.isRunning() ? try? await Socktainer.version() : nil
        if !force, let last = lastUpdateCheck, Date().timeIntervalSince(last) < 6 * 3600 { return }
        lastUpdateCheck = Date()
        async let runtime = try? Updates.latestRelease(of: Updates.containerRepository)
        async let socktainer = try? Updates.latestRelease(of: Updates.socktainerRepository)
        if let runtime = await runtime { latestRuntime = runtime }
        if let socktainer = await socktainer { latestSocktainer = socktainer }
    }

    /// Runs Apple's update script in Terminal, where it can ask for the admin password.
    /// Containers stop while it runs; images, volumes and container definitions are kept.
    func updateRuntime() {
        guard let cli = cliURL else { return }
        guard let script = Updates.containerUpdateScript(cli: cli) else {
            if let url = latestRuntime?.url { NSWorkspace.shared.open(url) }
            return
        }
        do {
            try TerminalLauncher.open(command: ["/bin/zsh", "-c", Updates.containerUpdateCommand(cli: cli, script: script)], title: "Update container")
        } catch {
            report("Couldn't open Terminal", error)
        }
    }

    // MARK: Images

    func pull(_ reference: String) -> AsyncThrowingStream<String, Error>? {
        engine?.pull(image: reference)
    }

    func didFinishPull() async { await refreshResources() }

    func delete(_ image: ImageSummary) async {
        guard let engine else { return }
        await perform(image.id, title: "Couldn't delete \(image.reference)") { try await engine.delete(image: image.reference) }
    }

    func pruneImages() async {
        guard let engine else { return }
        await perform("images", title: "Couldn't prune images") { _ = try await engine.pruneImages() }
    }

    func containersUsing(_ image: ImageSummary) -> [ContainerSummary] {
        containers.filter { $0.image == image.reference }
    }

    // MARK: Volumes & networks

    func createVolume(_ name: String) async {
        guard let engine else { return }
        await perform("volume:\(name)", title: "Couldn't create volume \(name)") { try await engine.createVolume(name: name) }
    }

    func delete(_ volume: VolumeSummary) async {
        guard let engine else { return }
        await perform("volume:\(volume.name)", title: "Couldn't delete volume \(volume.name)") { try await engine.delete(volume: volume.name) }
    }

    func createNetwork(_ name: String) async {
        guard let engine else { return }
        await perform("network:\(name)", title: "Couldn't create network \(name)") { try await engine.createNetwork(name: name) }
    }

    func delete(_ network: NetworkSummary) async {
        guard let engine else { return }
        await perform("network:\(network.name)", title: "Couldn't delete network \(network.name)") { try await engine.delete(network: network.name) }
    }

    // MARK: Helpers

    func isBusy(_ id: String) -> Bool { busy.contains(id) }

    private func perform(_ id: String, title: String, _ action: @Sendable () async throws -> Void) async {
        busy.insert(id)
        defer { busy.remove(id) }
        do {
            try await action()
        } catch {
            report(title, error)
        }
        await refreshAll()
    }

    func report(_ title: String, _ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        self.error = UserFacingError(title: title, message: message)
    }
}

struct StatsPoint: Identifiable, Hashable {
    var id: Date { date }
    let date: Date
    let sample: ContainerStatsSample
}
