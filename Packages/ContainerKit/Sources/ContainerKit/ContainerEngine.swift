import Foundation

/// What the UI needs from a container runtime.
///
/// `CLIContainerEngine` is the production implementation. The protocol exists so a
/// native XPC backend (Apple's `ContainerAPIClient`) can be added later without
/// touching the UI, and so previews and tests can use an in-memory engine.
public protocol ContainerEngine: Sendable {
    func systemStatus() async throws -> SystemStatus
    func startSystem() async throws
    func stopSystem() async throws

    func listContainers() async throws -> [ContainerSummary]
    func start(container id: String) async throws
    func stop(container id: String) async throws
    func kill(container id: String) async throws
    func delete(container id: String, force: Bool) async throws
    func run(_ spec: RunSpec) async throws -> String
    func stats() async throws -> [ContainerStatsSample]
    func logs(container id: String, follow: Bool, tail: Int?, boot: Bool) -> AsyncThrowingStream<String, Error>
    /// Runs a command inside a running container and returns its result without throwing
    /// on a non-zero exit (health checks need the exit code).
    func exec(container id: String, command: [String], timeout: Duration) async throws -> CommandResult
    /// Raw `inspect` output, pretty-printed, for the "Inspect" tab.
    func inspect(container id: String) async throws -> String

    func listImages() async throws -> [ImageSummary]
    func pull(image reference: String) -> AsyncThrowingStream<String, Error>
    func delete(image reference: String) async throws
    func pruneImages() async throws -> String

    func listVolumes() async throws -> [VolumeSummary]
    func createVolume(name: String) async throws
    func delete(volume name: String) async throws

    func listNetworks() async throws -> [NetworkSummary]
    func createNetwork(name: String) async throws
    func delete(network name: String) async throws

    /// The command line a user would type to open a shell, for "Open in Terminal".
    func shellCommand(container id: String, shell: String) -> [String]
}

public struct CLIContainerEngine: ContainerEngine {
    public let runner: CLIRunner

    public init(runner: CLIRunner) { self.runner = runner }

    public init?(cliPathOverride: String? = nil) {
        guard let url = CLIRunner.locate(override: cliPathOverride) else { return nil }
        self.runner = CLIRunner(executableURL: url)
    }

    // MARK: System

    public func systemStatus() async throws -> SystemStatus {
        // `system status` exits 1 when the daemon is down but still prints JSON.
        let result = try await runner.runAllowingFailure(["system", "status", "--format", "json"], timeout: .seconds(15))
        if let status = try? decode(SystemStatus.self, from: result.stdout, command: "system status") {
            return status
        }
        if result.exitCode == 0 { return SystemStatus(state: .running) }
        return SystemStatus(state: .notRunning)
    }

    public func startSystem() async throws {
        // First start may download a kernel; accept the recommended one non-interactively.
        try await runner.run(["system", "start", "--enable-kernel-install"], timeout: .seconds(600))
    }

    public func stopSystem() async throws {
        try await runner.run(["system", "stop"], timeout: .seconds(120))
    }

    // MARK: Containers

    public func listContainers() async throws -> [ContainerSummary] {
        try await list(["list", "--all", "--format", "json"], as: ContainerSummary.self)
    }

    public func start(container id: String) async throws {
        try await runner.run(["start", id], timeout: .seconds(120))
    }

    public func stop(container id: String) async throws {
        try await runner.run(["stop", id], timeout: .seconds(60))
    }

    public func kill(container id: String) async throws {
        try await runner.run(["kill", id], timeout: .seconds(30))
    }

    public func delete(container id: String, force: Bool) async throws {
        try await runner.run(["delete"] + (force ? ["--force"] : []) + [id], timeout: .seconds(60))
    }

    public func run(_ spec: RunSpec) async throws -> String {
        // Pulling a large image happens inside `run`; give it room.
        let result = try await runner.run(try spec.arguments(), timeout: .seconds(1800))
        return result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").last.map(String.init) ?? ""
    }

