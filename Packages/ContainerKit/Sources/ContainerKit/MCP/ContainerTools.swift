import Foundation

/// The tools Container Desktop offers AI agents: see what's running, read logs, find out why
/// a project is broken, and (unless read-only) start, stop, restart and exec.
public enum ContainerTools {
    public static let serverInstructions = """
    Manages containers on this Mac through Apple's `container` runtime. Docker Compose projects \
    (created through Socktainer) are grouped by project and service. Start with `list_containers`; \
    when something is broken, `diagnose` checks the runtime, Socktainer, DNS, health checks and \
    recent errors in one call. Prefer `start`/`stop`/`restart` with `project` over individual \
    services: they follow depends_on order and wait for health checks. Never stop or delete \
    containers labelled as runtime helpers (socktainer-dns-*): services depend on their address.
    """

    public static func all(controller: ProjectController, readOnly: Bool = false) -> [MCPTool] {
        let t = Toolbox(controller: controller)
        var tools = [t.status, t.list, t.logs, t.diagnose, t.inspect]
        if !readOnly { tools += [t.start, t.stop, t.restart, t.exec] }
        return tools
    }
}

/// Raised for bad arguments; the message tells the model what to send instead.
struct ToolError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

private struct Toolbox: Sendable {
    let controller: ProjectController
    var engine: any ContainerEngine { controller.engine }

    // MARK: Schemas

    static let targetProperties: [String: JSONValue] = [
        "container": ["type": "string", "description": "Container ID, as shown by list_containers."],
        "project": ["type": "string", "description": "Compose project name. Acts on every service in the project unless `service` is given."],
        "service": ["type": "string", "description": "A service in `project`."],
    ]

    static func schema(_ properties: [String: JSONValue] = [:], required: [String] = []) -> JSONValue {
        ["type": "object", "properties": .object(properties), "required": .strings(required), "additionalProperties": false]
    }

    // MARK: Read-only tools

    var status: MCPTool {
        MCPTool(
            name: "container_status",
            title: "Runtime status",
            description: "Whether Apple's container system and Socktainer (the Docker API used by Compose) are running, their versions, and how many containers run.",
            inputSchema: Self.schema(),
            annotations: .init(readOnly: true, idempotent: true)
        ) { _ in
            let status = try await engine.systemStatus()
            var result: [String: JSONValue] = [
                "container_system": .string(status.state == .running ? "running" : "stopped"),
                "cli_version": .from(status.clientVersion),
                "server_version": .from(status.serverVersion),
                "socktainer": .string(Socktainer.isRunning(socketPath: controller.socketPath) ? "running" : "not running"),
                "socktainer_socket": .string(controller.socketPath),
            ]
            if status.state == .running {
                let list = try await engine.listContainers()
                result["containers_running"] = .from(list.filter(\.isRunning).count)
                result["containers_total"] = .from(list.count)
            } else {
                result["hint"] = "Start the container system with `container system start` or from Container Desktop."
            }
            return .json(.object(result))
        }
    }

    var list: MCPTool {
        MCPTool(
            name: "list_containers",
            title: "List containers",
            description: "Lists Compose projects with their services, and standalone containers, with state, image, ports and dependencies. Stopped containers are included unless include_stopped is false.",
            inputSchema: Self.schema([
                "include_stopped": ["type": "boolean", "description": "Include stopped containers (default true)."],
                "include_helpers": ["type": "boolean", "description": "Include runtime helpers such as Socktainer's DNS servers (default false)."],
            ]),
            annotations: .init(readOnly: true, idempotent: true)
        ) { args in
            let includeStopped = args["include_stopped"]?.boolValue ?? true
            let includeHelpers = args["include_helpers"]?.boolValue ?? false
            let grouping = try await controller.grouping()
            let keep: (ContainerSummary) -> Bool = { includeStopped || $0.isRunning }

            let projects: [JSONValue] = grouping.projects.compactMap { project in
                let services = project.services.filter(keep)
                guard !services.isEmpty else { return nil }
                var entry: [String: JSONValue] = [
                    "name": .string(project.name),
                    "state": .string(Self.describe(project.state)),
                    "running": .from(project.runningCount),
                    "services_total": .from(project.services.count),
                    "working_dir": .from(project.workingDirectory),
                    "services": .array(services.map { Self.describe($0, inProject: true) }),
                ]
                if includeHelpers { entry["helpers"] = .array(project.helpers.map { Self.describe($0, inProject: false) }) }
                let stale = project.servicesWithStaleDNS()
                if !stale.isEmpty {
                    entry["warning"] = .string("DNS helper moved; \(stale.map(\.displayName).joined(separator: ", ")) can't resolve service names. Run diagnose.")
                }
                return .object(entry)
            }
            var result: [String: JSONValue] = [
                "projects": .array(projects),
                "containers": .array(grouping.standalone.filter(keep).map { Self.describe($0, inProject: false) }),
            ]
            if includeHelpers { result["unassigned_helpers"] = .array(grouping.helpers.map { Self.describe($0, inProject: false) }) }
            return .json(.object(result))
        }
    }

