import Foundation
import Testing
@testable import ContainerKit

/// Labels as Docker Compose 5.7 writes them through Socktainer (captured from a real stack).
private func service(_ name: String, project: String = "shop", dependsOn: String = "", running: Bool = false,
                     health: String? = nil, network: String = "shop_default") -> ContainerSummary {
    var labels = [
        "com.docker.compose.project": project,
        "com.docker.compose.service": name,
        "com.docker.compose.depends-on": dependsOn,
        "com.docker.compose.project.working-dir": "/Users/me/shop",
        "com.docker.compose.project.config-files": "/Users/me/shop/compose.yaml,/Users/me/shop/compose.apple.yaml",
    ]
    if let health { labels["socktainer.healthcheck"] = health }
    return ContainerSummary(
        id: "\(project)-\(name)-1", image: "img", state: running ? .running : .stopped,
        // Stopped containers have no live attachments, only configured networks.
        networks: running ? [NetworkAttachment(network: network, hostname: name, ipv4Address: nil, ipv4Gateway: nil)] : [],
        configuredNetworks: [network],
        labels: labels)
}

@Suite struct ComposeTests {
    @Test func parsesDependsOn() {
        let deps = ComposeDependency.parse("postgres:service_healthy:false,minio:service_started:false,seed:service_completed_successfully:true")
        #expect(deps == [
            .init(service: "postgres", condition: .healthy),
            .init(service: "minio", condition: .started),
            .init(service: "seed", condition: .completedSuccessfully),
        ])
        #expect(ComposeDependency.parse("").isEmpty)
        #expect(ComposeDependency.parse("cache") == [.init(service: "cache", condition: .started)])
    }

    @Test func decodesSocktainerHealthCheck() throws {
        let c = service("postgres", health: #"{"Retries":30,"Test":["CMD-SHELL","pg_isready -U \"${POSTGRES_USER}\""],"Interval":2000000000,"Timeout":5000000000}"#)
        let check = try #require(c.healthCheck)
        #expect(check.command == ["sh", "-c", #"pg_isready -U "${POSTGRES_USER}""#])
        #expect(check.retries == 30)
        #expect(check.intervalDuration == .seconds(2))
        #expect(check.timeoutDuration == .seconds(5))
        #expect(HealthCheck(test: ["CMD", "curl", "-f", "http://localhost"]).command == ["curl", "-f", "http://localhost"])
        #expect(HealthCheck(test: ["NONE"]).command == nil)
        #expect(service("x", health: "not json").healthCheck == nil)
    }

    @Test func groupsProjectsHelpersAndStandalone() {
        let dns = ContainerSummary(id: "socktainer-dns-shop_default", image: "dns", state: .running,
                                   labels: ["socktainer.role": "dns", "socktainer.network": "shop_default"])
        let otherDNS = ContainerSummary(id: "socktainer-dns-gone_default", image: "dns", state: .stopped,
                                        labels: ["socktainer.role": "dns", "socktainer.network": "gone_default"])
        let builder = ContainerSummary(id: "buildx_buildkit_default", image: "buildkit", state: .stopped)
        let web = ContainerSummary(id: "web", image: "nginx", state: .running)
        let containers = [service("api", running: true), service("db"), service("worker", project: "jobs", network: "jobs_default"),
                          dns, otherDNS, builder, web]

        let grouping = ContainerGrouping(containers)
        #expect(grouping.projects.map(\.name) == ["jobs", "shop"])
        let shop = grouping.projects[1]
        #expect(shop.services.map(\.displayName) == ["api", "db"]) // running first
        #expect(shop.helpers.map(\.id) == ["socktainer-dns-shop_default"])
        #expect(shop.state == .partial)
        #expect(shop.workingDirectory == "/Users/me/shop")
        #expect(shop.configFiles.count == 2)
        #expect(grouping.projects[0].state == .stopped)
        #expect(grouping.standalone.map(\.id) == ["web"])
        #expect(Set(grouping.helpers.map(\.id)) == ["buildx_buildkit_default", "socktainer-dns-gone_default"])
    }

    @Test func startStagesFollowDependencies() {
        let project = ComposeProject(name: "shop", services: [
            service("api", dependsOn: "postgres:service_healthy:false,minio:service_started:false"),
            service("minio-init", dependsOn: "minio:service_started:false"),
            service("postgres"),
            service("minio"),
            service("web", dependsOn: "api:service_started:false,missing:service_started:false"),
        ], helpers: [])
        #expect(project.startStages().map { $0.map(\.displayName) } == [
            ["minio", "postgres"], ["api", "minio-init"], ["web"],
        ])
        #expect(project.requiredCondition(for: "postgres") == .healthy)
        #expect(project.requiredCondition(for: "minio") == .started)
        #expect(project.requiredCondition(for: "web") == nil)
    }

    @Test func dependencyCycleStillStartsEverything() {
        let project = ComposeProject(name: "loop", services: [
            service("a", dependsOn: "b:service_started:false"),
            service("b", dependsOn: "a:service_started:false"),
            service("c"),
        ], helpers: [])
        let stages = project.startStages()
        #expect(stages.first?.map(\.displayName) == ["c"])
        #expect(stages.flatMap { $0 }.count == 3)
    }
}

