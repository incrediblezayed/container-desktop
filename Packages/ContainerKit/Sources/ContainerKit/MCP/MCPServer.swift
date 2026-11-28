import Foundation

/// A Model Context Protocol server over stdio: newline-delimited JSON-RPC 2.0.
///
/// It implements the parts of the protocol a tools-only server needs (initialize, ping,
/// tools/list, tools/call). Requests run concurrently, so a slow `start` doesn't hold up a
/// `ping`; responses are written one line at a time.
public actor MCPServer {
    public struct Info: Sendable {
        public var name: String
        public var version: String
        public var instructions: String?
        public init(name: String, version: String, instructions: String? = nil) {
            self.name = name; self.version = version; self.instructions = instructions
        }
    }

    /// Newest first. A client asking for one of these gets it back; anything else gets the newest.
    public static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    let info: Info
    let tools: [MCPTool]
    private var inFlight: [JSONValue: Task<Void, Never>] = [:]

    public init(info: Info, tools: [MCPTool]) {
        self.info = info
        self.tools = tools
    }

    /// Reads requests from stdin until it closes, writing responses to stdout.
    public func runStdio() async {
        let output = LineWriter(handle: .standardOutput)
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                receive(line, write: { await output.write($0) })
            }
        } catch {
            FileHandle.standardError.write(Data("container-desktop mcp: \(error)\n".utf8))
        }
        // Let calls already running finish before the process exits.
        for task in inFlight.values { await task.value }
    }

    /// Handles one line of input. Notifications and cancellations produce no output.
    public func receive(_ line: String, write: @escaping @Sendable (String) async -> Void) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)) else {
            Task { await write(Self.errorResponse(id: .null, code: -32700, message: "Parse error")) }
            return
        }
        // Batches were dropped from the protocol in 2025-06-18 but cost nothing to accept.
        let messages = message.arrayValue ?? [message]
        for message in messages { dispatch(message, write: write) }
    }

    private func dispatch(_ message: JSONValue, write: @escaping @Sendable (String) async -> Void) {
        guard let method = message["method"]?.stringValue else { return } // a response to us; we send no requests
        let params = message["params"] ?? [:]
        guard let id = message["id"], id != .null else {
            if method == "notifications/cancelled", let target = params["requestId"] {
                inFlight[target]?.cancel()
            }
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            let response = await self.respond(method: method, params: params, id: id)
            if !Task.isCancelled { await write(response) }
            await self.finished(id)
        }
        inFlight[id] = task
    }

    private func finished(_ id: JSONValue) { inFlight[id] = nil }

    func respond(method: String, params: JSONValue, id: JSONValue) async -> String {
        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue ?? ""
            let version = Self.supportedProtocolVersions.contains(requested) ? requested : Self.supportedProtocolVersions[0]
            var result: [String: JSONValue] = [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string(info.name), "version": .string(info.version)],
            ]
            if let instructions = info.instructions { result["instructions"] = .string(instructions) }
            return Self.resultResponse(id: id, result: .object(result))
        case "ping":
            return Self.resultResponse(id: id, result: [:])
        case "tools/list":
            return Self.resultResponse(id: id, result: ["tools": .array(tools.map(\.definition))])
        case "tools/call":
            guard let name = params["name"]?.stringValue, let tool = tools.first(where: { $0.name == name }) else {
                return Self.errorResponse(id: id, code: -32602, message: "Unknown tool: \(params["name"]?.stringValue ?? "")")
            }
            let arguments = params["arguments"] ?? [:]
            let output: MCPToolOutput
            do {
                output = try await tool.handler(arguments)
            } catch {
                // Tool failures go back as results so the model can read them and adjust.
                let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                output = MCPToolOutput(text: message, isError: true)
            }
            return Self.resultResponse(id: id, result: output.json)
        case "resources/list":
            return Self.resultResponse(id: id, result: ["resources": []])
        case "prompts/list":
            return Self.resultResponse(id: id, result: ["prompts": []])
        default:
            return Self.errorResponse(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    static func resultResponse(id: JSONValue, result: JSONValue) -> String {
        JSONValue.object(["jsonrpc": "2.0", "id": id, "result": result]).encodedString(pretty: false)
    }

    static func errorResponse(id: JSONValue, code: Int, message: String) -> String {
        JSONValue.object(["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]])
            .encodedString(pretty: false)
    }
}

/// One tool the server offers.
public struct MCPTool: Sendable {
    public struct Annotations: Sendable {
        public var readOnly: Bool
        public var destructive: Bool
        public var idempotent: Bool
        public init(readOnly: Bool, destructive: Bool = false, idempotent: Bool = false) {
            self.readOnly = readOnly; self.destructive = destructive; self.idempotent = idempotent
        }
    }

    public var name: String
    public var title: String
    public var description: String
    public var inputSchema: JSONValue
    public var annotations: Annotations
    public var handler: @Sendable (JSONValue) async throws -> MCPToolOutput

    public init(name: String, title: String, description: String, inputSchema: JSONValue, annotations: Annotations,
                handler: @escaping @Sendable (JSONValue) async throws -> MCPToolOutput) {
        self.name = name; self.title = title; self.description = description
        self.inputSchema = inputSchema; self.annotations = annotations; self.handler = handler
    }

    var definition: JSONValue {
        [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": [
                "title": .string(title),
                "readOnlyHint": .bool(annotations.readOnly),
                "destructiveHint": .bool(annotations.destructive),
                "idempotentHint": .bool(annotations.idempotent),
                "openWorldHint": false,
            ],
        ]
    }
}

public struct MCPToolOutput: Sendable {
    public var text: String
    public var structured: JSONValue?
    public var isError: Bool

    public init(text: String, structured: JSONValue? = nil, isError: Bool = false) {
        self.text = text; self.structured = structured; self.isError = isError
    }

    /// Structured results are also sent as text: not every client reads `structuredContent`.
    public static func json(_ value: JSONValue) -> MCPToolOutput {
        MCPToolOutput(text: value.encodedString(), structured: value)
    }

    var json: JSONValue {
        var result: [String: JSONValue] = [
            "content": [["type": "text", "text": .string(text)]],
            "isError": .bool(isError),
        ]
        if let structured, case .object = structured { result["structuredContent"] = structured }
        return .object(result)
    }
}

/// Serializes writes so concurrent responses never interleave on one line.
actor LineWriter {
    let handle: FileHandle
    init(handle: FileHandle) { self.handle = handle }
    func write(_ line: String) {
        handle.write(Data((line + "\n").utf8))
    }
}
