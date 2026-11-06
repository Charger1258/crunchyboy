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
        for adapter in adapters {
            try Task.checkCancellation()
            do { candidates += try await adapter.resolve(episode) }
            catch is CancellationError { throw CancellationError() }
            catch { continue }
        }
        guard !candidates.isEmpty else { throw StreamError.noStream }
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
        let response = try await http.text(address.url!)
        let payload = try JSONDecoder().decode(Response.self, from: Data(response.utf8))
        let page = try SwiftSoup.parseBodyFragment(payload.html)
        var streams: [ResolvedStream] = []
        for server in try page.select(".server-item[data-hash][data-server-name=ZokoAnime][data-type=sub]").array() {
            try Task.checkCancellation()
            do {
                let hash = try server.attr("data-hash")
                guard let decoded = Data(base64Encoded: hash, options: .ignoreUnknownCharacters),
                      let embedText = String(data: decoded, encoding: .utf8),
                      let embed = SafeURL.https(embedText, host: "zokoanime.video") else { continue }
                let html = try await http.text(embed, referer: AnimeCatalog.root)
                let config = try Self.decodePlayer(html)
                guard let media = SafeURL.https(config.src), media.path.hasSuffix(".m3u8") else { continue }
                let referer = URL(string: "https://zokoanime.video/")!
                let playlist = try await http.text(media, referer: referer)
                guard playlist.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else { continue }
                let regex = try NSRegularExpression(pattern: "RESOLUTION=[0-9]+x([0-9]{2,4})")
                let ns = playlist as NSString
                let height = regex.matches(in: playlist, range: NSRange(location: 0, length: ns.length))
                    .compactMap { Int(ns.substring(with: $0.range(at: 1))) }.max() ?? 0
                streams.append(ResolvedStream(url: media, referer: referer, height: height, source: name))
            } catch is CancellationError { throw CancellationError() }
            catch { continue }
        }
        return streams
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
