import Foundation

/// Everything the "Run container" form collects, turned into `container run` arguments.
public struct RunSpec: Sendable, Equatable {
    public struct Port: Sendable, Equatable, Hashable, Identifiable {
        public var id = UUID()
        public var hostPort: String
        public var containerPort: String
        public var proto: String
        public init(hostPort: String = "", containerPort: String = "", proto: String = "tcp") {
            self.hostPort = hostPort; self.containerPort = containerPort; self.proto = proto
        }
    }

    public struct VolumeBinding: Sendable, Equatable, Hashable, Identifiable {
        public var id = UUID()
        /// A host path (absolute, or starting with `~`) or a named volume.
        public var source: String
        public var destination: String
        public var readOnly: Bool
        public init(source: String = "", destination: String = "", readOnly: Bool = false) {
            self.source = source; self.destination = destination; self.readOnly = readOnly
        }
    }

    public struct EnvVar: Sendable, Equatable, Hashable, Identifiable {
        public var id = UUID()
        public var key: String
        public var value: String
        public init(key: String = "", value: String = "") { self.key = key; self.value = value }
    }

    public var image: String
    public var name: String = ""
    public var command: String = ""
    public var ports: [Port] = []
    public var volumes: [VolumeBinding] = []
    public var environment: [EnvVar] = []
    public var cpus: Int? = nil
    /// Memory limit, e.g. 2048 (MiB).
    public var memoryMiB: Int? = nil
    public var network: String = ""
    public var removeWhenStopped: Bool = false
    public var rosetta: Bool = false
    public var platform: String = ""

    public init(image: String) { self.image = image }

    public enum ValidationError: Error, LocalizedError, Equatable {
        case missingImage, invalidName(String), invalidPort(String), invalidVolume(String), invalidEnv(String)
        public var errorDescription: String? {
            switch self {
            case .missingImage: return "Choose an image to run."
            case .invalidName(let n): return "\"\(n)\" isn't a valid container name. Use letters, numbers, '.', '_' or '-', up to 63 characters."
            case .invalidPort(let p): return "Port \"\(p)\" must be a number from 1 to 65535."
            case .invalidVolume(let v): return "The mount \"\(v)\" needs both a source and an absolute path inside the container."
            case .invalidEnv(let e): return "The environment variable \"\(e)\" needs a name."
            }
        }
    }

    /// Mirrors `ManagedContainer.nameValid` in apple/container.
    public static func isValidName(_ name: String) -> Bool {
        name.count <= 63 && name.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9_.-]+$"#, options: .regularExpression) != nil
    }

    public func validate() throws {
        if image.trimmingCharacters(in: .whitespaces).isEmpty { throw ValidationError.missingImage }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        if !trimmedName.isEmpty, !Self.isValidName(trimmedName) { throw ValidationError.invalidName(trimmedName) }
        for port in ports where !(port.hostPort.isEmpty && port.containerPort.isEmpty) {
            for value in [port.hostPort, port.containerPort] {
                guard let n = Int(value), (1...65535).contains(n) else { throw ValidationError.invalidPort(value) }
            }
        }
        for v in volumes where !(v.source.isEmpty && v.destination.isEmpty) {
            guard !v.source.isEmpty, v.destination.hasPrefix("/") else { throw ValidationError.invalidVolume("\(v.source):\(v.destination)") }
        }
        for e in environment where !(e.key.isEmpty && e.value.isEmpty) {
            guard !e.key.trimmingCharacters(in: .whitespaces).isEmpty else { throw ValidationError.invalidEnv("=\(e.value)") }
        }
    }

    /// Arguments after the executable, always detached so the app doesn't own the container's lifetime.
    public func arguments() throws -> [String] {
        try validate()
        var args = ["run", "--detach", "--progress", "none"]
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        if !trimmedName.isEmpty { args += ["--name", trimmedName] }
        for port in ports where !port.hostPort.isEmpty && !port.containerPort.isEmpty {
            let proto = port.proto.lowercased() == "udp" ? "/udp" : ""
            args += ["--publish", "\(port.hostPort):\(port.containerPort)\(proto)"]
        }
        for v in volumes where !v.source.isEmpty && !v.destination.isEmpty {
            let source = (v.source as NSString).expandingTildeInPath
            args += ["--volume", "\(source):\(v.destination)\(v.readOnly ? ":ro" : "")"]
        }
        for e in environment where !e.key.trimmingCharacters(in: .whitespaces).isEmpty {
            args += ["--env", "\(e.key.trimmingCharacters(in: .whitespaces))=\(e.value)"]
        }
        if let cpus, cpus > 0 { args += ["--cpus", String(cpus)] }
        if let memoryMiB, memoryMiB > 0 { args += ["--memory", "\(memoryMiB)M"] }
        if !network.isEmpty { args += ["--network", network] }
        if removeWhenStopped { args.append("--rm") }
        if rosetta { args.append("--rosetta") }
        if !platform.isEmpty { args += ["--platform", platform] }
        args.append(image.trimmingCharacters(in: .whitespaces))
        args += Self.splitCommand(command)
        return args
    }

    /// Shell-like splitting that honours single quotes, double quotes and backslash escapes.
    public static func splitCommand(_ command: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inToken = false
        var quote: Character? = nil
        var escaping = false
        for ch in command {
            if escaping { current.append(ch); escaping = false; inToken = true; continue }
            if ch == "\\" && quote != "'" { escaping = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch; inToken = true; continue }
            if ch.isWhitespace {
                if inToken { result.append(current); current = ""; inToken = false }
                continue
            }
            current.append(ch); inToken = true
        }
        if inToken { result.append(current) }
        return result
    }
}