@Suite struct LogLineTests {
    @Test func stripsAndStylesANSI() {
        let line = LogLine(id: 0, raw: "\u{1B}[1;31mERROR\u{1B}[0m connection \u{1B}[38;5;208mrefused\u{1B}[39m\r")
        #expect(line.text == "ERROR connection refused")
        #expect(line.runs.count == 3)
        #expect(line.runs[0].style.bold && line.runs[0].style.foreground == .palette(1))
        #expect(line.runs[1].style.isPlain)
        #expect(line.runs[2].style.foreground == .extended(208))
        #expect(line.level == .error)
    }

    @Test func handlesTrueColorBackgroundsAndOtherEscapes() {
        let line = LogLine(id: 0, raw: "\u{1B}]0;title\u{07}\u{1B}[2K\u{1B}[48;2;1;2;3m\u{1B}[38;2;10;20;30mhi\u{1B}[m")
        #expect(line.text == "hi")
        #expect(line.runs.map(\.style.foreground) == [.rgb(10, 20, 30)])
        #expect(LogLine(id: 1, raw: "plain").runs == [.init(text: "plain", style: ANSIStyle())])
    }

    @Test(arguments: [
        ("2026-11-21 10:00:01.123 UTC [1] LOG:  database system is ready", LogLevel.info),
        (#"{"level":"warn","msg":"slow query"}"#, .warning),
        ("time=2026 level=error msg=boom", .error),
        ("[WARNING] disk almost full, error budget fine", .warning),
        ("FATAL: password authentication failed", .error),
        ("[debug] cache miss", .debug),
        ("no level here, terrorists and errand boys", nil),
    ] as [(String, LogLevel?)])
    func detectsLevels(text: String, level: LogLevel?) {
        #expect(LogLevel.detect(in: text) == level)
    }
}

@Suite struct SocktainerProbeTests {
    @Test func detectsListeningSocket() throws {
        let path = NSTemporaryDirectory() + "cd-\(UInt32.random(in: 0...UInt32.max)).sock"
        defer { unlink(path) }
        #expect(!Socktainer.isRunning(socketPath: path))

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            let bytes = Array(path.utf8)
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0)
        try #require(listen(fd, 1) == 0)
        #expect(Socktainer.isRunning(socketPath: path))
    }
}

@Suite struct StaleDNSTests {
    private func dnsHelper(_ address: String, running: Bool = true) -> ContainerSummary {
        ContainerSummary(id: "socktainer-dns-shop_default", image: "dns", state: running ? .running : .stopped,
                         networks: running ? [NetworkAttachment(network: "shop_default", hostname: "dns", ipv4Address: address + "/24", ipv4Gateway: nil)] : [],
                         labels: ["socktainer.role": "dns", "socktainer.network": "shop_default"])
    }

    private func svc(_ name: String, nameserver: String) -> ContainerSummary {
        ContainerSummary(id: "shop-\(name)-1", image: "img", state: .stopped, configuredNetworks: ["shop_default"],
                         dnsNameservers: [nameserver], labels: ["com.docker.compose.project": "shop", "com.docker.compose.service": name])
    }

    @Test func flagsServicesPointingAtAMovedHelper() {
        let moved = ComposeProject(name: "shop", services: [svc("api", nameserver: "192.168.254.2")], helpers: [dnsHelper("192.168.254.9")])
        #expect(moved.servicesWithStaleDNS().map(\.displayName) == ["api"])

        let fine = ComposeProject(name: "shop", services: [svc("api", nameserver: "192.168.254.2")], helpers: [dnsHelper("192.168.254.2")])
        #expect(fine.servicesWithStaleDNS().isEmpty)

        // A stopped helper has no address to compare with; nothing to report yet.
        let stopped = ComposeProject(name: "shop", services: [svc("api", nameserver: "192.168.254.2")], helpers: [dnsHelper("x", running: false)])
        #expect(stopped.servicesWithStaleDNS().isEmpty)

        // Services with their own public resolvers aren't using the helper at all.
        let custom = ComposeProject(name: "shop", services: [svc("api", nameserver: "1.1.1.1")], helpers: [dnsHelper("192.168.254.9")])
        #expect(custom.servicesWithStaleDNS().isEmpty)
    }

