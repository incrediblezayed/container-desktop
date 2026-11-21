import Foundation

// Docker Compose (through Socktainer) labels every container it creates. These helpers read
// those labels so the UI can group a project's containers and manage them together, the way
// Docker Desktop does.

/// One `depends_on` entry, from the `com.docker.compose.depends-on` label
/// (`service:condition:restart`, comma separated).
public struct ComposeDependency: Hashable, Sendable {
    public enum Condition: Hashable, Sendable {
        case started, healthy, completedSuccessfully
        case other(String)
    }

    public var service: String
    public var condition: Condition

    public init(service: String, condition: Condition) {
        self.service = service
        self.condition = condition
    }

    static func parse(_ label: String) -> [ComposeDependency] {
        label.split(separator: ",").compactMap { entry in
            let parts = entry.split(separator: ":", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard let service = parts.first, !service.isEmpty else { return nil }
            let condition: Condition = switch parts.count > 1 ? parts[1] : "service_started" {
            case "service_started": .started
            case "service_healthy": .healthy
            case "service_completed_successfully": .completedSuccessfully
            case let other: .other(other)
            }
            return ComposeDependency(service: service, condition: condition)
        }
    }
}

/// A Docker-style health check, from Socktainer's `socktainer.healthcheck` label.
public struct HealthCheck: Hashable, Sendable, Decodable {
    public var test: [String]
    /// Nanoseconds, as in the Docker API.
    public var interval: Int64?
    public var timeout: Int64?
    public var retries: Int?

    private enum CodingKeys: String, CodingKey {
        case test = "Test", interval = "Interval", timeout = "Timeout", retries = "Retries"
    }

    public init(test: [String], interval: Int64? = nil, timeout: Int64? = nil, retries: Int? = nil) {
        self.test = test; self.interval = interval; self.timeout = timeout; self.retries = retries
    }

    /// The process to run inside the container, or nil when the check is disabled.
    public var command: [String]? {
        guard let kind = test.first else { return nil }
        switch kind {
        case "CMD-SHELL": return test.count > 1 ? ["sh", "-c", test.dropFirst().joined(separator: " ")] : nil
        case "CMD": return test.count > 1 ? Array(test.dropFirst()) : nil
        case "NONE": return nil
        default: return test // Docker treats a bare list as CMD
        }
    }

    public var intervalDuration: Duration {
        guard let interval, interval > 0 else { return .seconds(2) }
        return .nanoseconds(interval)
    }

    public var timeoutDuration: Duration {
        guard let timeout, timeout > 0 else { return .seconds(30) }
        return .nanoseconds(timeout)
    }
}

extension ContainerSummary {
    public var composeProject: String? { labels["com.docker.compose.project"].flatMap { $0.isEmpty ? nil : $0 } }
    public var composeService: String? { labels["com.docker.compose.service"] }
    public var composeWorkingDirectory: String? { labels["com.docker.compose.project.working-dir"] }
    public var composeConfigFiles: [String] {
        labels["com.docker.compose.project.config-files"]?.split(separator: ",").map(String.init) ?? []
    }
    public var composeDependencies: [ComposeDependency] {
        labels["com.docker.compose.depends-on"].map(ComposeDependency.parse) ?? []
    }

    public var healthCheck: HealthCheck? {
        guard let json = labels["socktainer.healthcheck"], let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(HealthCheck.self, from: data)
    }

    /// Infrastructure that Socktainer or BuildKit creates: per-network DNS servers and the
    /// buildx builder. Users rarely want to see or manage these directly.
    public var isHelper: Bool {
        labels["socktainer.role"] != nil || id.hasPrefix("buildx_buildkit_")
    }

    /// The network a Socktainer helper serves, if any.
    public var helperNetwork: String? { labels["socktainer.network"] }

    /// Short name for display inside a project: the service, or the ID.
    public var displayName: String { composeService ?? id }
}

/// The containers of one Compose project.
public struct ComposeProject: Identifiable, Hashable, Sendable {
    public var name: String
    public var services: [ContainerSummary]
    /// Socktainer helpers serving this project's networks (its DNS server).
    public var helpers: [ContainerSummary]

