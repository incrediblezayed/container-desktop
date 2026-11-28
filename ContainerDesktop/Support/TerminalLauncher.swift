import ContainerKit
import AppKit
import Foundation

/// Opens an interactive command in the user's terminal.
///
/// We write a throwaway `.command` file and hand it to Terminal through
/// NSWorkspace. That avoids Apple Events automation permissions, works for
/// non-sandboxed apps, and lets the shell own the TTY that `exec -it` needs.
enum TerminalLauncher {
    static func open(command: [String], title: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ContainerDesktop", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeTitle = title.replacingOccurrences(of: "[^A-Za-z0-9_.-]", with: "_", options: .regularExpression)
        let script = directory.appendingPathComponent("shell-\(safeTitle)-\(UUID().uuidString.prefix(8)).command")

        let quoted = command.map(shellQuote).joined(separator: " ")
        let body = """
        #!/bin/zsh
        printf '\\e]0;%s\\a' \(shellQuote("container: \(title)"))
        rm -f -- \(shellQuote(script.path))
        exec \(quoted)

        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let terminal {
            NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: configuration)
        } else {
            NSWorkspace.shared.open(script)
        }
    }

    static func shellQuote(_ value: String) -> String { Shell.quote(value) }
}