    var logs: MCPTool {
        MCPTool(
            name: "get_logs",
            title: "Read logs",
            description: "Recent log lines (ANSI colours removed) of a container, or of every service in a project. Filter by level to find errors fast, or by text. Logs have no timestamps, so project logs are grouped by service rather than interleaved.",
            inputSchema: Self.schema(Self.targetProperties.merging([
                "tail": ["type": "integer", "description": "Lines to return per container, newest last (default 200, max 2000).", "minimum": 1, "maximum": 2000],
                "level": ["type": "string", "enum": ["all", "warnings", "errors"], "description": "`errors` keeps error/fatal/panic lines, `warnings` adds warnings (default all)."],
                "contains": ["type": "string", "description": "Only lines containing this text (case-insensitive)."],
                "regex": ["type": "boolean", "description": "Treat `contains` as a case-insensitive regular expression, e.g. \"timeout|refused\" (default false)."],
                "boot": ["type": "boolean", "description": "The VM's boot log instead of the app's output (single container only)."],
            ]) { a, _ in a }),
            annotations: .init(readOnly: true, idempotent: true)
        ) { args in
            let tail = min(max(args["tail"]?.intValue ?? 200, 1), 2000)
            let minimum: LogLevel? = switch args["level"]?.stringValue {
            case "errors": .error
            case "warnings": .warning
            default: nil
            }
            let matcher: LogMatcher?
            do {
                matcher = try LogMatcher.make(args["contains"]?.stringValue ?? "", regex: args["regex"]?.boolValue ?? false)
            } catch {
                throw ToolError("`contains` isn't a valid regular expression: \(error.localizedDescription)")
            }
            let filtering = minimum != nil || matcher != nil
            let targets = try await resolve(args).containers
            let boot = args["boot"]?.boolValue ?? false
            if boot, targets.count > 1 { throw ToolError("`boot` needs a single container; pass `container` or `service`.") }

            var sections: [String] = []
            for c in targets {
                // When filtering, read further back so a few matches still turn up.
                let fetched = try await readLogs(c, tail: filtering ? min(tail * 10, 10_000) : tail, boot: boot)
                var lines = fetched.map { LogLine(id: 0, raw: $0) }
                if let minimum { lines = lines.filter { ($0.level ?? .info) >= minimum } }
                if let matcher { lines = lines.filter { matcher.matches($0.text) } }
                let shown = lines.suffix(tail).map(\.text)
                let header = targets.count > 1 || filtering
                    ? "== \(c.displayName) (\(c.state.rawValue)) · \(shown.count) of \(fetched.count) lines read =="
                    : nil
                sections.append(([header].compactMap { $0 } + (shown.isEmpty ? ["(no matching lines)"] : Array(shown))).joined(separator: "\n"))
            }
            return MCPToolOutput(text: Self.clip(sections.joined(separator: "\n\n"), keepEnd: true))
        }
    }

    var diagnose: MCPTool {
        MCPTool(
            name: "diagnose",
            title: "Diagnose",
            description: "Finds out why a project or container isn't working: checks the container system, Socktainer, stale DNS after a helper restart, stopped services, runs health checks now, and lists recent error lines. Returns problems with suggested fixes. Without arguments, checks every project.",
            inputSchema: Self.schema(Self.targetProperties),
            annotations: .init(readOnly: true, idempotent: true)
        ) { args in
            let status = try await engine.systemStatus()
            guard status.state == .running else {
                return .json(["problems": [["problem": "The container system isn't running.", "fix": "Run `container system start`, or start it from Container Desktop."]]])
            }
            let hasTarget = args["container"] != nil || args["project"] != nil
            let targets: [Target] = hasTarget
                ? [try await resolve(args)]
                : try await controller.grouping().projects.map(Target.project)
            var reports: [JSONValue] = []
            for target in targets { reports.append(await report(for: target)) }
            return .json(["reports": .array(reports)])
        }
    }

