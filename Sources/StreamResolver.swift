import Foundation
import SwiftSoup

protocol StreamAdapter {
    var name: String { get }
    func resolve(_ episode: Episode) async throws -> [ResolvedStream]
}

/// Adapters remain separate so additional providers can be ported without changing the player.
actor StreamResolver {
    private let adapters: [any StreamAdapter] = [HiAnimeStreamAdapter()]

    func resolve(_ episode: Episode) async throws -> [ResolvedStream] {
        var candidates: [ResolvedStream] = []
        var failures: [String] = []
        for adapter in adapters {
            try Task.checkCancellation()
            do { candidates += try await adapter.resolve(episode) }
            catch is CancellationError { throw CancellationError() }
            catch { failures.append("\(adapter.name): \(error.localizedDescription)") }
        }
        guard !candidates.isEmpty else {
            throw failures.isEmpty ? StreamError.noStream : StreamError.unavailable(failures.joined(separator: "\n"))
        }
        return candidates.sorted { $0.height > $1.height }
    }
}

struct HiAnimeStreamAdapter: StreamAdapter {
    let name = "ZokoAnime"
    private let http = HTTPClient()

    func resolve(_ episode: Episode) async throws -> [ResolvedStream] {
        var address = URLComponents(url: AnimeCatalog.root.appendingPathComponent("api/theme/episode/servers"), resolvingAgainstBaseURL: false)!
        address.queryItems = [URLQueryItem(name: "episodeId", value: episode.id)]
        struct Response: Decodable { let html: String }
        var watch = URLComponents(url: AnimeCatalog.root.appendingPathComponent("watch/\(episode.release)"), resolvingAgainstBaseURL: false)!
        watch.queryItems = [URLQueryItem(name: "ep", value: episode.id)]
        let response = try await http.text(address.url!, referer: watch.url, ajax: true)
        let payload = try JSONDecoder().decode(Response.self, from: Data(response.utf8))
        let page = try SwiftSoup.parseBodyFragment(payload.html)
        var streams: [ResolvedStream] = []
        var failures: [String] = []
        for server in try page.select(".server-item[data-hash][data-server-name=ZokoAnime][data-type=sub]").array() {
            try Task.checkCancellation()
            var stage = "player address"
            do {
                let hash = try server.attr("data-hash")
                guard let decoded = Data(base64Encoded: hash, options: .ignoreUnknownCharacters),
                      let embedText = String(data: decoded, encoding: .utf8),
                      let embed = SafeURL.https(embedText, host: "zokoanime.video") else { throw StreamError.invalidResponse }
                stage = "player page"
                let html = try await http.text(embed, referer: AnimeCatalog.root.appendingPathComponent(""))
                stage = "player configuration"
                let config = try Self.decodePlayer(html)
                guard let media = SafeURL.https(config.src), media.path.hasSuffix(".m3u8") else { throw StreamError.invalidResponse }
                let referer = URL(string: "https://zokoanime.video/")!
                stage = "video manifest"
                let playlist = try await http.text(media, referer: referer)
                guard playlist.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else { throw StreamError.invalidResponse }
                let regex = try NSRegularExpression(pattern: "RESOLUTION=[0-9]+x([0-9]{2,4})")
                let ns = playlist as NSString
                let height = regex.matches(in: playlist, range: NSRange(location: 0, length: ns.length))
                    .compactMap { Int(ns.substring(with: $0.range(at: 1))) }.max() ?? 0
                streams.append(ResolvedStream(url: media, referer: referer, height: height, source: name))
            } catch is CancellationError { throw CancellationError() }
            catch {
                let reason = (error as? URLError).map { Self.networkReason($0) } ?? error.localizedDescription
                failures.append("Couldn’t load the \(stage). \(reason)")
            }
        }
        if streams.isEmpty, let failure = failures.last { throw StreamError.unavailable(failure) }
        return streams
    }

    static func networkReason(_ error: URLError) -> String {
        switch error.code {
        case .timedOut: return "The video source timed out. Try again later."
        case .cannotFindHost, .dnsLookupFailed: return "The video source’s address could not be found."
        case .cannotConnectToHost: return "The video source could not be reached."
        case .notConnectedToInternet: return "Check your internet connection."
        default: return error.localizedDescription
        }
    }

    struct PlayerConfig: Decodable { let src: String }

    static func decodePlayer(_ html: String) throws -> PlayerConfig {
        let regex = try NSRegularExpression(pattern: #"window\.__P\s*=\s*"([^"]+)""#)
        let ns = html as NSString
        guard let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
              let encoded = Data(base64Encoded: ns.substring(with: match.range(at: 1)), options: .ignoreUnknownCharacters)
        else { throw StreamError.invalidResponse }
        let mask = Array("otaku-embed-v1".utf8)
        let decoded = Data(encoded.enumerated().map { index, byte in byte ^ mask[index % mask.count] })
        return try JSONDecoder().decode(PlayerConfig.self, from: decoded)
    }
}
