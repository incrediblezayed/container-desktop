import Foundation
import Synchronization
import Testing
@testable import ContainerKit

/// An in-memory runtime that records what it was asked to do.
final class FakeEngine: ContainerEngine {
    struct State {
        var containers: [ContainerSummary] = []
        var calls: [String] = []
        var logs: [String: [String]] = [:]
        var execResult = CommandResult(exitCode: 0, stdout: Data(), stderr: Data())
        var running = true
        /// Containers that die as soon as they start, like a database on a damaged volume.
        var crashOnStart: Set<String> = []
        var startErrors: [String: String] = [:]
        var execOutput: [String: String] = [:]
    }

    let state: Mutex<State>
    init(_ containers: [ContainerSummary], logs: [String: [String]] = [:]) {
        state = Mutex(State(containers: containers, logs: logs))
    }

    var calls: [String] { state.withLock { $0.calls } }
    private func record(_ call: String) { state.withLock { $0.calls.append(call) } }
    private func set(_ id: String, _ s: ContainerState) {
        state.withLock { st in
            if let i = st.containers.firstIndex(where: { $0.id == id }) { st.containers[i].state = s }
        }
    }

    func systemStatus() async throws -> SystemStatus {
        SystemStatus(state: state.withLock { $0.running } ? .running : .notRunning)
    }
    func startSystem() async throws { record("system start") }
    func stopSystem() async throws { record("system stop") }
    func listContainers() async throws -> [ContainerSummary] { state.withLock { $0.containers } }
    func start(container id: String) async throws {
        record("start \(id)")
        if let message = state.withLock({ $0.startErrors[id] }) { throw ContainerCLIError.commandFailed(command: "start", exitCode: 1, stderr: message) }
        set(id, state.withLock { $0.crashOnStart.contains(id) } ? .stopped : .running)
    }
    func stop(container id: String) async throws { record("stop \(id)"); set(id, .stopped) }
    func kill(container id: String) async throws { record("kill \(id)") }
    func delete(container id: String, force: Bool) async throws {
        record("delete \(id)")
        state.withLock { $0.containers.removeAll { $0.id == id } }
    }
    func run(_ spec: RunSpec) async throws -> String { "" }
    func stats() async throws -> [ContainerStatsSample] { [] }
    func logs(container id: String, follow: Bool, tail: Int?, boot: Bool) -> AsyncThrowingStream<String, Error> {
        let lines = state.withLock { $0.logs[id] ?? [] }
        let shown = tail.map { Array(lines.suffix($0)) } ?? lines
        return AsyncThrowingStream { c in
            for line in shown { c.yield(line) }
            c.finish()
        }
    }
    func exec(container id: String, command: [String], timeout: Duration) async throws -> CommandResult {
        if let out = state.withLock({ $0.execOutput[id] }) { return CommandResult(exitCode: 0, stdout: Data(out.utf8), stderr: Data()) }
        record("exec \(id) \(command.joined(separator: " "))")
        return state.withLock { $0.execResult }
    }
    func inspect(container id: String) async throws -> String { #"{"id":"\#(id)"}"# }
    func listImages() async throws -> [ImageSummary] { [] }
    func pull(image reference: String) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func delete(image reference: String) async throws {}
    func pruneImages() async throws -> String { "" }
    func listVolumes() async throws -> [VolumeSummary] { [] }
    func createVolume(name: String) async throws {}
    func delete(volume name: String) async throws { record("delete volume \(name)") }
    func listNetworks() async throws -> [NetworkSummary] { [] }
    func createNetwork(name: String) async throws {}
    func delete(network name: String) async throws {}
    func shellCommand(container id: String, shell: String) -> [String] { [] }
}

private func svc(_ name: String, dependsOn: String = "", running: Bool = false, health: String? = nil,
                 volumes: [String] = []) -> ContainerSummary {
    var labels = [
        "com.docker.compose.project": "shop",
        "com.docker.compose.service": name,
        "com.docker.compose.depends-on": dependsOn,
    ]
    if let health { labels["socktainer.healthcheck"] = health }
    return ContainerSummary(
        id: "shop-\(name)-1", image: "\(name):latest", state: running ? .running : .stopped,
        mounts: volumes.map { Mount(kind: "volume", source: $0, destination: "/data", readOnly: false) },
        configuredNetworks: ["shop_default"], labels: labels)
}

/// A socket path nothing listens on, so Socktainer always looks stopped.
private let noSocket = "/tmp/container-desktop-tests-\(UUID().uuidString.prefix(8)).sock"

private let healthy = #"{"Test":["CMD","true"],"Interval":1000000,"Retries":3}"#

@Suite struct ProjectControllerTests {
    @Test func startsInDependencyOrderAndChecksHealth() async throws {
        let engine = FakeEngine([
            svc("api", dependsOn: "db:service_healthy:false"),
            svc("db", health: healthy),
            svc("web", dependsOn: "api:service_started:false"),
        ])
        let controller = ProjectController(engine: engine, socketPath: noSocket, settleTime: .zero)
        let project = try #require(try await controller.project(named: "shop"))
        try await controller.start(project)
        #expect(engine.calls == ["start shop-db-1", "exec shop-db-1 true", "start shop-api-1", "start shop-web-1"])
    }

