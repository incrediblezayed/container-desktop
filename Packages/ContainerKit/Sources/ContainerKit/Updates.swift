import Foundation

/// Release checks for the runtime pieces the app depends on but doesn't ship.
public enum Updates {
    public struct Release: Sendable, Hashable {
        public var version: String
        public var url: URL
        public var publishedAt: Date?
    }

    public static let containerRepository = "apple/container"
    public static let socktainerRepository = "socktainer/socktainer"

    /// The newest published (non-draft, non-prerelease) release. Sends no identifying data.
    public static func latestRelease(of repository: String, session: URLSession = .shared) async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ContainerDesktop", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try parseRelease(data)
    }

    static func parseRelease(_ data: Data) throws -> Release {
        struct Payload: Decodable {
            var tag_name: String
            var html_url: URL
            var published_at: Date?
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(Payload.self, from: data)
        return Release(version: normalize(payload.tag_name), url: payload.html_url, publishedAt: payload.published_at)
    }

    /// "v1.6.1" → "1.6.1"; "1.6.1-11-gb8439ea" → "1.6.1-11-gb8439ea".
    public static func normalize(_ version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
    }

    /// Compares dotted numeric versions; anything after the numbers (a build suffix) is ignored.
    /// Returns nil when either side has no version number at all.
    public static func isNewer(_ candidate: String, than installed: String) -> Bool? {
        guard let a = numbers(candidate), let b = numbers(installed) else { return nil }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func numbers(_ version: String) -> [Int]? {
        let core = normalize(version).prefix { $0.isNumber || $0 == "." }
        let parts = core.split(separator: ".").compactMap { Int($0) }
        return parts.isEmpty ? nil : parts
    }

    /// Apple's installer ships `update-container.sh` next to the CLI. It downloads the newest
    /// signed package and installs it with `sudo installer`; data in the app root is kept.
    public static func containerUpdateScript(cli: URL) -> URL? {
        let script = cli.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("update-container.sh")
        return FileManager.default.isExecutableFile(atPath: script.path) ? script : nil
    }

    /// The command that updates the runtime in place: the script refuses to run while the
    /// system is up, and the system comes back afterwards.
    public static func containerUpdateCommand(cli: URL, script: URL) -> String {
        let container = Shell.quote(cli.path)
        return "\(container) system stop && \(Shell.quote(script.path)) && \(container) system start --enable-kernel-install"
    }
}

extension Socktainer {
    /// The exit code Socktainer recorded for a stopped container. Apple's runtime keeps none.
    public static func exitCode(container id: String, socketPath: String = defaultSocketPath) async -> Int? {
        let response = try? await Task.detached {
            try request(method: "GET", path: "/containers/\(escape(id))/json", socketPath: socketPath, timeout: .seconds(5))
        }.value
        guard let response, response.status == 200,
              let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let state = object["State"] as? [String: Any], state["Running"] as? Bool != true
        else { return nil }
        return (state["ExitCode"] as? NSNumber)?.intValue
    }

    /// The version Socktainer reports through the Docker API (`GET /version`).
    public static func version(socketPath: String = defaultSocketPath) async throws -> String {
        let response = try await Task.detached {
            try request(method: "GET", path: "/version", socketPath: socketPath, timeout: .seconds(5))
        }.value
        guard response.status == 200,
              let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let version = object["Version"] as? String
        else { throw APIError(status: response.status, message: message(from: response.body)) }
        return Updates.normalize(version)
    }
}