    var inspect: MCPTool {
        MCPTool(
            name: "inspect_container",
            title: "Inspect container",
            description: "The runtime's full configuration of one container as JSON: command, environment, mounts, networks, resources and labels.",
            inputSchema: Self.schema(Self.targetProperties),
            annotations: .init(readOnly: true, idempotent: true)
        ) { args in
            let targets = try await resolve(args).containers
            guard targets.count == 1, let c = targets.first else { throw ToolError("Pass `container`, or `project` with `service`.") }
            return MCPToolOutput(text: Self.clip(try await engine.inspect(container: c.id), keepEnd: false))
        }
    }

    // MARK: Actions

    var start: MCPTool {
        MCPTool(
            name: "start",
            title: "Start",
            description: "Starts a container, or a whole Compose project in depends_on order, waiting for health checks and one-shot jobs that later services need. Already-running services are left alone.",
            inputSchema: Self.schema(Self.targetProperties),
            annotations: .init(readOnly: false, idempotent: true)
        ) { args in
            switch try await resolve(args) {
            case .project(let p): try await controller.start(p)
            case .container(let c): try await controller.start(c)
            }
            return try await summary(after: "Started", args)
        }
    }

    var stop: MCPTool {
        MCPTool(
            name: "stop",
            title: "Stop",
            description: "Stops a container, or a Compose project's services in reverse dependency order. Socktainer's DNS helper keeps running. Data in volumes is kept.",
            inputSchema: Self.schema(Self.targetProperties),
            annotations: .init(readOnly: false, idempotent: true)
        ) { args in
            switch try await resolve(args) {
            case .project(let p): try await controller.stop(p)
            case .container(let c):
                if c.isHelper { throw ToolError("\(c.id) is a runtime helper; services depend on its address. Stop the project instead.") }
                try await controller.stop(c)
            }
            return try await summary(after: "Stopped", args)
        }
    }

    var restart: MCPTool {
        MCPTool(
            name: "restart",
            title: "Restart",
            description: "Stops and starts a container or a Compose project (in dependency order, waiting for health checks). Use after changing configuration or when a service is wedged.",
            inputSchema: Self.schema(Self.targetProperties),
            annotations: .init(readOnly: false, idempotent: false)
        ) { args in
            switch try await resolve(args) {
            case .project(let p): try await controller.restart(p)
            case .container(let c): try await controller.restart(c)
            }
            return try await summary(after: "Restarted", args)
        }
    }

    var exec: MCPTool {
        MCPTool(
            name: "exec",
            title: "Run command in container",
            description: "Runs a command inside a running container and returns its exit code and output, e.g. [\"psql\", \"-U\", \"postgres\", \"-c\", \"select 1\"] or [\"sh\", \"-c\", \"ls /app\"]. Not interactive; stdin is empty.",
            inputSchema: Self.schema(Self.targetProperties.merging([
                "command": ["type": "array", "items": ["type": "string"], "minItems": 1, "description": "Program and arguments. Use [\"sh\", \"-c\", \"...\"] for pipes or globbing."],
                "timeout_seconds": ["type": "integer", "minimum": 1, "maximum": 600, "description": "Give up after this long (default 60)."],
            ]) { a, _ in a }, required: ["command"]),
            annotations: .init(readOnly: false, destructive: true, idempotent: false)
        ) { args in
            let command = args["command"]?.arrayValue?.compactMap(\.stringValue) ?? []
            guard !command.isEmpty else { throw ToolError("`command` must be a non-empty array of strings.") }
            let targets = try await resolve(args).containers
            guard targets.count == 1, let c = targets.first else { throw ToolError("Pass `container`, or `project` with `service`.") }
            guard c.isRunning else { throw ToolError("\(c.id) isn't running. Start it first.") }
            let timeout = min(max(args["timeout_seconds"]?.intValue ?? 60, 1), 600)
            let result = try await engine.exec(container: c.id, command: command, timeout: .seconds(timeout))
            return MCPToolOutput(
                text: JSONValue.object([
                    "exit_code": .number(Double(result.exitCode)),
                    "stdout": .string(Self.clip(result.stdoutText, keepEnd: true, limit: 30_000)),
                    "stderr": .string(Self.clip(result.stderrText, keepEnd: true, limit: 10_000)),
                ]).encodedString(),
                isError: result.exitCode != 0)
        }
    }