    public var id: String { "project:" + name }
    public var workingDirectory: String? { services.lazy.compactMap(\.composeWorkingDirectory).first }
    public var configFiles: [String] { services.first?.composeConfigFiles ?? [] }
    public var runningCount: Int { services.filter(\.isRunning).count }
    public var isRunning: Bool { runningCount > 0 }

    public var state: State {
        switch runningCount {
        case 0: .stopped
        case services.count: .running
        default: .partial
        }
    }

    public enum State: Sendable { case running, partial, stopped }

    /// Services whose resolv.conf points at a DNS server other than the project's running
    /// helper. Apple's runtime never hands a freed address out again, so a helper that was
    /// stopped or recreated comes back on a new IP while services keep the old one; their
    /// names then stop resolving until the services are recreated.
    public func servicesWithStaleDNS() -> [ContainerSummary] {
        let helperAddresses = Set(helpers.filter { $0.isRunning && $0.labels["socktainer.role"] == "dns" }.compactMap(\.primaryAddress))
        guard !helperAddresses.isEmpty else { return [] }
        return services.filter { service in
            let private192 = service.dnsNameservers.filter { $0.hasPrefix("192.168.") }
            return !private192.isEmpty && private192.allSatisfy { !helperAddresses.contains($0) }
        }
    }

    /// Services grouped into stages: every service's dependencies are in an earlier stage.
    /// Unknown dependencies are ignored; a cycle is broken by putting the rest in one stage.
    public func startStages() -> [[ContainerSummary]] {
        let byService = Dictionary(services.map { ($0.displayName, $0) }, uniquingKeysWith: { a, _ in a })
        var remaining = services
        var placed = Set<String>()
        var stages: [[ContainerSummary]] = []
        while !remaining.isEmpty {
            let ready = remaining.filter { c in
                c.composeDependencies.allSatisfy { placed.contains($0.service) || byService[$0.service] == nil }
            }
            let stage = ready.isEmpty ? remaining : ready
            stages.append(stage.sorted { $0.displayName < $1.displayName })
            placed.formUnion(stage.map(\.displayName))
            remaining.removeAll { c in stage.contains { $0.id == c.id } }
        }
        return stages
    }

    /// The strongest condition any service waits on for `service`.
    public func requiredCondition(for service: String) -> ComposeDependency.Condition? {
        let conditions = services.flatMap(\.composeDependencies).filter { $0.service == service }.map(\.condition)
        if conditions.contains(.healthy) { return .healthy }
        if conditions.contains(.completedSuccessfully) { return .completedSuccessfully }
        return conditions.isEmpty ? nil : .started
    }
}

/// How the container list is organised: Compose projects, standalone containers, and
/// helpers that don't belong to any project.
public struct ContainerGrouping: Sendable {
    public var projects: [ComposeProject]
    public var standalone: [ContainerSummary]
    public var helpers: [ContainerSummary]

    public init(_ containers: [ContainerSummary]) {
        var byProject: [String: [ContainerSummary]] = [:]
        var standalone: [ContainerSummary] = []
        var helpers: [ContainerSummary] = []
        for c in containers {
            if c.isHelper { helpers.append(c) }
            else if let project = c.composeProject { byProject[project, default: []].append(c) }
            else { standalone.append(c) }
        }

        var projects: [ComposeProject] = []
        for (name, services) in byProject {
            let networks = Set(services.flatMap { $0.configuredNetworks + $0.networks.map(\.network) })
            let owned = helpers.filter { $0.helperNetwork.map(networks.contains) ?? false }
            projects.append(ComposeProject(name: name, services: Self.order(services), helpers: owned))
        }
        let ownedIDs = Set(projects.flatMap { $0.helpers.map(\.id) })

        self.projects = projects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        self.standalone = Self.order(standalone)
        self.helpers = Self.order(helpers.filter { !ownedIDs.contains($0.id) })
    }

    /// Running first, then by name.
    static func order(_ list: [ContainerSummary]) -> [ContainerSummary] {
        list.sorted {
            ($0.isRunning ? 0 : 1, $0.displayName) < ($1.isRunning ? 0 : 1, $1.displayName)
        }
    }
}
