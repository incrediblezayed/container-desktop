import Foundation

// MARK: - Containers

public enum ContainerState: String, Sendable, Codable, CaseIterable {
    case running, stopped, stopping, unknown

    public init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = ContainerState(rawValue: raw.lowercased()) ?? .unknown
    }
}

public struct PortMapping: Sendable, Hashable, Codable {
    public var hostAddress: String
    public var hostPort: UInt16
    public var containerPort: UInt16
    public var proto: String
    public var count: UInt16

    public init(hostAddress: String = "0.0.0.0", hostPort: UInt16, containerPort: UInt16, proto: String = "tcp", count: UInt16 = 1) {
        self.hostAddress = hostAddress
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.proto = proto
        self.count = count
    }

    enum CodingKeys: String, CodingKey { case hostAddress, hostPort, containerPort, proto, count }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hostAddress = c.lenient(LooseString.self, forKey: .hostAddress)?.value ?? "0.0.0.0"
        hostPort = try c.decode(UInt16.self, forKey: .hostPort)
        containerPort = try c.decode(UInt16.self, forKey: .containerPort)
        proto = c.lenient(String.self, forKey: .proto) ?? "tcp"
        count = c.lenient(UInt16.self, forKey: .count) ?? 1
    }

    public var display: String {
        let host = hostAddress == "0.0.0.0" || hostAddress.isEmpty ? "" : "\(hostAddress):"
        let range = count > 1 ? "-\(hostPort + count - 1)" : ""
        return "\(host)\(hostPort)\(range)→\(containerPort)/\(proto)"
    }
}

public struct Mount: Sendable, Hashable {
    public var kind: String
    public var source: String
    public var destination: String
    public var readOnly: Bool
}

public struct NetworkAttachment: Sendable, Hashable {
    public var network: String
    public var hostname: String
    public var ipv4Address: String?
    public var ipv4Gateway: String?
}

public struct ContainerSummary: Identifiable, Sendable, Hashable, Decodable {
    public var id: String
    public var image: String
    public var state: ContainerState
    public var startedAt: Date?
    public var createdAt: Date?
    public var command: [String]
    public var workingDirectory: String?
    public var environment: [String]
    public var ports: [PortMapping]
    public var mounts: [Mount]
    public var networks: [NetworkAttachment]
    /// Networks the container joins when it starts. `networks` only lists live
    /// attachments, which are empty while the container is stopped.
    public var configuredNetworks: [String]
    /// Nameservers written into the container's resolv.conf when it was created.
    public var dnsNameservers: [String]
    public var labels: [String: String]
    public var cpus: Int?
    public var memoryBytes: UInt64?
    public var platform: String?
    public var rosetta: Bool

    public var isRunning: Bool { state == .running }
    /// The first IPv4 address, without the CIDR prefix.
    public var primaryAddress: String? {
        networks.compactMap(\.ipv4Address).first.map { String($0.split(separator: "/").first ?? Substring($0)) }
    }

    public init(
        id: String, image: String, state: ContainerState, startedAt: Date? = nil, createdAt: Date? = nil,
        command: [String] = [], workingDirectory: String? = nil, environment: [String] = [],
        ports: [PortMapping] = [], mounts: [Mount] = [], networks: [NetworkAttachment] = [],
        configuredNetworks: [String]? = nil, dnsNameservers: [String] = [],
        labels: [String: String] = [:], cpus: Int? = nil, memoryBytes: UInt64? = nil,
        platform: String? = nil, rosetta: Bool = false
    ) {
        self.id = id; self.image = image; self.state = state; self.startedAt = startedAt
        self.createdAt = createdAt; self.command = command; self.workingDirectory = workingDirectory
        self.environment = environment; self.ports = ports; self.mounts = mounts; self.networks = networks
        self.configuredNetworks = configuredNetworks ?? networks.map(\.network)
        self.dnsNameservers = dnsNameservers
        self.labels = labels; self.cpus = cpus; self.memoryBytes = memoryBytes; self.platform = platform
        self.rosetta = rosetta
    }

    private enum Keys: String, CodingKey { case id, configuration, status }
    private enum ConfigKeys: String, CodingKey {
        case id, image, mounts, publishedPorts, labels, networks, initProcess, platform, resources, rosetta, creationDate, dns
    }
    private enum DNSKeys: String, CodingKey { case nameservers }
    private enum StatusKeys: String, CodingKey { case state, networks, startedDate }
    private enum ImageKeys: String, CodingKey { case reference }
    private enum ProcessKeys: String, CodingKey { case executable, arguments, environment, workingDirectory }
    private enum ResourceKeys: String, CodingKey { case cpus, memoryInBytes }
    private enum PlatformKeys: String, CodingKey { case os, architecture, variant }
    private enum AttachmentKeys: String, CodingKey { case network, hostname, ipv4Address, ipv4Gateway, address, gateway }
    private enum MountKeys: String, CodingKey { case type, source, destination, options }

