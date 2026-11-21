import Foundation

public enum ContainerCLIError: Error, LocalizedError, Sendable, Equatable {
    case binaryNotFound
    case commandFailed(command: String, exitCode: Int32, stderr: String)
    case timedOut(command: String)
    case decodingFailed(command: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "The `container` command-line tool isn't installed."
        case let .commandFailed(command, code, stderr):
            let message = Self.cleanMessage(stderr)
            return message.isEmpty ? "`container \(command)` failed (exit \(code))." : message
        case let .timedOut(command):
            return "`container \(command)` didn't respond in time."
        case let .decodingFailed(command, detail):
            return "Couldn't read the output of `container \(command)`: \(detail)"
        }
    }

    /// The CLI prefixes errors with `Error: ` and sometimes wraps them in structured noise.
    static func cleanMessage(_ stderr: String) -> String {
        let lines = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let last = lines.last(where: { $0.lowercased().hasPrefix("error") }) ?? lines.last else { return "" }
        var text = String(last)
        for prefix in ["Error: ", "error: "] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        return text
    }
}

public struct CommandResult: Sendable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// Runs the `container` CLI. All process work happens off the main actor.
public struct CLIRunner: Sendable {
    public static let defaultSearchPaths = [
        "/usr/local/bin/container",   // Apple's signed installer package
        "/opt/homebrew/bin/container", // Homebrew on Apple silicon
    ]

    public let executableURL: URL

    public init(executableURL: URL) {
        self.executableURL = executableURL
    }

    /// Find the CLI: an explicit override first, then the standard install locations, then `$PATH`.
    public static func locate(override: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let override, !override.isEmpty { candidates.append((override as NSString).expandingTildeInPath) }
        if let env = environment["CONTAINER_DESKTOP_CLI"] { candidates.append(env) }
        candidates += defaultSearchPaths
        // GUI apps get a minimal PATH, so this mostly helps when launched from a terminal.
        if let path = environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/container" }
        }
        return candidates.lazy.map { URL(fileURLWithPath: $0) }.first { fm.isExecutableFile(atPath: $0.path) }
    }

    /// Run to completion, returning stdout/stderr. Throws `commandFailed` on a non-zero exit.
    @discardableResult
    public func run(_ arguments: [String], timeout: Duration = .seconds(60), stdin: Data? = nil) async throws -> CommandResult {
        let result = try await runAllowingFailure(arguments, timeout: timeout, stdin: stdin)
        guard result.exitCode == 0 else {
            throw ContainerCLIError.commandFailed(
                command: arguments.prefix(2).joined(separator: " "), exitCode: result.exitCode, stderr: result.stderrText)
        }
        return result
    }

    public func runAllowingFailure(_ arguments: [String], timeout: Duration = .seconds(60), stdin: Data? = nil) async throws -> CommandResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = Self.childEnvironment()
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let input = Pipe()
        process.standardInput = stdin == nil ? FileHandle.nullDevice : input

        let commandName = arguments.prefix(2).joined(separator: " ")

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandResult, Error>) in
                let state = RunState(continuation: continuation)

                // Drain both pipes concurrently so a chatty process can't fill a buffer and deadlock.
                let group = DispatchGroup()
                let stdoutBox = DataBox(), stderrBox = DataBox()
                group.enter()
                DispatchQueue.global().async { stdoutBox.data = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                group.enter()
                DispatchQueue.global().async { stderrBox.data = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }

                process.terminationHandler = { proc in
                    group.notify(queue: .global()) {
                        state.resume(.success(CommandResult(exitCode: proc.terminationStatus, stdout: stdoutBox.data, stderr: stderrBox.data)))
                    }
                }

                do {
                    try process.run()
                } catch {
                    state.resume(.failure(error))
                    return
                }
                if let stdin {
                    input.fileHandleForWriting.write(stdin)
                    try? input.fileHandleForWriting.close()
                }

                let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                    if process.isRunning {
                        process.terminate()
                        state.resume(.failure(ContainerCLIError.timedOut(command: commandName)))
                    }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// Stream stdout line by line until the process exits or the consumer stops iterating.
    public func streamLines(_ arguments: [String]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.environment = Self.childEnvironment()
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice

            let buffer = LineBuffer()
            out.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                for line in buffer.append(chunk) { continuation.yield(line) }
            }
            let stderrBox = DataBox()
            err.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { handle.readabilityHandler = nil } else { stderrBox.append(chunk) }
            }

            process.terminationHandler = { proc in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                let rest = out.fileHandleForReading.readDataToEndOfFile()
                for line in buffer.append(rest) { continuation.yield(line) }
                if let tail = buffer.flush() { continuation.yield(tail) }
                if proc.terminationStatus == 0 || proc.terminationReason == .uncaughtSignal {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: ContainerCLIError.commandFailed(
                        command: arguments.prefix(2).joined(separator: " "),
                        exitCode: proc.terminationStatus,
                        stderr: String(decoding: stderrBox.data, as: UTF8.self)))
                }
            }

            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }

            do {
                try process.run()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    /// GUI apps inherit a bare environment; give the CLI a sensible PATH and HOME.
    static func childEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let basePath = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = env["PATH"].map { "\(basePath):\($0)" } ?? basePath
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        return env
    }
}

// MARK: - Concurrency plumbing

/// Guarantees a continuation is resumed exactly once (termination vs. timeout vs. launch failure).
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CommandResult, Error>?

    init(continuation: CheckedContinuation<CommandResult, Error>) { self.continuation = continuation }

    func resume(_ result: Result<CommandResult, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: result)
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    var data: Data {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
    func append(_ chunk: Data) { lock.withLock { storage.append(chunk) } }
}

/// Splits a byte stream into UTF-8 lines, holding back a partial trailing line.
final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    func append(_ chunk: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        pending.append(chunk)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            var lineData = pending[pending.startIndex..<newline]
            if lineData.last == UInt8(ascii: "\r") { lineData = lineData.dropLast() }
            lines.append(String(decoding: lineData, as: UTF8.self))
            pending.removeSubrange(pending.startIndex...newline)
        }
        return lines
    }

    func flush() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !pending.isEmpty else { return nil }
        defer { pending.removeAll() }
        return String(decoding: pending, as: UTF8.self)
    }
}
