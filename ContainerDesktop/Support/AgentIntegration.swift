import ContainerKit
import Foundation

/// Connects AI agents to the MCP server built into the app binary (see `MCPMode`).
enum AgentIntegration {
    static var executablePath: String { Bundle.main.executableURL?.path ?? "" }

    static func arguments(readOnly: Bool) -> [String] {
        [MCPMode.flag] + (readOnly ? [MCPMode.readOnlyFlag] : [])
    }

    /// A copy run from a download folder or a disk image moves or vanishes; agents would
    /// then fail to launch the server.
    static var isInstalledInApplications: Bool {
        let path = Bundle.main.bundlePath
        return (path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/"))
            && !path.contains("/AppTranslocation/")
    }

    static func serverJSON(readOnly: Bool) -> [String: Any] {
        ["type": "stdio", "command": executablePath, "args": arguments(readOnly: readOnly)]
    }

    /// The `mcpServers` snippet Claude Desktop, Cursor, VS Code and most other clients accept.
    static func clientConfig(readOnly: Bool) -> String {
        var server = serverJSON(readOnly: readOnly)
        server["type"] = nil
        let object: [String: Any] = ["mcpServers": [MCPMode.serverName: server]]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func claudeCommand(readOnly: Bool) -> String {
        (["claude", "mcp", "add", "--scope", "user", MCPMode.serverName, "--", executablePath] + arguments(readOnly: readOnly))
            .map { $0.contains(" ") ? Shell.quote($0) : $0 }
            .joined(separator: " ")
    }

    // MARK: Claude Code

    enum ClaudeStatus: Equatable {
        case notInstalled
        case notConnected
        /// Connected, but to another copy of the app or with other options.
        case outdated
        case connected(readOnly: Bool)
    }

    /// The native installer's link first, then whatever a login shell finds.
    static func locateClaude() async -> URL? {
        let home = NSHomeDirectory()
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        let shell = CLIRunner(executableURL: URL(fileURLWithPath: "/bin/zsh"))
        guard let result = try? await shell.runAllowingFailure(["-lc", "command -v claude"], timeout: .seconds(10)),
              result.exitCode == 0 else { return nil }
        let path = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : nil
    }

    /// Reads Claude Code's user config directly; `claude mcp get` would also launch the server.
    static func claudeStatus(claude: URL?) -> ClaudeStatus {
        guard claude != nil else { return .notInstalled }
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any],
              let entry = servers[MCPMode.serverName] as? [String: Any]
        else { return .notConnected }
        let args = entry["args"] as? [String] ?? []
        guard entry["command"] as? String == executablePath, args.contains(MCPMode.flag) else { return .outdated }
        return .connected(readOnly: args.contains(MCPMode.readOnlyFlag))
    }

    static func connectClaude(_ claude: URL, readOnly: Bool) async throws {
        let runner = CLIRunner(executableURL: claude)
        // `add-json` fails if the name exists; replacing it keeps the button idempotent.
        _ = try? await runner.runAllowingFailure(["mcp", "remove", "--scope", "user", MCPMode.serverName], timeout: .seconds(30))
        let data = try JSONSerialization.data(withJSONObject: serverJSON(readOnly: readOnly), options: [.withoutEscapingSlashes])
        try await runner.run(["mcp", "add-json", "--scope", "user", MCPMode.serverName, String(decoding: data, as: UTF8.self)], timeout: .seconds(30))
    }

    static func disconnectClaude(_ claude: URL) async throws {
        try await CLIRunner(executableURL: claude).run(["mcp", "remove", "--scope", "user", MCPMode.serverName], timeout: .seconds(30))
    }
}
