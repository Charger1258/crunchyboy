import Foundation

struct HTTPClient {
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    private let session: URLSession

    init(timeout: TimeInterval = 10) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        config.httpMaximumConnectionsPerHost = 2
        config.httpCookieStorage = nil
        session = URLSession(configuration: config)
    }

    func text(_ url: URL, referer: URL? = nil, limit: Int = 8_000_000, ajax: Bool = false) async throws -> String {
        let (data, _) = try await bytes(url, referer: referer, limit: limit, ajax: ajax)
        guard let text = String(data: data, encoding: .utf8) else { throw StreamError.invalidResponse }
        return text
    }

    func postJSON(_ url: URL, body: [String: Any]) async throws -> Data {
        guard SafeURL.https(url.absoluteString) != nil else { throw StreamError.insecureURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.url?.scheme == "https",
              (200...299).contains(response.statusCode), data.count <= 2_000_000 else { throw StreamError.invalidResponse }
        return data
    }

    func bytes(_ url: URL, referer: URL? = nil, range: String? = nil,
               limit: Int = 32_000_000, ajax: Bool = false, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        guard SafeURL.https(url.absoluteString) != nil else { throw StreamError.insecureURL }
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let referer {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }
        if ajax {
            request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            request.setValue("*/*", forHTTPHeaderField: "Accept")
        }
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        for (key, value) in headers where ["user-agent", "referer", "origin"].contains(key.lowercased()) {
            guard !value.contains("\r"), !value.contains("\n") else { continue }
            if key.lowercased() == "user-agent" || SafeURL.https(value) != nil { request.setValue(value, forHTTPHeaderField: key) }
        }
        // Stream into a bounded buffer so an unexpected download cannot exhaust memory.
        let (incoming, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw StreamError.invalidResponse }
        guard http.url?.scheme == "https" else { throw StreamError.insecureURL }
        guard (200...299).contains(http.statusCode) else {
            throw StreamError.unavailable(http.statusCode == 429
                ? "The source is busy. Wait a moment and try again."
                : "The source couldn’t load (HTTP \(http.statusCode)). Try again.")
        }
        var data = Data()
        for try await byte in incoming {
            if data.count >= limit { throw StreamError.invalidResponse }
            data.append(byte)
            if data.count % 65536 == 0 { try Task.checkCancellation() }
        }
        return (data, http)
    }
}