    public func stats() async throws -> [ContainerStatsSample] {
        // `--no-stream` takes two samples ~2s apart so it can report CPU utilisation.
        try await list(["stats", "--no-stream", "--format", "json"], as: ContainerStatsSample.self, timeout: .seconds(20))
    }

    public func logs(container id: String, follow: Bool, tail: Int?, boot: Bool = false) -> AsyncThrowingStream<String, Error> {
        var args = ["logs"]
        if boot { args.append("--boot") }
        if follow { args.append("--follow") }
        if let tail { args += ["-n", String(tail)] }
        args.append(id)
        return runner.streamLines(args)
    }

    public func exec(container id: String, command: [String], timeout: Duration) async throws -> CommandResult {
        try await runner.runAllowingFailure(["exec", id] + command, timeout: timeout)
    }

    public func inspect(container id: String) async throws -> String {
        let result = try await runner.run(["inspect", id], timeout: .seconds(15))
        return Self.prettyJSON(result.stdout) ?? result.stdoutText
    }

    // MARK: Images

    public func listImages() async throws -> [ImageSummary] {
        try await list(["image", "list", "--format", "json"], as: ImageSummary.self)
    }

    public func pull(image reference: String) -> AsyncThrowingStream<String, Error> {
        runner.streamLines(["image", "pull", "--progress", "plain", reference])
    }

    public func delete(image reference: String) async throws {
        try await runner.run(["image", "delete", reference], timeout: .seconds(60))
    }

    public func pruneImages() async throws -> String {
        try await runner.run(["image", "prune"], timeout: .seconds(300)).stdoutText
    }

    // MARK: Volumes

    public func listVolumes() async throws -> [VolumeSummary] {
        try await list(["volume", "list", "--format", "json"], as: VolumeSummary.self)
    }

    public func createVolume(name: String) async throws {
        try await runner.run(["volume", "create", name])
    }

    public func delete(volume name: String) async throws {
        try await runner.run(["volume", "delete", name])
    }

    // MARK: Networks

    public func listNetworks() async throws -> [NetworkSummary] {
        try await list(["network", "list", "--format", "json"], as: NetworkSummary.self)
    }

    public func createNetwork(name: String) async throws {
        try await runner.run(["network", "create", name])
    }

    public func delete(network name: String) async throws {
        try await runner.run(["network", "delete", name])
    }

    public func shellCommand(container id: String, shell: String = "sh") -> [String] {
        [runner.executableURL.path, "exec", "--interactive", "--tty", id, shell]
    }

    // MARK: Helpers

    private func list<T: Decodable>(_ args: [String], as: T.Type, timeout: Duration = .seconds(30)) async throws -> [T] {
        let result = try await runner.run(args, timeout: timeout)
        let trimmed = result.stdout.isEmpty ? Data("[]".utf8) : result.stdout
        return try decodeList(T.self, from: trimmed, command: args.prefix(2).joined(separator: " "))
    }

    /// Decode an array element by element so one unreadable entry doesn't hide the rest.
    func decodeList<T: Decodable>(_ type: T.Type, from data: Data, command: String) throws -> [T] {
        let document = CLIJSON.extractDocument(from: data)
        let decoder = CLIJSON.decoder()
        do {
            return try decoder.decode([Tolerant<T>].self, from: document).compactMap(\.value)
        } catch {
            throw ContainerCLIError.decodingFailed(command: command, detail: String(describing: error))
        }
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data, command: String) throws -> T {
        do {
            return try CLIJSON.decoder().decode(T.self, from: CLIJSON.extractDocument(from: data))
        } catch {
            throw ContainerCLIError.decodingFailed(command: command, detail: String(describing: error))
        }
    }

    static func prettyJSON(_ data: Data) -> String? {
        let document = CLIJSON.extractDocument(from: data)
        guard let object = try? JSONSerialization.jsonObject(with: document),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: pretty, as: UTF8.self)
    }
}

/// Wraps an element so a decoding failure yields `nil` instead of failing the array.
struct Tolerant<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}