    public init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: Keys.self)
        let config = try root.nestedContainer(keyedBy: ConfigKeys.self, forKey: .configuration)

        id = try (root.lenient(String.self, forKey: .id)) ?? config.decode(String.self, forKey: .id)

        if let imageContainer = try? config.nestedContainer(keyedBy: ImageKeys.self, forKey: .image) {
            image = imageContainer.lenient(String.self, forKey: .reference) ?? ""
        } else {
            image = ""
        }

        if let status = try? root.nestedContainer(keyedBy: StatusKeys.self, forKey: .status) {
            state = status.lenient(ContainerState.self, forKey: .state) ?? .unknown
            startedAt = status.lenient(Date.self, forKey: .startedDate)
            networks = Self.decodeAttachments(status, key: .networks)
        } else if let flatState = root.lenient(ContainerState.self, forKey: .status) {
            // Older CLI releases encoded `status` as a bare string.
            state = flatState
            startedAt = nil
            networks = []
        } else {
            state = .unknown
            startedAt = nil
            networks = []
        }

        createdAt = config.lenient(Date.self, forKey: .creationDate)
        labels = config.lenient([String: String].self, forKey: .labels) ?? [:]
        ports = config.lenient([PortMapping].self, forKey: .publishedPorts) ?? []
        rosetta = config.lenient(Bool.self, forKey: .rosetta) ?? false
        configuredNetworks = (config.lenient([ConfiguredNetwork].self, forKey: .networks) ?? []).compactMap(\.network)
        dnsNameservers = (try? config.nestedContainer(keyedBy: DNSKeys.self, forKey: .dns))
            .flatMap { $0.lenient([String].self, forKey: .nameservers) } ?? []

        if let process = try? config.nestedContainer(keyedBy: ProcessKeys.self, forKey: .initProcess) {
            let executable = process.lenient(String.self, forKey: .executable)
            let arguments = process.lenient([String].self, forKey: .arguments) ?? []
            command = (executable.map { [$0] } ?? []) + arguments
            environment = process.lenient([String].self, forKey: .environment) ?? []
            workingDirectory = process.lenient(String.self, forKey: .workingDirectory)
        } else {
            command = []; environment = []; workingDirectory = nil
        }

        if let resources = try? config.nestedContainer(keyedBy: ResourceKeys.self, forKey: .resources) {
            cpus = resources.lenient(Int.self, forKey: .cpus)
            memoryBytes = resources.lenient(UInt64.self, forKey: .memoryInBytes)
        } else {
            cpus = nil; memoryBytes = nil
        }

        if let p = try? config.nestedContainer(keyedBy: PlatformKeys.self, forKey: .platform) {
            let parts = [p.lenient(String.self, forKey: .os), p.lenient(String.self, forKey: .architecture), p.lenient(String.self, forKey: .variant)]
            platform = parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "/")
        } else {
            platform = nil
        }

        mounts = Self.decodeMounts(config)
    }

    private struct ConfiguredNetwork: Decodable { var network: String? }

    private static func decodeAttachments(_ c: KeyedDecodingContainer<StatusKeys>, key: StatusKeys) -> [NetworkAttachment] {
        guard var list = try? c.nestedUnkeyedContainer(forKey: key) else { return [] }
        var result: [NetworkAttachment] = []
        while !list.isAtEnd {
            guard let a = try? list.nestedContainer(keyedBy: AttachmentKeys.self) else { break }
            result.append(NetworkAttachment(
                network: a.lenient(String.self, forKey: .network) ?? "",
                hostname: a.lenient(String.self, forKey: .hostname) ?? "",
                ipv4Address: (a.lenient(LooseString.self, forKey: .ipv4Address) ?? a.lenient(LooseString.self, forKey: .address))?.value,
                ipv4Gateway: (a.lenient(LooseString.self, forKey: .ipv4Gateway) ?? a.lenient(LooseString.self, forKey: .gateway))?.value
            ))
        }
        return result
    }

    private static func decodeMounts(_ c: KeyedDecodingContainer<ConfigKeys>) -> [Mount] {
        guard var list = try? c.nestedUnkeyedContainer(forKey: .mounts) else { return [] }
        var result: [Mount] = []
        while !list.isAtEnd {
            guard let m = try? list.nestedContainer(keyedBy: MountKeys.self) else { break }
            // `type` is a Swift enum with associated values, e.g. {"virtiofs":{}} or {"volume":{"name":...}}.
            var kind = "bind"
            var source = m.lenient(String.self, forKey: .source) ?? ""
            if let typeObject = m.lenient([String: [String: LooseString]].self, forKey: .type), let first = typeObject.keys.sorted().first {
                kind = first == "virtiofs" ? "bind" : first
                if first == "volume", let name = typeObject[first]?["name"]?.value { source = name }
            } else if let typeString = m.lenient(String.self, forKey: .type) {
                kind = typeString
            }
            let options = m.lenient([String].self, forKey: .options) ?? []
            result.append(Mount(
                kind: kind, source: source,
                destination: m.lenient(String.self, forKey: .destination) ?? "",
                readOnly: options.contains("ro")))
        }
        return result
    }
}

