import Foundation

/// Starts, stops and deletes containers and Compose projects the way Docker Compose would.
/// The app and the MCP server both go through it, so agents get the same ordering, health
/// checks and Socktainer handling as the buttons in the window.
public struct ProjectController: Sendable {
    public let engine: any ContainerEngine
    public let socketPath: String
    /// How long a started service must stay up before a start counts as done. Services that
    /// crash on boot (a damaged volume, a bad config) often pass a first health check.
    public var settleTime: Duration
    /// The exit code of a stopped container, when something recorded it (Socktainer does;
    /// Apple's runtime doesn't). A setup job that exited 0 isn't a failed start.
    public var exitCode: @Sendable (ContainerSummary) async -> Int?

    public init(engine: any ContainerEngine, socketPath: String = Socktainer.defaultSocketPath,
                settleTime: Duration = .seconds(2),
                exitCode: (@Sendable (ContainerSummary) async -> Int?)? = nil) {
        self.engine = engine
        self.socketPath = socketPath
        self.settleTime = settleTime
        self.exitCode = exitCode ?? { c in
            c.isSocktainerManaged ? await Socktainer.exitCode(container: c.id, socketPath: socketPath) : nil
        }
    }

    public func grouping() async throws -> ContainerGrouping {
        ContainerGrouping(try await engine.listContainers())
    }

    public func project(named name: String) async throws -> ComposeProject? {
        try await grouping().projects.first { $0.name == name }
    }

    // MARK: Containers

    /// Socktainer registers a container's DNS names only when it starts the container itself,
    /// so its containers go through its API while it runs; everything else uses the CLI.
    public func start(_ c: ContainerSummary) async throws {
        if c.isSocktainerManaged, Socktainer.isRunning(socketPath: socketPath) {
            try await Socktainer.start(container: c.id, socketPath: socketPath)
        } else {
            try await engine.start(container: c.id)
        }
    }

    public func stop(_ c: ContainerSummary) async throws {
        if c.isSocktainerManaged, Socktainer.isRunning(socketPath: socketPath) {
            try await Socktainer.stop(container: c.id, socketPath: socketPath)
        } else {
            try await engine.stop(container: c.id)
        }
    }

    public func restart(_ c: ContainerSummary) async throws {
        if c.isRunning { try await stop(c) }
        try await start(c)
    }

    // MARK: Projects