    @Test func decodesNameserversFromRealOutput() throws {
        let json = #"[{"configuration":{"id":"svc","image":{"reference":"x"},"dns":{"nameservers":["192.168.254.2"],"options":[],"searchDomains":[]},"networks":[{"network":"shop_default"}]},"status":{"state":"stopped","networks":[]}}]"#
        let engine = CLIContainerEngine(runner: CLIRunner(executableURL: URL(fileURLWithPath: "/usr/bin/false")))
        let list = try engine.decodeList(ContainerSummary.self, from: Data(json.utf8), command: "list")
        #expect(list.first?.dnsNameservers == ["192.168.254.2"])
        #expect(list.first?.configuredNetworks == ["shop_default"])
    }
}

@Suite struct SocktainerAPITests {
    @Test func parsesStatusAndChunkedErrorBody() throws {
        let raw = "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n18\r\n{\"message\":\"no such cont\r\n7\r\nainer\"}\r\n0\r\n\r\n"
        let response = try Socktainer.parse(Data(raw.utf8))
        #expect(response.status == 404)
        #expect(Socktainer.message(from: response.body) == "no such container")
        #expect(try Socktainer.parse(Data("HTTP/1.1 204 No Content\r\n\r\n".utf8)).status == 204)
        #expect(throws: POSIXError.self) { try Socktainer.parse(Data("garbage".utf8)) }
    }

    @Test func escapesIDsIntoOnePathSegment() {
        #expect(Socktainer.escape("shop-api-1") == "shop-api-1")
        #expect(Socktainer.escape("a/b c") == "a%2Fb%20c")
    }

    @Test func managedContainersAreRecognised() {
        #expect(ContainerSummary(id: "a", image: "", state: .stopped, labels: ["io.github.socktainer.id-seed": "x"]).isSocktainerManaged)
        #expect(!ContainerSummary(id: "b", image: "", state: .stopped, labels: ["socktainer.role": "dns"]).isSocktainerManaged)
        #expect(!ContainerSummary(id: "c", image: "", state: .stopped).isSocktainerManaged)
    }

    /// A one-shot fake Docker API on a Unix socket: records the request line, sends `reply`.
    private func serveOnce(_ reply: String) throws -> (path: String, requestLine: @Sendable () -> String) {
        let path = NSTemporaryDirectory() + "cd-api-\(UInt32.random(in: 0...UInt32.max)).sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            let bytes = Array(path.utf8); raw.copyBytes(from: bytes); raw[bytes.count] = 0
        }
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        try #require(listen(fd, 1) == 0)
        let box = RequestBox()
        Thread.detachNewThread {
            let client = accept(fd, nil, nil)
            var buffer = [UInt8](repeating: 0, count: 4096)
            let n = read(client, &buffer, buffer.count)
            box.set(String(decoding: buffer.prefix(max(n, 0)), as: UTF8.self))
            _ = Array(reply.utf8).withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
            close(client); close(fd); unlink(path)
        }
        return (path, { box.firstLine })
    }

    @Test func startPostsToTheContainerAndAcceptsNotModified() async throws {
        let server = try serveOnce("HTTP/1.1 304 Not Modified\r\nContent-Length: 0\r\n\r\n")
        try await Socktainer.start(container: "shop-api-1", socketPath: server.path)
        #expect(server.requestLine() == "POST /containers/shop-api-1/start HTTP/1.1")
    }

    @Test func surfacesTheAPIErrorMessage() async throws {
        let body = #"{"message":"No such container: nope"}"#
        let server = try serveOnce("HTTP/1.1 404 Not Found\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)")
        await #expect(throws: Socktainer.APIError(status: 404, message: "No such container: nope")) {
            try await Socktainer.stop(container: "nope", socketPath: server.path)
        }
    }
}

private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func set(_ value: String) { lock.withLock { text = value } }
    var firstLine: String { lock.withLock { String(text.split(separator: "\r\n").first ?? "") } }
}