// MARK: - Images

public struct ImageSummary: Identifiable, Sendable, Hashable, Decodable {
    public var id: String
    public var reference: String
    public var digest: String
    public var createdAt: Date?
    public var sizeBytes: Int64
    public var platforms: [String]

    public var repository: String {
        let ref = reference
        if let at = ref.firstIndex(of: "@") { return String(ref[..<at]) }
        if let colon = ref.lastIndex(of: ":"), !ref[colon...].contains("/") { return String(ref[..<colon]) }
        return ref
    }

    public var tag: String {
        let ref = reference
        if ref.contains("@") { return "<digest>" }
        if let colon = ref.lastIndex(of: ":"), !ref[colon...].contains("/") { return String(ref[ref.index(after: colon)...]) }
        return "latest"
    }

    public var isInfrastructure: Bool {
        // Images the runtime pulls for itself (init filesystem, builder).
        reference.contains("apple/containerization/vminit") || reference.contains("apple/container-builder")
    }

    public init(id: String, reference: String, digest: String, createdAt: Date? = nil, sizeBytes: Int64 = 0, platforms: [String] = []) {
        self.id = id; self.reference = reference; self.digest = digest
        self.createdAt = createdAt; self.sizeBytes = sizeBytes; self.platforms = platforms
    }

    private enum Keys: String, CodingKey { case id, configuration, variants }
    private enum ConfigKeys: String, CodingKey { case name, creationDate, descriptor, reference }
    private enum DescriptorKeys: String, CodingKey { case digest, size }
    private enum VariantKeys: String, CodingKey { case platform, size }
    private enum PlatformKeys: String, CodingKey { case os, architecture, variant }

    public init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: Keys.self)
        let config = try root.nestedContainer(keyedBy: ConfigKeys.self, forKey: .configuration)
        reference = config.lenient(String.self, forKey: .name) ?? config.lenient(String.self, forKey: .reference) ?? ""
        createdAt = config.lenient(Date.self, forKey: .creationDate)
        var descriptorSize: Int64 = 0
        if let d = try? config.nestedContainer(keyedBy: DescriptorKeys.self, forKey: .descriptor) {
            digest = d.lenient(String.self, forKey: .digest) ?? ""
            descriptorSize = d.lenient(Int64.self, forKey: .size) ?? 0
        } else {
            digest = ""
        }
        id = root.lenient(String.self, forKey: .id) ?? String(digest.split(separator: ":").last ?? "")

        var total: Int64 = 0
        var platforms: [String] = []
        if var list = try? root.nestedUnkeyedContainer(forKey: .variants) {
            while !list.isAtEnd {
                guard let v = try? list.nestedContainer(keyedBy: VariantKeys.self) else { break }
                total += v.lenient(Int64.self, forKey: .size) ?? 0
                if let p = try? v.nestedContainer(keyedBy: PlatformKeys.self, forKey: .platform) {
                    let os = p.lenient(String.self, forKey: .os) ?? ""
                    // Skip attestation manifests ("unknown/unknown").
                    guard os != "unknown" else { continue }
                    let parts = [os, p.lenient(String.self, forKey: .architecture), p.lenient(String.self, forKey: .variant)]
                    platforms.append(parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "/"))
                }
            }
        }
        sizeBytes = total > 0 ? total : descriptorSize
        self.platforms = platforms
    }
}

// MARK: - Volumes

public struct VolumeSummary: Identifiable, Sendable, Hashable, Decodable {
    public var id: String { name }
    public var name: String
    public var driver: String
    public var format: String
    public var source: String
    public var createdAt: Date?
    public var labels: [String: String]
    public var sizeBytes: UInt64?

