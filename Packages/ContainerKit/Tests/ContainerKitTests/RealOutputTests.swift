import Foundation
import Testing
@testable import ContainerKit

/// Output captured from the real `container` CLI (paths anonymised).
/// When a new runtime release changes its JSON, add a sibling folder rather than editing these.
@Suite("container 1.7.1 output")
struct RealOutputTests {
    private let engine = CLIContainerEngine(runner: CLIRunner(executableURL: URL(fileURLWithPath: "/usr/bin/false")))

    private func load(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/1.7.1"))
        return try Data(contentsOf: url)
    }

    @Test func containers() throws {
        let list = try engine.decodeList(ContainerSummary.self, from: load("containers"), command: "list")
        #expect(list.count == 2)

        let web = try #require(list.first { $0.id == "cd-web" })
        #expect(web.state == .running)
        #expect(web.image == "docker.io/library/nginx:alpine")
        #expect(web.command == ["/docker-entrypoint.sh", "nginx", "-g", "daemon off;"])
        #expect(web.ports == [PortMapping(hostPort: 8089, containerPort: 80)])
        #expect(web.primaryAddress == "192.168.65.2")
        #expect(web.networks.first?.network == "cd-net")
        #expect(web.cpus == 2)
        #expect(web.memoryBytes == UInt64(536_870_912))
        #expect(web.platform == "linux/arm64/v8")
        #expect(web.labels["app"] == "demo")
        #expect(web.environment.contains("DEMO=1"))
        #expect(web.startedAt != nil)
        #expect(web.mounts.map(\.kind) == ["volume", "bind"])
        #expect(web.mounts[0].source == "cd-data")
        #expect(web.mounts[1] == Mount(kind: "bind", source: "/Users/me/site", destination: "/usr/share/nginx/html", readOnly: true))

        let stopped = try #require(list.first { $0.id == "cd-stopped" })
        #expect(stopped.state == .stopped)
        #expect(stopped.networks.isEmpty)
        // Live attachments vanish when stopped; the configuration still names the network.
        #expect(stopped.configuredNetworks == ["default"])
        #expect(web.configuredNetworks == ["cd-net"])
    }

    @Test func images() throws {
        let images = try engine.decodeList(ImageSummary.self, from: load("images"), command: "image list")
        // 1.7.1 already hides the runtime's vminit image from `image list`.
        #expect(images.map(\.reference).sorted() == ["docker.io/library/alpine:latest", "docker.io/library/nginx:alpine"])
        #expect(images.allSatisfy { !$0.isInfrastructure })
        let alpine = try #require(images.first { $0.reference == "docker.io/library/alpine:latest" })
        #expect(alpine.tag == "latest")
        #expect(alpine.platforms == ["linux/arm64/v8"])
        #expect(alpine.sizeBytes > 1_000_000)
    }

    @Test func volumes() throws {
        let volumes = try engine.decodeList(VolumeSummary.self, from: load("volumes"), command: "volume list")
        let data = try #require(volumes.first)
        #expect(data.name == "cd-data")
        #expect(data.format == "ext4")
        // The CLI reports the sparse image's capacity, not the space it uses.
        #expect(data.sizeBytes == UInt64(549_755_813_888))
    }

    @Test func networks() throws {
        let networks = try engine.decodeList(NetworkSummary.self, from: load("networks"), command: "network list")
        #expect(networks.map(\.name).sorted() == ["cd-net", "default"])
        let custom = try #require(networks.first { $0.name == "cd-net" })
        #expect(custom.subnet == "192.168.65.0/24")
        #expect(custom.gateway == "192.168.65.1")
        #expect(!custom.isBuiltin)
        #expect(networks.first { $0.name == "default" }?.isBuiltin == true)
    }

    @Test func stats() throws {
        let stats = try engine.decodeList(ContainerStatsSample.self, from: load("stats"), command: "stats")
        let web = try #require(stats.first)
        #expect(web.id == "cd-web")
        #expect(web.memoryLimitBytes == UInt64(536_870_912))
        #expect(web.numProcesses == 4)
        #expect(web.cpuUtilization == 0)
    }

    @Test func status() throws {
        let status = try engine.decode(SystemStatus.self, from: load("status"), command: "system status")
        #expect(status.state == .running)
        #expect(status.clientVersion == "1.7.1")
        #expect(status.serverVersion == "1.7.1")
        #expect(status.containersTotal == 2)
    }
}

@Suite struct VolumeUsageTests {
    @Test func allocatedBytesReflectsSparseFiles() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sparse-\(UUID().uuidString).img")
        defer { try? FileManager.default.removeItem(at: url) }
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 1, count: 64 * 1024))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 1 << 30) // 1 GiB logical, mostly holes
        try handle.close()

        let volume = VolumeSummary(name: "v", source: url.path, sizeBytes: 1 << 30)
        let used = try #require(volume.allocatedBytes())
        #expect(used >= 64 * 1024)
        #expect(used < 16 * 1024 * 1024)
        #expect(VolumeSummary(name: "missing", source: "/nonexistent/volume.img").allocatedBytes() == nil)
    }
}
