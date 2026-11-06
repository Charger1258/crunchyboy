import Foundation

struct HTTPClient {
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 18
        config.timeoutIntervalForResource = 35
        config.httpMaximumConnectionsPerHost = 2
        config.httpCookieStorage = nil
        session = URLSession(configuration: config)
    }

    func text(_ url: URL, referer: URL? = nil, limit: Int = 8_000_000, ajax: Bool = false) async throws -> String {
        let (data, _) = try await bytes(url, referer: referer, limit: limit, ajax: ajax)
        guard let text = String(data: data, encoding: .utf8) else { throw StreamError.invalidResponse }
        return text
    }

    func bytes(_ url: URL, referer: URL? = nil, range: String? = nil,
               limit: Int = 32_000_000, ajax: Bool = false) async throws -> (Data, HTTPURLResponse) {
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