    public var isAnonymous: Bool { labels["com.apple.container.resource.anonymous"] != nil }

    /// Disk space the volume actually uses. Volumes are sparse disk images, so
    /// `sizeBytes` (their capacity, 512 GiB by default) says little about real usage.
    /// Reads the host file, so it only works when the app runs on the same Mac as the runtime.
    public func allocatedBytes() -> UInt64? {
        guard !source.isEmpty else { return nil }
        let url = URL(fileURLWithPath: source)
        guard let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]) else { return nil }
        return (values.totalFileAllocatedSize ?? values.fileAllocatedSize).map(UInt64.init)
    }

    public init(name: String, driver: String = "local", format: String = "ext4", source: String = "", createdAt: Date? = nil, labels: [String: String] = [:], sizeBytes: UInt64? = nil) {
        self.name = name; self.driver = driver; self.format = format; self.source = source
        self.createdAt = createdAt; self.labels = labels; self.sizeBytes = sizeBytes
    }

    private enum Keys: String, CodingKey { case configuration }
    private enum ConfigKeys: String, CodingKey { case name, driver, format, source, creationDate, createdAt, labels, sizeInBytes }

    public init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: Keys.self)
        // Some releases print the configuration at the top level.
        let c = try (try? root.nestedContainer(keyedBy: ConfigKeys.self, forKey: .configuration))
            ?? decoder.container(keyedBy: ConfigKeys.self)
        name = try c.decode(String.self, forKey: .name)
        driver = c.lenient(String.self, forKey: .driver) ?? "local"
        format = c.lenient(String.self, forKey: .format) ?? ""
        source = c.lenient(String.self, forKey: .source) ?? ""
        createdAt = c.lenient(Date.self, forKey: .creationDate) ?? c.lenient(Date.self, forKey: .createdAt)
        labels = c.lenient([String: String].self, forKey: .labels) ?? [:]
        sizeBytes = c.lenient(UInt64.self, forKey: .sizeInBytes)
    }
}

// MARK: - Networks

public struct NetworkSummary: Identifiable, Sendable, Hashable, Decodable {
    public var id: String { name }
    public var name: String
    public var mode: String
    public var subnet: String?
    public var gateway: String?
    public var createdAt: Date?
    public var labels: [String: String]

    public var isBuiltin: Bool { labels["com.apple.container.resource.role"] == "builtin" || name == "default" }

    public init(name: String, mode: String = "nat", subnet: String? = nil, gateway: String? = nil, createdAt: Date? = nil, labels: [String: String] = [:]) {
        self.name = name; self.mode = mode; self.subnet = subnet; self.gateway = gateway
        self.createdAt = createdAt; self.labels = labels
    }

    private enum Keys: String, CodingKey { case id, configuration, status }
    private enum ConfigKeys: String, CodingKey { case name, id, mode, creationDate, ipv4Subnet, subnet, labels }
    private enum StatusKeys: String, CodingKey { case ipv4Subnet, ipv4Gateway, address, gateway }

    public init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: Keys.self)
        let c = try root.nestedContainer(keyedBy: ConfigKeys.self, forKey: .configuration)
        name = c.lenient(String.self, forKey: .name) ?? c.lenient(String.self, forKey: .id) ?? root.lenient(String.self, forKey: .id) ?? ""
        mode = c.lenient(LooseString.self, forKey: .mode)?.value ?? "nat"
        createdAt = c.lenient(Date.self, forKey: .creationDate)
        labels = c.lenient([String: String].self, forKey: .labels) ?? [:]
        let configSubnet = (c.lenient(LooseString.self, forKey: .ipv4Subnet) ?? c.lenient(LooseString.self, forKey: .subnet))?.value
        if let s = try? root.nestedContainer(keyedBy: StatusKeys.self, forKey: .status) {
            subnet = (s.lenient(LooseString.self, forKey: .ipv4Subnet) ?? s.lenient(LooseString.self, forKey: .address))?.value ?? configSubnet
            gateway = (s.lenient(LooseString.self, forKey: .ipv4Gateway) ?? s.lenient(LooseString.self, forKey: .gateway))?.value
        } else {
            subnet = configSubnet
            gateway = nil
        }
    }
}

// MARK: - Stats