    // MARK: Targets

    enum Target {
        case container(ContainerSummary)
        case project(ComposeProject)

        var containers: [ContainerSummary] {
            switch self {
            case .container(let c): [c]
            case .project(let p): p.services
            }
        }
    }

    func resolve(_ args: JSONValue) async throws -> Target {
        let grouping = try await controller.grouping()
        if let id = args["container"]?.stringValue, !id.isEmpty {
            let all = grouping.projects.flatMap { $0.services + $0.helpers } + grouping.standalone + grouping.helpers
            if let c = all.first(where: { $0.id == id }) { return .container(c) }
            let close = all.map(\.id).filter { $0.localizedCaseInsensitiveContains(id) }
            throw ToolError("No container \"\(id)\"." + (close.isEmpty ? " Call list_containers to see IDs." : " Did you mean: \(close.prefix(5).joined(separator: ", "))?"))
        }
        if let name = args["project"]?.stringValue, !name.isEmpty {
            guard let project = grouping.projects.first(where: { $0.name == name }) else {
                let names = grouping.projects.map(\.name)
                throw ToolError("No project \"\(name)\". Projects: \(names.isEmpty ? "none" : names.joined(separator: ", ")).")
            }
            if let service = args["service"]?.stringValue, !service.isEmpty {
                guard let c = project.services.first(where: { $0.displayName == service }) else {
                    throw ToolError("No service \"\(service)\" in \(name). Services: \(project.services.map(\.displayName).joined(separator: ", ")).")
                }
                return .container(c)
            }
            return .project(project)
        }
        throw ToolError("Pass `container` (an ID) or `project` (and optionally `service`).")
    }

    // MARK: Helpers

    func readLogs(_ c: ContainerSummary, tail: Int, boot: Bool) async throws -> [String] {
        var lines: [String] = []
        for try await line in engine.logs(container: c.id, follow: false, tail: tail, boot: boot) {
            lines.append(line)
        }
        return lines
    }

    func summary(after verb: String, _ args: JSONValue) async throws -> MCPToolOutput {
        var target = try await resolve(args)
        // A container that dies on boot reports "running" for a moment; look again shortly after.
        if verb != "Stopped", case .container = target, target.containers.contains(where: { !$0.isRunning }) || controller.settleTime > .zero {
            if controller.settleTime > .zero { try await Task.sleep(for: controller.settleTime) }
            target = try await resolve(args)
        }
        let states = target.containers.map { "\($0.displayName): \($0.state.rawValue)" }
        let wanted = verb != "Stopped"
        let wrong = target.containers.filter { $0.isRunning != wanted && !$0.isOneOff }
        guard wanted, !wrong.isEmpty, case .container(let c) = target else {
            return MCPToolOutput(text: "\(verb). " + states.joined(separator: ", "))
        }
        let errors = await controller.recentErrors(c, limit: 3)
        return MCPToolOutput(
            text: "\(c.displayName) started but stopped again." + (errors.isEmpty ? " Read get_logs to see why." : " Last errors:\n" + errors.joined(separator: "\n")),
            isError: true)
    }

