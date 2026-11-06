import Foundation
import Network

/// A loopback-only, per-playback relay. No hosted proxy and no undocumented AVPlayer header APIs.
actor MediaRelay {
    private let queue = DispatchQueue(label: "stream.anime.loopback")
    private let http = HTTPClient()
    private var listener: NWListener?
    private var port: NWEndpoint.Port?
    private var routes: [String: URL] = [:]
    private var reverseRoutes: [URL: String] = [:]
    private var referer: URL?
    private var connections: [UUID: NWConnection] = [:]
    private var requests: [UUID: Task<Void, Never>] = [:]

    func start(_ stream: ResolvedStream) async throws -> URL {
        stop()
        referer = stream.referer
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let server = try NWListener(using: parameters)
        listener = server
        server.newConnectionHandler = { [weak self] connection in
            connection.start(queue: DispatchQueue.global(qos: .userInitiated))
            Self.receiveHeaders(connection, accumulated: Data()) { data in
                Task { await self?.accept(connection, request: data) }
            }
        }
        let bound: NWEndpoint.Port = try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var resumed = false
            server.stateUpdateHandler = { state in
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    if let port = server.port { continuation.resume(returning: port) }
                    else { continuation.resume(throwing: StreamError.invalidResponse) }
                case .failed(let error): resumed = true; continuation.resume(throwing: error)
                case .cancelled: resumed = true; continuation.resume(throwing: CancellationError())
                default: break
                }
            }
            server.start(queue: queue)
        }
        try Task.checkCancellation()
        port = bound
        return try route(stream.url)
    }

    func stop() {
        listener?.cancel(); listener = nil; port = nil
        for request in requests.values { request.cancel() }
        for connection in connections.values { connection.cancel() }
        requests.removeAll(); connections.removeAll(); routes.removeAll(); reverseRoutes.removeAll()
    }

    private func route(_ remote: URL) throws -> URL {
        guard SafeURL.https(remote.absoluteString) != nil, let port else { throw StreamError.insecureURL }
        if let key = reverseRoutes[remote] { return URL(string: "http://127.0.0.1:\(port.rawValue)/\(key)")! }
        guard routes.count < 12000 else { throw StreamError.invalidResponse }
        let key = UUID().uuidString
        routes[key] = remote; reverseRoutes[remote] = key
        return URL(string: "http://127.0.0.1:\(port.rawValue)/\(key)")!
    }

    private nonisolated static func receiveHeaders(_ connection: NWConnection, accumulated: Data,
                                                   complete: @escaping (Data?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, ended, error in
            var bytes = accumulated
            if let data { bytes.append(data) }
            if bytes.count > 32768 || error != nil { complete(nil); return }
            if bytes.range(of: Data("\r\n\r\n".utf8)) != nil { complete(bytes); return }
            if ended { complete(nil); return }
            receiveHeaders(connection, accumulated: bytes, complete: complete)
        }
    }

    private func accept(_ connection: NWConnection, request: Data?) {
        guard let request, connections.count < 16 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        requests[id] = Task { [weak self] in await self?.respond(connection, id: id, request: request) }
    }

    private func respond(_ connection: NWConnection, id: UUID, request: Data) async {
        defer { requests[id] = nil; connections[id] = nil }
        do {
            guard let text = String(data: request, encoding: .utf8), let first = text.components(separatedBy: "\r\n").first else {
                throw StreamError.invalidResponse
            }
            let fields = first.split(separator: " ")
            guard fields.count == 3, fields[0] == "GET" || fields[0] == "HEAD" else { throw StreamError.invalidResponse }
            let path = String(fields[1]).split(separator: "?").first.map(String.init) ?? ""
            guard path.hasPrefix("/"), let remote = routes[String(path.dropFirst())], let referer else { throw StreamError.invalidResponse }
            let range = text.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("range:") }?
                .split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
            let (bytes, response) = try await http.bytes(remote, referer: referer, range: range)
            try Task.checkCancellation()
            var body = bytes
            var contentType = response.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
            var contentRange = response.value(forHTTPHeaderField: "Content-Range")
            if let playlist = String(data: bytes, encoding: .utf8), playlist.hasPrefix("#EXTM3U") {
                body = Data(try Self.rewritePlaylist(playlist, base: response.url ?? remote, route: route).utf8)
                contentType = "application/vnd.apple.mpegurl"
                contentRange = nil
            }
            var headers = "HTTP/1.1 \(response.statusCode) OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nAccept-Ranges: bytes\r\n"
            if let contentRange { headers += "Content-Range: \(contentRange)\r\n" }
            headers += "\r\n"
            var payload = Data(headers.utf8)
            if fields[0] != "HEAD" { payload.append(body) }
            connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
        } catch {
            // Never log stream URLs, tokens, cookies, or request headers.
            connection.send(content: Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                            completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    static func rewritePlaylist(_ playlist: String, base: URL, route: (URL) throws -> URL) throws -> String {
        let uri = try NSRegularExpression(pattern: #"URI="([^"]+)""#)
        return try playlist.components(separatedBy: .newlines).map { line in
            let stripped = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if stripped.isEmpty { return line }
            if !stripped.hasPrefix("#") {
                guard let url = URL(string: stripped, relativeTo: base)?.absoluteURL else { throw StreamError.invalidResponse }
                return try route(url).absoluteString
            }
            let original = line as NSString
            var rewritten = line
            for match in uri.matches(in: line, range: NSRange(location: 0, length: original.length)).reversed() {
                let value = original.substring(with: match.range(at: 1))
                guard let url = URL(string: value, relativeTo: base)?.absoluteURL,
                      let range = Range(match.range(at: 1), in: rewritten) else { throw StreamError.invalidResponse }
                rewritten.replaceSubrange(range, with: try route(url).absoluteString)
            }
            return rewritten
        }.joined(separator: "\n")
    }
}