    /// Starts a project the way `docker compose start` would: Socktainer's DNS helper first
    /// (service names resolve through it), then services in `depends_on` order, waiting for
    /// health checks and one-shot jobs that later services depend on.
    ///
    /// `afterStage` runs after each group of services starts, so a UI can refresh.
    public func start(_ snapshot: ComposeProject, afterStage: @Sendable () async -> Void = {}) async throws {
        // Work from the runtime's state now: Socktainer starts its own helpers when it
        // launches, so a snapshot taken a moment ago may already be wrong.
        let project = try await self.project(named: snapshot.name) ?? snapshot
        if project.needsSocktainer, !Socktainer.isRunning(socketPath: socketPath) {
            throw ProjectError.socktainerNotRunning
        }
        for helper in project.helpers where !helper.isRunning {
            do {
                try await engine.start(container: helper.id)
            } catch where Self.isAlreadyRunning(error) {
                // Started by Socktainer in the meantime.
            }
        }
        if let current = try await self.project(named: project.name) {
            let stale = current.servicesWithStaleDNS()
            if !stale.isEmpty {
                throw ProjectError.dnsMoved(project: project.name, services: stale.map(\.displayName), command: current.recreateCommand)
            }
        }
        for stage in project.startStages() {
            let toStart = stage.filter { !$0.isRunning && !$0.isOneOff }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for c in toStart { group.addTask { try await start(c) } }
                try await group.waitForAll()
            }
            await afterStage()
            for c in stage where !c.isOneOff {
                switch project.requiredCondition(for: c.displayName) {
                case .healthy: try await waitUntilHealthy(c)
                case .completedSuccessfully: try await waitUntilExited(c)
                default: break
                }
            }
        }
        try await verifyStillRunning(project)
    }

    /// Fails when services that should be up have already exited, naming their last errors.
    func verifyStillRunning(_ project: ComposeProject) async throws {
        if settleTime > .zero { try await Task.sleep(for: settleTime) }
        guard let current = try await self.project(named: project.name) else { return }
        var down: [ContainerSummary] = []
        for c in current.services where !c.isRunning && !c.isOneOff
            && current.requiredCondition(for: c.displayName) != .completedSuccessfully {
            if await exitCode(c) == 0 { continue } // a setup job that finished
            down.append(c)
        }
        guard !down.isEmpty else { return }
        var details: [String] = []
        for c in down { details.append(contentsOf: await recentErrors(c, limit: 2).map { "\(c.displayName): \($0)" }) }
        throw ProjectError.exited(services: down.map(\.displayName), lastErrors: details)
    }

    /// The last error lines a container printed, newest last.
    public func recentErrors(_ c: ContainerSummary, scanning tail: Int = 300, limit: Int = 5) async -> [String] {
        var lines: [String] = []
        do {
            for try await line in engine.logs(container: c.id, follow: false, tail: tail, boot: false) { lines.append(line) }
        } catch {}
        let errors = lines.map { LogLine(id: 0, raw: $0) }.filter { ($0.level ?? .info) >= .error }.map(\.text)
        return Array(errors.suffix(limit))
    }

    static func isAlreadyRunning(_ error: Error) -> Bool {
        let text = String(describing: error) + ((error as? LocalizedError)?.errorDescription ?? "")
        return text.contains("got: running") || text.localizedCaseInsensitiveContains("already running")
    }

    /// Stops services in reverse dependency order. Socktainer's DNS helper keeps running:
    /// services have its IP baked into resolv.conf, and a restarted helper never gets that
    /// IP back, so stopping it would break name resolution for the whole project.
    public func stop(_ project: ComposeProject) async throws {
        for stage in project.startStages().reversed() {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for c in stage where c.isRunning { group.addTask { try await stop(c) } }
                try await group.waitForAll()
            }
        }
    }

    public func restart(_ project: ComposeProject, afterStage: @Sendable () async -> Void = {}) async throws {
        try await stop(project)
        await afterStage()
        let fresh = try await self.project(named: project.name) ?? project
        try await start(fresh, afterStage: afterStage)
    }

    /// Deletes the project's containers, like `docker compose rm`. With `removeVolumes`, also
    /// deletes the volumes its services mount that no other container uses, like
    /// `docker compose down -v`. Networks and Socktainer's helpers stay either way.
    @discardableResult
    public func delete(_ project: ComposeProject, removeVolumes: Bool = false) async throws -> [String] {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for c in project.services { group.addTask { try await engine.delete(container: c.id, force: c.isRunning) } }
            try await group.waitForAll()
        }
        guard removeVolumes else { return [] }
        let others = try await engine.listContainers()
        let stillUsed = Set(others.flatMap(\.volumeNames))
        let volumes = project.volumeNames.filter { !stillUsed.contains($0) }
        for volume in volumes { try await engine.delete(volume: volume) }
        return volumes
    }

    // MARK: Health

    public enum HealthResult: Sendable, Equatable {
        case noCheck
        case notRunning
        case passed
        case failed(exitCode: Int32, output: String)
    }

    /// Runs the container's Compose health check once, now.
    public func checkHealth(_ c: ContainerSummary) async -> HealthResult {
        guard c.isRunning else { return .notRunning }
        guard let check = c.healthCheck, let command = check.command else { return .noCheck }
        do {
            let result = try await engine.exec(container: c.id, command: command, timeout: check.timeoutDuration)
            if result.exitCode == 0 { return .passed }
            let output = (result.stdoutText + result.stderrText).trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(exitCode: result.exitCode, output: output)
        } catch {
            return .failed(exitCode: -1, output: error.localizedDescription)
        }
    }

    /// A volume whose ext4 filesystem has recorded errors: the data on it may be damaged.
    public struct VolumeDamage: Sendable, Equatable {
        public var volume: String
        public var mountPoint: String
        public var errorCount: Int
        public var firstError: Date?
    }

    /// Reads the kernel's ext4 error counters inside a running container. Each volume is its
    /// own disk image, so a VM killed mid-write (a system stop, a crash) can leave it damaged.
    public func volumeDamage(_ c: ContainerSummary) async -> [VolumeDamage] {
        let volumes = c.mounts.filter { $0.kind == "volume" && !$0.destination.isEmpty }
        guard c.isRunning, !volumes.isEmpty else { return [] }
        let script = #"cat /proc/mounts; for d in /sys/fs/ext4/*/; do [ -f "$d/errors_count" ] && echo "EXT4 $(basename "$d") $(cat "$d/errors_count") $(cat "$d/first_error_time" 2>/dev/null)"; done"#
        guard let result = try? await engine.exec(container: c.id, command: ["sh", "-c", script], timeout: .seconds(10)),
              result.exitCode == 0 else { return [] }
        return Self.parseVolumeDamage(result.stdoutText, volumes: volumes)
    }

    static func parseVolumeDamage(_ output: String, volumes: [Mount]) -> [VolumeDamage] {
        var deviceAt: [String: String] = [:] // mount point → device name
        var errors: [String: (Int, Int)] = [:] // device name → (count, first error time)
        for line in output.split(separator: "\n") {
            let f = line.split(separator: " ").map(String.init)
            if f.first == "EXT4", f.count >= 3, let count = Int(f[2]) {
                errors[f[1]] = (count, f.count > 3 ? Int(f[3]) ?? 0 : 0)
            } else if f.count >= 3, f[0].hasPrefix("/dev/"), f[2] == "ext4" {
                deviceAt[f[1]] = String(f[0].dropFirst("/dev/".count))
            }
        }
        return volumes.compactMap { mount in
            guard let device = deviceAt[mount.destination], let (count, first) = errors[device], count > 0 else { return nil }
            return VolumeDamage(volume: mount.source, mountPoint: mount.destination, errorCount: count,
                                firstError: first > 0 ? Date(timeIntervalSince1970: TimeInterval(first)) : nil)
        }
    }

    /// Runs the service's own health check (from Socktainer's label) until it passes.
    func waitUntilHealthy(_ c: ContainerSummary) async throws {
        guard let check = c.healthCheck, check.command != nil else { return }
        let attempts = min(max(check.retries ?? 30, 1), 120)
        for attempt in 0..<attempts {
            if await checkHealth(c.runningCopy) == .passed { return }
            // A service that crashed on boot will never pass; say so instead of waiting out every retry.
            if attempt > 0, try await engine.listContainers().first(where: { $0.id == c.id })?.isRunning == false {
                throw ProjectError.exited(services: [c.displayName], lastErrors: await recentErrors(c, limit: 2))
            }
            try await Task.sleep(for: check.intervalDuration)
        }
        throw ProjectError.unhealthy(c.displayName)
    }

    /// Waits for a one-shot service (a migration, a bucket setup) to finish.
    func waitUntilExited(_ c: ContainerSummary, timeout: Duration = .seconds(300)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let list = try await engine.listContainers()
            if list.first(where: { $0.id == c.id })?.isRunning != true { return }
            try await Task.sleep(for: .seconds(1))
        }
        throw ProjectError.didNotFinish(c.displayName)
    }
}