    func report(for target: Target) async -> JSONValue {
        var problems: [JSONValue] = []
        func problem(_ text: String, fix: String? = nil, service: String? = nil) {
            var entry: [String: JSONValue] = ["problem": .string(text)]
            if let fix { entry["fix"] = .string(fix) }
            if let service { entry["service"] = .string(service) }
            problems.append(.object(entry))
        }

        let name: String
        let services: [ContainerSummary]
        var initJobs = Set<String>()
        switch target {
        case .project(let project):
            name = project.name
            initJobs = Set(project.services.map(\.displayName).filter { project.requiredCondition(for: $0) == .completedSuccessfully })
            services = project.services
            if project.needsSocktainer, !Socktainer.isRunning(socketPath: controller.socketPath) {
                problem("Socktainer isn't running. Services find each other by name through it, so lookups fail.",
                        fix: "Start Socktainer, then start the project.")
            }
            for helper in project.helpers where !helper.isRunning {
                problem("Socktainer's DNS helper \(helper.id) is stopped, so services can't look each other up by name.",
                        fix: "Start the project; it starts the helper first. A restarted helper gets a new address, so if diagnose then reports moved DNS, recreate the services (volumes are kept): \(project.recreateCommand)")
            }
            let stale = project.servicesWithStaleDNS()
            if !stale.isEmpty {
                problem("Socktainer's DNS server came back on a new address, so \(stale.map(\.displayName).joined(separator: ", ")) can't resolve other services.",
                        fix: "Recreate the containers (volumes are kept): \(project.recreateCommand)")
            }
        case .container(let c):
            name = c.id
            services = [c]
        }

        var checked: [JSONValue] = []
        for c in services {
            var entry: [String: JSONValue] = ["name": .string(c.displayName), "state": .string(c.state.rawValue)]
            if !c.isRunning {
                let exitCode = await controller.exitCode(c)
                if let exitCode { entry["exit_code"] = .from(exitCode) }
                if exitCode == 0 || (exitCode == nil && initJobs.contains(c.displayName)) {
                    entry["state"] = "finished"
                } else if !c.isOneOff {
                    let how = exitCode.map { "exited with code \($0)" } ?? c.state.rawValue
                    problem("\(c.displayName) \(exitCode == nil ? "is" : "has") \(how).", fix: "Read its logs (get_logs level errors), fix the cause, then start it.", service: c.displayName)
                }
            } else {
                for damage in await controller.volumeDamage(c) {
                    let when = damage.firstError.map { " since \($0.formatted(.iso8601))" } ?? ""
                    problem("Volume \(damage.volume) (\(damage.mountPoint)) has \(damage.errorCount) filesystem errors\(when). Data on it may be damaged; I/O errors in the logs come from this.",
                            fix: "Ask the user before touching it. Back up first (e.g. pg_dump), then stop the project, copy the volume image, and repair it with e2fsck -f.",
                            service: c.displayName)
                }
                switch await controller.checkHealth(c) {
                case .passed: entry["health"] = "passing"
                case .failed(let code, let output):
                    entry["health"] = "failing"
                    problem("\(c.displayName)'s health check fails (exit \(code)): \(Self.clip(output, keepEnd: true, limit: 500))", service: c.displayName)
                case .noCheck, .notRunning: break
                }
            }
            let recent = (try? await readLogs(c, tail: 300, boot: false)) ?? []
            let errors = recent.map { LogLine(id: 0, raw: $0) }.filter { ($0.level ?? .info) >= .error }.map(\.text)
            if !errors.isEmpty {
                entry["recent_errors"] = .strings(errors.suffix(5).map { Self.clip($0, keepEnd: false, limit: 400) })
                entry["error_lines_in_last_300"] = .from(errors.count)
            }
            checked.append(.object(entry))
        }
        return [
            "target": .string(name),
            "ok": .bool(problems.isEmpty),
            "problems": .array(problems),
            "services": .array(checked),
        ]
    }

    static func describe(_ state: ComposeProject.State) -> String {
        switch state {
        case .running: "running"
        case .partial: "partly running"
        case .stopped: "stopped"
        }
    }

    static func describe(_ c: ContainerSummary, inProject: Bool) -> JSONValue {
        var entry: [String: JSONValue] = [
            "id": .string(c.id),
            "state": .string(c.state.rawValue),
            "image": .string(c.image),
        ]
        if inProject, let service = c.composeService { entry["service"] = .string(service) }
        if !c.ports.isEmpty { entry["ports"] = .strings(c.ports.map(\.display)) }
        if let address = c.primaryAddress { entry["ip"] = .string(address) }
        let deps = c.composeDependencies
        if !deps.isEmpty {
            entry["depends_on"] = .strings(deps.map { dep in
                switch dep.condition {
                case .healthy: "\(dep.service) (healthy)"
                case .completedSuccessfully: "\(dep.service) (completed)"
                default: dep.service
                }
            })
        }
        if c.healthCheck?.command != nil { entry["has_healthcheck"] = true }
        if c.isOneOff { entry["one_off"] = true }
        return .object(entry)
    }

    /// Keeps tool results inside what a model can usefully read.
    static func clip(_ text: String, keepEnd: Bool, limit: Int = 60_000) -> String {
        guard text.count > limit else { return text }
        if keepEnd { return "… (\(text.count - limit) earlier characters cut)\n" + text.suffix(limit) }
        return text.prefix(limit) + "\n… (\(text.count - limit) more characters cut)"
    }
}