public struct ContainerStatsSample: Identifiable, Sendable, Hashable, Decodable {
    public var id: String
    /// Fraction of one core: 1.0 is one core fully used.
    public var cpuUtilization: Double?
    public var cpuUsageUsec: UInt64?
    public var memoryUsageBytes: UInt64?
    public var memoryLimitBytes: UInt64?
    public var networkRxBytes: UInt64?
    public var networkTxBytes: UInt64?
    public var blockReadBytes: UInt64?
    public var blockWriteBytes: UInt64?
    public var numProcesses: UInt64?

    public init(id: String, cpuUtilization: Double? = nil, cpuUsageUsec: UInt64? = nil, memoryUsageBytes: UInt64? = nil,
                memoryLimitBytes: UInt64? = nil, networkRxBytes: UInt64? = nil, networkTxBytes: UInt64? = nil,
                blockReadBytes: UInt64? = nil, blockWriteBytes: UInt64? = nil, numProcesses: UInt64? = nil) {
        self.id = id; self.cpuUtilization = cpuUtilization; self.cpuUsageUsec = cpuUsageUsec
        self.memoryUsageBytes = memoryUsageBytes; self.memoryLimitBytes = memoryLimitBytes
        self.networkRxBytes = networkRxBytes; self.networkTxBytes = networkTxBytes
        self.blockReadBytes = blockReadBytes; self.blockWriteBytes = blockWriteBytes; self.numProcesses = numProcesses
    }

    private enum Keys: String, CodingKey {
        case id, cpuUtilization, cpuUsageUsec, memoryUsageBytes, memoryLimitBytes
        case networkRxBytes, networkTxBytes, blockReadBytes, blockWriteBytes, numProcesses
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        cpuUtilization = c.lenient(Double.self, forKey: .cpuUtilization)
        cpuUsageUsec = c.lenient(UInt64.self, forKey: .cpuUsageUsec)
        memoryUsageBytes = c.lenient(UInt64.self, forKey: .memoryUsageBytes)
        memoryLimitBytes = c.lenient(UInt64.self, forKey: .memoryLimitBytes)
        networkRxBytes = c.lenient(UInt64.self, forKey: .networkRxBytes)
        networkTxBytes = c.lenient(UInt64.self, forKey: .networkTxBytes)
        blockReadBytes = c.lenient(UInt64.self, forKey: .blockReadBytes)
        blockWriteBytes = c.lenient(UInt64.self, forKey: .blockWriteBytes)
        numProcesses = c.lenient(UInt64.self, forKey: .numProcesses)
    }
}

// MARK: - System

public struct SystemStatus: Sendable, Hashable, Decodable {
    public enum State: Sendable, Hashable { case running, notRunning, unregistered, other(String) }

    public var state: State
    public var clientVersion: String?
    public var serverVersion: String?
    public var appRoot: String?
    public var installRoot: String?
    public var cpus: Int?
    public var containersTotal: Int?
    public var containersRunning: Int?
    public var images: Int?

    public init(state: State, clientVersion: String? = nil, serverVersion: String? = nil) {
        self.state = state; self.clientVersion = clientVersion; self.serverVersion = serverVersion
    }

    private enum Keys: String, CodingKey { case status, client, server, host, paths, resources }
    private enum VersionKeys: String, CodingKey { case version }
    private enum HostKeys: String, CodingKey { case cpus }
    private enum PathKeys: String, CodingKey { case appRoot, installRoot }
    private enum ResourceKeys: String, CodingKey { case containersTotal, containersRunning, images }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let raw = (c.lenient(String.self, forKey: .status) ?? "").lowercased()
        switch raw {
        case "running": state = .running
        case "not running", "stopped": state = .notRunning
        case "unregistered": state = .unregistered
        default: state = .other(raw)
        }
        clientVersion = (try? c.nestedContainer(keyedBy: VersionKeys.self, forKey: .client))?.lenient(String.self, forKey: .version)
        serverVersion = (try? c.nestedContainer(keyedBy: VersionKeys.self, forKey: .server))?.lenient(String.self, forKey: .version)
        cpus = (try? c.nestedContainer(keyedBy: HostKeys.self, forKey: .host))?.lenient(Int.self, forKey: .cpus)
        let paths = try? c.nestedContainer(keyedBy: PathKeys.self, forKey: .paths)
        appRoot = paths?.lenient(String.self, forKey: .appRoot)
        installRoot = paths?.lenient(String.self, forKey: .installRoot)
        let resources = try? c.nestedContainer(keyedBy: ResourceKeys.self, forKey: .resources)
        containersTotal = resources?.lenient(Int.self, forKey: .containersTotal)
        containersRunning = resources?.lenient(Int.self, forKey: .containersRunning)
        images = resources?.lenient(Int.self, forKey: .images)
    }
}