public enum ProjectError: LocalizedError, Equatable {
    case unhealthy(String)
    case didNotFinish(String)
    case socktainerNotRunning
    case dnsMoved(project: String, services: [String], command: String)
    case exited(services: [String], lastErrors: [String])

    public var errorDescription: String? {
        switch self {
        case .exited(let services, let lastErrors):
            "\(services.joined(separator: ", ")) stopped again right after starting." + (lastErrors.isEmpty
                ? " Check the logs to see why."
                : " Last errors:\n" + lastErrors.map { "• " + $0 }.joined(separator: "\n"))
        case .unhealthy(let service): "\(service) didn't pass its health check, so services that depend on it weren't started."
        case .didNotFinish(let service): "\(service) was still running after 5 minutes, so services that wait for it weren't started."
        case .dnsMoved(_, let services, let command):
            "Socktainer's DNS server for this project came back on a new address, so \(services.joined(separator: ", ")) can't look up other services by name. Recreate the containers; volumes are kept:\n\n\(command)"
        case .socktainerNotRunning: "This project was created through Socktainer, and its services find each other by name through Socktainer's DNS. Start Socktainer, then try again."
        }
    }
}

public enum Shell {
    /// Single-quotes a value for zsh/bash.
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension ContainerSummary {
    /// Containers from `docker compose run`, which a project start shouldn't bring back.
    public var isOneOff: Bool { labels["com.docker.compose.oneoff"]?.lowercased() == "true" }

    /// Names of the volumes this container mounts.
    public var volumeNames: [String] {
        mounts.filter { $0.kind == "volume" && !$0.source.isEmpty }.map(\.source)
    }

    /// The health check runs against a container the caller just started; the copy it was
    /// handed may still say stopped.
    fileprivate var runningCopy: ContainerSummary {
        var copy = self
        copy.state = .running
        return copy
    }
}

extension ComposeProject {
    /// Whether its services find each other through Socktainer's DNS helper.
    public var needsSocktainer: Bool {
        helpers.contains { $0.labels["socktainer.role"] == "dns" }
    }

    public var volumeNames: [String] {
        var seen = Set<String>()
        return services.flatMap(\.volumeNames).filter { seen.insert($0).inserted }
    }

    /// The Compose command that recreates the project with the files it was created from.
    public var recreateCommand: String {
        var parts = ["docker", "compose", "-p", name]
        for file in configFiles { parts += ["-f", Shell.quote(file)] }
        parts += ["up", "-d", "--force-recreate"]
        let command = parts.joined(separator: " ")
        guard let dir = workingDirectory else { return command }
        return "cd \(Shell.quote(dir)) && " + command
    }
}
