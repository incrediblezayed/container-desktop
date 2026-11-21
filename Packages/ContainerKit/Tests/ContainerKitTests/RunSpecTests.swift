import Foundation
import Testing
@testable import ContainerKit

@Suite struct RunSpecTests {
    @Test func minimalSpec() throws {
        let spec = RunSpec(image: "nginx:latest")
        #expect(try spec.arguments() == ["run", "--detach", "--progress", "none", "nginx:latest"])
    }

    @Test func fullSpec() throws {
        var spec = RunSpec(image: " postgres:17 ")
        spec.name = "db"
        spec.ports = [.init(hostPort: "5432", containerPort: "5432"), .init(hostPort: "53", containerPort: "53", proto: "udp"), .init()]
        spec.volumes = [.init(source: "pgdata", destination: "/var/lib/postgresql/data"), .init(source: "/tmp/conf", destination: "/etc/conf", readOnly: true)]
        spec.environment = [.init(key: "POSTGRES_PASSWORD", value: "a b=c"), .init()]
        spec.cpus = 2
        spec.memoryMiB = 2048
        spec.network = "backend"
        spec.removeWhenStopped = true
        spec.command = #"postgres -c "shared_buffers=256MB""#

        #expect(try spec.arguments() == [
            "run", "--detach", "--progress", "none",
            "--name", "db",
            "--publish", "5432:5432",
            "--publish", "53:53/udp",
            "--volume", "pgdata:/var/lib/postgresql/data",
            "--volume", "/tmp/conf:/etc/conf:ro",
            "--env", "POSTGRES_PASSWORD=a b=c",
            "--cpus", "2",
            "--memory", "2048M",
            "--network", "backend",
            "--rm",
            "postgres:17",
            "postgres", "-c", "shared_buffers=256MB",
        ])
    }

    @Test func tildeExpandsInHostPaths() throws {
        var spec = RunSpec(image: "alpine")
        spec.volumes = [.init(source: "~/code", destination: "/code")]
        let args = try spec.arguments()
        let volume = try #require(args.firstIndex(of: "--volume").map { args[$0 + 1] })
        #expect(volume == NSHomeDirectory() + "/code:/code")
    }

    @Test(arguments: ["", "  "]) func missingImageFails(image: String) {
        #expect(throws: RunSpec.ValidationError.missingImage) { try RunSpec(image: image).arguments() }
    }

    @Test func invalidValuesFail() {
        var spec = RunSpec(image: "alpine")
        spec.name = "-bad"
        #expect(throws: RunSpec.ValidationError.invalidName("-bad")) { try spec.arguments() }

        spec = RunSpec(image: "alpine")
        spec.ports = [.init(hostPort: "70000", containerPort: "80")]
        #expect(throws: RunSpec.ValidationError.invalidPort("70000")) { try spec.arguments() }

        spec = RunSpec(image: "alpine")
        spec.volumes = [.init(source: "data", destination: "relative")]
        #expect(throws: RunSpec.ValidationError.invalidVolume("data:relative")) { try spec.arguments() }
    }

    @Test func commandSplitting() {
        #expect(RunSpec.splitCommand(#"sh -c 'echo "hi there"'"#) == ["sh", "-c", #"echo "hi there""#])
        #expect(RunSpec.splitCommand(#"a\ b "" c"#) == ["a b", "", "c"])
        #expect(RunSpec.splitCommand("   ") == [])
    }
}

@Suite struct CLIRunnerTests {
    @Test func capturesOutputAndExitCode() async throws {
        let runner = CLIRunner(executableURL: URL(fileURLWithPath: "/bin/sh"))
        let ok = try await runner.run(["-c", "echo hello; echo oops >&2"])
        #expect(ok.stdoutText == "hello\n")
        #expect(ok.stderrText == "oops\n")

        await #expect(throws: ContainerCLIError.self) {
            try await runner.run(["-c", "echo 'Error: no such container' >&2; exit 3"])
        }
        do {
            try await runner.run(["-c", "echo 'Error: no such container' >&2; exit 3"])
        } catch let error as ContainerCLIError {
            #expect(error.errorDescription == "no such container")
        }
    }

    @Test func largeOutputDoesNotDeadlock() async throws {
        let runner = CLIRunner(executableURL: URL(fileURLWithPath: "/bin/sh"))
        let result = try await runner.run(["-c", "head -c 2000000 /dev/zero | tr '\\0' a; head -c 500000 /dev/zero | tr '\\0' b >&2"])
        #expect(result.stdout.count == 2_000_000)
        #expect(result.stderr.count == 500_000)
    }

    @Test func timesOut() async {
        let runner = CLIRunner(executableURL: URL(fileURLWithPath: "/bin/sh"))
        await #expect(throws: ContainerCLIError.timedOut(command: "-c sleep 5")) {
            try await runner.run(["-c", "sleep 5"], timeout: .milliseconds(200))
        }
    }

    @Test func streamsLines() async throws {
        let runner = CLIRunner(executableURL: URL(fileURLWithPath: "/bin/sh"))
        var lines: [String] = []
        for try await line in runner.streamLines(["-c", "printf 'one\\ntwo\\r\\nthree'"]) { lines.append(line) }
        #expect(lines == ["one", "two", "three"])
    }

    @Test func locateHonoursOverride() {
        #expect(CLIRunner.locate(override: "/bin/sh", environment: [:])?.path == "/bin/sh")
        #expect(CLIRunner.locate(override: "/nope", environment: ["PATH": "/nonexistent"]) == CLIRunner.locate(override: nil, environment: [:]))
    }
}
