import ContainerKit
import Foundation

/// The app's binary doubles as its MCP server, so there's nothing extra to install or sign:
/// `Container Desktop.app/Contents/MacOS/Container Desktop --mcp` speaks MCP over stdio and
/// never opens a window. `--read-only` leaves out the tools that change anything.
@main
enum Main {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.contains(MCPMode.flag) {
            MCPMode.run(readOnly: arguments.contains(MCPMode.readOnlyFlag))
        }
        ContainerDesktopApp.main()
    }
}

enum MCPMode {
    static let flag = "--mcp"
    static let readOnlyFlag = "--read-only"
    static let serverName = "container-desktop"

    static func run(readOnly: Bool) -> Never {
        // The client may hang up mid-write; that must end the process quietly, not crash it.
        signal(SIGPIPE, SIG_IGN)
        let override = UserDefaults.standard.string(forKey: "cliPath").flatMap { $0.isEmpty ? nil : $0 }
        guard let engine = CLIContainerEngine(cliPathOverride: override) else {
            FileHandle.standardError.write(Data("Apple's container CLI isn't installed. Get it from https://github.com/apple/container/releases\n".utf8))
            exit(1)
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let server = MCPServer(
            info: .init(name: serverName, version: version, instructions: ContainerTools.serverInstructions),
            tools: ContainerTools.all(controller: ProjectController(engine: engine), readOnly: readOnly))
        Task {
            await server.runStdio()
            exit(0)
        }
        dispatchMain()
    }
}
