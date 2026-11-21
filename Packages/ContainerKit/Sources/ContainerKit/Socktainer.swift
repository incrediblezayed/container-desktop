import Foundation

/// Socktainer serves the Docker API over a Unix socket and resolves service names for the
/// containers it creates: its per-network DNS helper only forwards queries to it.
///
/// It registers a container's names when the container starts *through its API*. Starting
/// one of its containers with the `container` CLI works, but leaves the names unregistered,
/// so services can't find each other. Its containers are therefore started and stopped
/// through the socket whenever Socktainer is running.
public enum Socktainer {
    public static var defaultSocketPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".socktainer/container.sock").path
    }

    /// True when something accepts connections on the socket.
    public static func isRunning(socketPath: String = defaultSocketPath) -> Bool {
        guard let fd = try? connect(socketPath) else { return false }
        close(fd)
        return true
    }

    public static func start(container id: String, socketPath: String = defaultSocketPath) async throws {
        // 304 means it was already running.
        try await post("/containers/\(escape(id))/start", accepting: [204, 304], socketPath: socketPath, timeout: .seconds(120))
    }

    public static func stop(container id: String, socketPath: String = defaultSocketPath) async throws {
        try await post("/containers/\(escape(id))/stop", accepting: [204, 304], socketPath: socketPath, timeout: .seconds(120))
    }

    // MARK: HTTP over the socket

    public struct APIError: LocalizedError, Equatable {
        public var status: Int
        public var message: String
        public var errorDescription: String? { "Socktainer returned \(status): \(message)" }
    }

    static func escape(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id
    }

    static func post(_ path: String, accepting: Set<Int>, socketPath: String, timeout: Duration) async throws {
        let response = try await Task.detached {
            try request(method: "POST", path: path, socketPath: socketPath, timeout: timeout)
        }.value
        guard accepting.contains(response.status) else {
            throw APIError(status: response.status, message: Self.message(from: response.body))
        }
    }

    /// The Docker API puts errors in `{"message": "..."}`.
    static func message(from body: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let message = object["message"] as? String {
            return message
        }
        return String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct Response {
        var status: Int
        var body: Data
    }

    /// A blocking HTTP/1.1 request with `Connection: close`, so the body is everything until EOF.
    static func request(method: String, path: String, socketPath: String, timeout: Duration) throws -> Response {
        let fd = try connect(socketPath)
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout.components.seconds), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let head = "\(method) \(path) HTTP/1.1\r\nHost: docker\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        let bytes = Array(head.utf8)
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            sent += n
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 { data.append(buffer, count: n); continue }
            if n == 0 { break }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> Response {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else { throw POSIXError(.EBADMSG) }
        let head = String(decoding: data[..<split.lowerBound], as: UTF8.self)
        let statusLine = head.split(separator: "\r\n", maxSplits: 1).first ?? ""
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else { throw POSIXError(.EBADMSG) }
        var body = Data(data[split.upperBound...])
        if head.lowercased().contains("transfer-encoding: chunked") { body = dechunk(body) }
        return Response(status: status, body: body)
    }

    static func dechunk(_ data: Data) -> Data {
        var out = Data()
        var index = data.startIndex
        while let lineEnd = data[index...].range(of: Data("\r\n".utf8)) {
            let sizeText = String(decoding: data[index..<lineEnd.lowerBound], as: UTF8.self)
            guard let size = Int(sizeText.split(separator: ";").first ?? "", radix: 16), size > 0 else { break }
            let start = lineEnd.upperBound
            let end = data.index(start, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
            out.append(data[start..<end])
            index = data.index(end, offsetBy: 2, limitedBy: data.endIndex) ?? data.endIndex
        }
        return out
    }

    static func connect(_ socketPath: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < capacity else { close(fd); throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED
            close(fd)
            throw POSIXError(code)
        }
        return fd
    }
}

extension ContainerSummary {
    /// Created through Socktainer's Docker API (Compose services, `docker run`).
    public var isSocktainerManaged: Bool {
        labels.keys.contains { $0.hasPrefix("io.github.socktainer.") || $0.hasPrefix("com.socktainer.") }
    }
}
