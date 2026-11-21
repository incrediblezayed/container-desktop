import Foundation
import Testing
@testable import ContainerKit

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private let engine = CLIContainerEngine(runner: CLIRunner(executableURL: URL(fileURLWithPath: "/usr/bin/false")))

@Suite struct DecodingTests {
    @Test func containersDecodeAndSkipBrokenEntries() throws {
        let containers = try engine.decodeList(ContainerSummary.self, from: try fixture("containers"), command: "list")
        #expect(containers.count == 2)

        let web = try #require(containers.first { $0.id == "web" })
        #expect(web.state == .running)
        #expect(web.image == "docker.io/library/nginx:latest")
        #expect(web.command == ["nginx", "-g", "daemon off;"])
        #expect(web.ports == [PortMapping(hostPort: 8080, containerPort: 80)])
        #expect(web.ports.first?.display == "8080→80/tcp")
        #expect(web.primaryAddress == "192.168.64.3")
        #expect(web.cpus == 4)
        #expect(web.memoryBytes == 1_073_741_824)
        #expect(web.platform == "linux/arm64")
        #expect(web.labels["app"] == "demo")
        #expect(web.startedAt != nil)
        #expect(web.mounts.count == 2)
        #expect(web.mounts[0] == Mount(kind: "bind", source: "/Users/me/site", destination: "/usr/share/nginx/html", readOnly: true))
        #expect(web.mounts[1].kind == "volume")
        #expect(web.mounts[1].source == "data")

        let old = try #require(containers.first { $0.id == "old" })
        #expect(old.state == .stopped)
        #expect(old.command == ["/bin/sh"])
        #expect(old.ports.isEmpty)
    }

    @Test func imagesDecode() throws {
        let images = try engine.decodeList(ImageSummary.self, from: try fixture("images"), command: "image list")
        #expect(images.count == 2)
        let nginx = images[0]
        #expect(nginx.repository == "docker.io/library/nginx")
        #expect(nginx.tag == "latest")
        #expect(nginx.platforms == ["linux/arm64/v8"])
        #expect(nginx.sizeBytes == 72_000_800)
        #expect(nginx.createdAt != nil)

        let pinned = images[1]
        #expect(pinned.repository == "localhost:5000/team/api")
        #expect(pinned.tag == "<digest>")
        #expect(pinned.id == "ff")
    }

    @Test func repositoryWithRegistryPortAndNoTag() {
        let image = ImageSummary(id: "1", reference: "localhost:5000/team/api", digest: "")
        #expect(image.repository == "localhost:5000/team/api")
        #expect(image.tag == "latest")
    }

    @Test func volumesDecodeCurrentAndLegacyShapes() throws {
        let volumes = try engine.decodeList(VolumeSummary.self, from: try fixture("volumes"), command: "volume list")
        #expect(volumes.map(\.name) == ["data", "legacy"])
        #expect(volumes[0].sizeBytes == 536_870_912)
        #expect(volumes[1].isAnonymous)
        #expect(volumes[1].createdAt != nil)
    }

    @Test func networksDecodeCurrentAndLegacyShapes() throws {
        let networks = try engine.decodeList(NetworkSummary.self, from: try fixture("networks"), command: "network list")
        #expect(networks.count == 2)
        #expect(networks[0].isBuiltin)
        #expect(networks[0].subnet == "192.168.64.0/24")
        #expect(networks[0].gateway == "192.168.64.1")
        #expect(networks[1].name == "backend")
        #expect(networks[1].gateway == "192.168.65.1")
        #expect(!networks[1].isBuiltin)
    }

    @Test func statsDecode() throws {
        let stats = try engine.decodeList(ContainerStatsSample.self, from: try fixture("stats"), command: "stats")
        #expect(stats.first?.cpuUtilization == 0.42)
        #expect(stats.first?.memoryUsageBytes == 52_428_800)
    }

    @Test func systemStatusDecode() throws {
        let status = try engine.decode(SystemStatus.self, from: try fixture("status"), command: "system status")
        #expect(status.state == .running)
        #expect(status.serverVersion == "1.3.0")
        #expect(status.containersRunning == 1)
        #expect(status.images == 3)

        let down = try engine.decode(SystemStatus.self, from: Data(#"{"status":"not running"}"#.utf8), command: "system status")
        #expect(down.state == .notRunning)
    }

    @Test func leadingLogLinesAreIgnored() throws {
        let data = Data("warning: something\n[{\"id\":\"web\",\"blockReadBytes\":1}]\n".utf8)
        let stats = try engine.decodeList(ContainerStatsSample.self, from: data, command: "stats")
        #expect(stats.map(\.id) == ["web"])
    }

    @Test func looseStringHandlesObjects() throws {
        let value = try JSONDecoder().decode(LooseString.self, from: Data(#"{"address":"10.0.0.2","prefix":24}"#.utf8))
        #expect(value.value == "10.0.0.2/24")
    }
}