    @Test func failedHealthCheckStopsLaterStages() async throws {
        let engine = FakeEngine([svc("api", dependsOn: "db:service_healthy:false"), svc("db", health: healthy)])
        engine.state.withLock { $0.execResult = CommandResult(exitCode: 1, stdout: Data(), stderr: Data("no".utf8)) }
        let controller = ProjectController(engine: engine, socketPath: noSocket, settleTime: .zero)
        let project = try #require(try await controller.project(named: "shop"))
        await #expect(throws: ProjectError.unhealthy("db")) { try await controller.start(project) }
        #expect(!engine.calls.contains("start shop-api-1"))
    }

    @Test func refusesWithoutSocktainerWhenDNSHelperExists() async throws {
        let dns = ContainerSummary(id: "socktainer-dns-shop_default", image: "dns", state: .running,
                                   labels: ["socktainer.role": "dns", "socktainer.network": "shop_default"])
        let engine = FakeEngine([svc("api"), dns])
        let controller = ProjectController(engine: engine, socketPath: noSocket, settleTime: .zero)
        let project = try #require(try await controller.project(named: "shop"))
        await #expect(throws: ProjectError.socktainerNotRunning) { try await controller.start(project) }
        #expect(engine.calls.isEmpty)
    }

    @Test func deleteKeepsVolumesUnlessAskedAndSparesSharedOnes() async throws {
        let other = ContainerSummary(id: "backup", image: "b", state: .stopped,
                                     mounts: [Mount(kind: "volume", source: "shared", destination: "/s", readOnly: false)])
        let engine = FakeEngine([svc("db", volumes: ["shop_pg", "shared"]), svc("api", running: true), other])
        let controller = ProjectController(engine: engine, socketPath: noSocket, settleTime: .zero)
        let project = try #require(try await controller.project(named: "shop"))
        let removed = try await controller.delete(project, removeVolumes: true)
        #expect(removed == ["shop_pg"])
        #expect(engine.calls.contains("delete volume shop_pg"))
        #expect(!engine.calls.contains("delete volume shared"))
        #expect(try await engine.listContainers().map(\.id) == ["backup"])
    }

    @Test func recreateCommandQuotesPaths() {
        var c = svc("api")
        c.labels["com.docker.compose.project.working-dir"] = "/Users/me/my shop"
        c.labels["com.docker.compose.project.config-files"] = "/Users/me/my shop/compose.yaml"
        let project = ContainerGrouping([c]).projects[0]
        #expect(project.recreateCommand == "cd '/Users/me/my shop' && docker compose -p shop -f '/Users/me/my shop/compose.yaml' up -d --force-recreate")
    }
}

/// Drives the server the way a client would: one JSON-RPC line in, one line out.
private func call(_ server: MCPServer, _ request: String) async -> JSONValue? {
    let box = Mutex<[String]>([])
    let done = AsyncStream<Void>.makeStream()
    await server.receive(request) { line in
        box.withLock { $0.append(line) }
        done.continuation.yield()
    }
    // Notifications never answer; give them a moment, then report nothing.
    let waited = await withTaskGroup(of: Bool.self) { group in
        group.addTask { for await _ in done.stream { return true }; return false }
        group.addTask { try? await Task.sleep(for: .milliseconds(300)); return false }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
    guard waited, let line = box.withLock({ $0.first }) else { return nil }
    return try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
}

private func toolCall(_ name: String, _ arguments: String = "{}", id: Int = 9) -> String {
    #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#
}

private func server(_ engine: FakeEngine, readOnly: Bool = false) -> MCPServer {
    let controller = ProjectController(engine: engine, socketPath: noSocket, settleTime: .zero)
    return MCPServer(info: .init(name: "container-desktop", version: "test", instructions: ContainerTools.serverInstructions),
                     tools: ContainerTools.all(controller: controller, readOnly: readOnly))
}

@Suite struct MCPServerTests {
    @Test func initializeNegotiatesVersion() async throws {
        let s = server(FakeEngine([]))
        let known = try #require(await call(s, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#))
        #expect(known["id"] == 1)
        #expect(known["result"]?["protocolVersion"] == "2025-06-18")
        #expect(known["result"]?["capabilities"]?["tools"] != nil)
        #expect(known["result"]?["serverInfo"]?["name"] == "container-desktop")

        let future = try #require(await call(s, #"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"2099-01-01"}}"#))
        #expect(future["id"] == "a")
        #expect(future["result"]?["protocolVersion"]?.stringValue == MCPServer.supportedProtocolVersions[0])
    }

    @Test func notificationsGetNoReplyAndUnknownMethodsError() async throws {
        let s = server(FakeEngine([]))
        #expect(await call(s, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        let unknown = try #require(await call(s, #"{"jsonrpc":"2.0","id":2,"method":"nope"}"#))
        #expect(unknown["error"]?["code"] == -32601)
        let garbage = try #require(await call(s, "{not json"))
        #expect(garbage["error"]?["code"] == -32700)
        let ping = try #require(await call(s, #"{"jsonrpc":"2.0","id":3,"method":"ping"}"#))
        #expect(ping["result"] == [:])
    }

    @Test func readOnlyModeHidesActions() async throws {
        let names: (MCPServer) async throws -> [String] = { s in
            let list = try #require(await call(s, #"{"jsonrpc":"2.0","id":4,"method":"tools/list"}"#))
            return (list["result"]?["tools"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
        }
        let full = try await names(server(FakeEngine([])))
        #expect(full.contains("exec") && full.contains("restart") && full.contains("diagnose"))
        let limited = try await names(server(FakeEngine([]), readOnly: true))
        #expect(!limited.contains("exec") && !limited.contains("stop"))
        #expect(limited.contains("get_logs"))
        // Hidden tools can't be called either.
        let s = server(FakeEngine([svc("api", running: true)]), readOnly: true)
        let blocked = try #require(await call(s, toolCall("exec", #"{"container":"shop-api-1","command":["ls"]}"#)))
        #expect(blocked["error"]?["code"] == -32602)
    }

    @Test func listGroupsProjects() async throws {
        let s = server(FakeEngine([svc("api", dependsOn: "db:service_healthy:false", running: true), svc("db"),
                                   ContainerSummary(id: "web", image: "nginx", state: .running)]))
        let response = try #require(await call(s, toolCall("list_containers")))
        let result = try #require(response["result"]?["structuredContent"])
        let project = try #require(result["projects"]?.arrayValue?.first)
        #expect(project["name"] == "shop")
        #expect(project["state"] == "partly running")
        #expect(project["services"]?.arrayValue?.first?["depends_on"] == ["db (healthy)"])
        #expect(result["containers"]?.arrayValue?.first?["id"] == "web")

        let running = try #require(await call(s, toolCall("list_containers", #"{"include_stopped":false}"#)))
        #expect(running["result"]?["structuredContent"]?["projects"]?.arrayValue?.first?["services"]?.arrayValue?.count == 1)
    }

    @Test func logsFilterByLevelAndStripColour() async throws {
        let engine = FakeEngine([svc("api", running: true)], logs: [
            "shop-api-1": ["\u{1B}[32mINFO\u{1B}[0m listening", "ERROR db timeout", "WARN slow query", "ERROR again"],
        ])
        let s = server(engine)
        let all = try #require(await call(s, toolCall("get_logs", #"{"container":"shop-api-1","tail":2}"#)))
        #expect(all["result"]?["content"]?.arrayValue?.first?["text"] == "WARN slow query\nERROR again")

        let errors = try #require(await call(s, toolCall("get_logs", #"{"project":"shop","level":"errors"}"#)))
        let text = errors["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        #expect(text.contains("ERROR db timeout\nERROR again"))
        #expect(!text.contains("WARN"))
        #expect(!text.contains("\u{1B}"))
    }

    @Test func badTargetsComeBackAsToolErrors() async throws {
        let s = server(FakeEngine([svc("api")]))
        let response = try #require(await call(s, toolCall("start", #"{"project":"shop","service":"nope"}"#)))
        #expect(response["result"]?["isError"] == true)
        let text = response["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        #expect(text.contains("Services: api"))
    }

    @Test func diagnoseReportsStoppedServicesAndFailingHealth() async throws {
        let engine = FakeEngine([svc("db", running: true, health: healthy), svc("api")],
                                logs: ["shop-db-1": ["FATAL: password authentication failed"]])
        engine.state.withLock { $0.execResult = CommandResult(exitCode: 2, stdout: Data("refused".utf8), stderr: Data()) }
        let s = server(engine)
        let response = try #require(await call(s, toolCall("diagnose", #"{"project":"shop"}"#)))
        let report = try #require(response["result"]?["structuredContent"]?["reports"]?.arrayValue?.first)
        #expect(report["ok"] == false)
        let problems = (report["problems"]?.arrayValue ?? []).compactMap { $0["problem"]?.stringValue }
        #expect(problems.contains { $0.contains("api is stopped") })
        #expect(problems.contains { $0.contains("health check fails (exit 2): refused") })
        let db = report["services"]?.arrayValue?.first { $0["name"] == "db" }
        #expect(db?["recent_errors"] == ["FATAL: password authentication failed"])
    }

    @Test func execReturnsExitCodeAndOutput() async throws {
        let engine = FakeEngine([svc("api", running: true)])
        engine.state.withLock { $0.execResult = CommandResult(exitCode: 3, stdout: Data("out".utf8), stderr: Data("err".utf8)) }
        let s = server(engine)
        let response = try #require(await call(s, toolCall("exec", #"{"project":"shop","service":"api","command":["sh","-c","exit 3"]}"#)))
        #expect(response["result"]?["isError"] == true)
        let text = try #require(response["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        let body = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        #expect(body["exit_code"] == 3)
        #expect(body["stdout"] == "out")
        #expect(engine.calls == ["exec shop-api-1 sh -c exit 3"])
    }
}

@Suite struct StartRobustnessTests {
    @Test func serviceThatDiesOnBootFailsTheStartWithItsErrors() async throws {
        let engine = FakeEngine([svc("db"), svc("api", dependsOn: "db:service_started:false")],
                                logs: ["shop-db-1": ["PANIC:  could not create file: Input/output error"]])
        engine.state.withLock { $0.crashOnStart = ["shop-db-1"] }
        let controller = ProjectController(engine: engine, socketPath: noSocket, settleTime: .zero)
        let project = try #require(try await controller.project(named: "shop"))
        await #expect(throws: ProjectError.exited(services: ["db"], lastErrors: ["db: PANIC:  could not create file: Input/output error"])) {
            try await controller.start(project)
        }
    }

    @Test func finishedInitJobIsNotAFailure() async throws {
        let engine = FakeEngine([svc("init"), svc("api", dependsOn: "init:service_completed_successfully:false")])
        engine.state.withLock { $0.crashOnStart = ["shop-init-1"] } // exits at once, as setup jobs do
        let controller = ProjectController(engine: engine, socketPath: noSocket, settleTime: .zero)
        let project = try #require(try await controller.project(named: "shop"))
        try await controller.start(project)
        #expect(engine.calls == ["start shop-init-1", "start shop-api-1"])
    }

    @Test func setupJobThatExitedZeroIsNotAFailure() async throws {
        let engine = FakeEngine([svc("bucket-init"), svc("api")])
        engine.state.withLock { $0.crashOnStart = ["shop-bucket-init-1"] }
        var controller = ProjectController(engine: engine, socketPath: noSocket, settleTime: .zero)
        controller.exitCode = { $0.id == "shop-bucket-init-1" ? 0 : nil }
        let project = try #require(try await controller.project(named: "shop"))
        try await controller.start(project)

        controller.exitCode = { _ in 1 }
        await #expect(throws: ProjectError.exited(services: ["bucket-init"], lastErrors: [])) { try await controller.start(project) }
    }

    @Test func helperStartedMeanwhileIsNotAnError() async throws {
        let dns = ContainerSummary(id: "socktainer-dns-x", image: "dns", state: .stopped,
                                   labels: ["socktainer.role": "builder", "socktainer.network": "shop_default"])
        let engine = FakeEngine([svc("api"), dns])
        engine.state.withLock { $0.startErrors["socktainer-dns-x"] = "invalidState: container expected to be in created state, got: running" }
        let controller = ProjectController(engine: engine, socketPath: noSocket, settleTime: .zero)
        let project = try #require(try await controller.project(named: "shop"))
        try await controller.start(project)
        #expect(engine.calls.contains("start shop-api-1"))
    }

    @Test func parsesVolumeDamageFromTheKernel() {
        let output = """
        /dev/vda / ext4 rw,relatime 0 0
        /dev/vdc /var/lib/postgresql ext4 rw,relatime 0 0
        EXT4 vda 0 0
        EXT4 vdc 4 1795860673
        """
        let damage = ProjectController.parseVolumeDamage(output, volumes: [
            Mount(kind: "volume", source: "shop_pg", destination: "/var/lib/postgresql", readOnly: false),
            Mount(kind: "volume", source: "shop_cache", destination: "/cache", readOnly: false),
        ])
        #expect(damage == [.init(volume: "shop_pg", mountPoint: "/var/lib/postgresql", errorCount: 4,
                                 firstError: Date(timeIntervalSince1970: 1795860673))])
    }

    @Test func diagnoseReportsDamagedVolumesAndSkipsFinishedJobs() async throws {
        let engine = FakeEngine([svc("db", running: true, volumes: ["shop_pg"]), svc("init"),
                                 svc("api", dependsOn: "init:service_completed_successfully:false", running: true)])
        engine.state.withLock {
            $0.execOutput["shop-db-1"] = "/dev/vdc /data ext4 rw 0 0\nEXT4 vdc 2 1795860667\n"
        }
        let s = server(engine)
        let response = try #require(await call(s, toolCall("diagnose", #"{"project":"shop"}"#)))
        let report = try #require(response["result"]?["structuredContent"]?["reports"]?.arrayValue?.first)
        let problems = (report["problems"]?.arrayValue ?? []).compactMap { $0["problem"]?.stringValue }
        #expect(problems.count == 1)
        #expect(problems.first?.contains("Volume shop_pg (/data) has 2 filesystem errors") == true)
    }

    @Test func startingAContainerThatDiesIsReportedAsAnError() async throws {
        let engine = FakeEngine([ContainerSummary(id: "web", image: "nginx", state: .stopped)],
                                logs: ["web": ["nginx: [emerg] bind() failed", "ERROR shutting down"]])
        engine.state.withLock { $0.crashOnStart = ["web"] }
        let response = try #require(await call(server(engine), toolCall("start", #"{"container":"web"}"#)))
        #expect(response["result"]?["isError"] == true)
        let text = response["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        #expect(text.contains("started but stopped again") && text.contains("ERROR shutting down"))
    }
}
