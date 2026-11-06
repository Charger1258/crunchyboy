import Foundation
import SwiftSoup

/// TV's AniKoto HLS gateways, with identity checks before accepting any episode.
struct AniKotoAdapter: StreamAdapter {
    let name = "AniKoto"
    let gateway: URL
    private let http = HTTPClient(timeout: 7)
    func resolve(_ episode: Episode) async throws -> [ResolvedStream] {
        let number = episode.localNumber ?? episode.number
        guard number > 0, number.rounded() == number else { return [] }
        let watch = AnimeCatalog.root.appendingPathComponent("watch/\(episode.release)")
        let page = try SwiftSoup.parse(await http.text(watch), watch.absoluteString)
        let links = try page.select("a.dynamic-name[title][data-jname][href]").array()
        guard let title = try links.first(where: { try $0.absUrl("href") == watch.absoluteString }),
              let anime = await ReleaseIdentity.shared.resolve([try title.attr("data-jname"), try title.attr("title")]) else { return [] }
        let url = gateway.appendingPathComponent("watch/anikoto/\(anime)/sub/anikoto-\(Int(number))")
        let text = try await http.text(url)
        let decoded = try Self.decode(text, anime: anime, episode: Int(number), gateway: gateway)
        return await withTaskGroup(of: ResolvedStream?.self) { group in
            for stream in decoded.prefix(12) {
                group.addTask {
                    do {
                        let (data, _) = try await http.bytes(stream.url, referer: stream.referer, limit: 1_000_000, headers: stream.headers)
                        guard let playlist = String(data: data, encoding: .utf8), playlist.hasPrefix("#EXTM3U") else { return nil }
                        let regex = try NSRegularExpression(pattern: "RESOLUTION=[0-9]+x([0-9]{2,4})")
                        let text = playlist as NSString
                        let height = regex.matches(in: playlist, range: NSRange(location: 0, length: text.length))
                            .compactMap { Int(text.substring(with: $0.range(at: 1))) }.max() ?? stream.height
                        return ResolvedStream(url: stream.url, referer: stream.referer, height: height,
                                              source: stream.source, headers: stream.headers, subtitles: stream.subtitles)
                    } catch { await SourceHealth.shared.failed(stream); return nil }
                }
            }
            var results: [ResolvedStream] = []
            for await stream in group { if let stream { results.append(stream) } }
            return results
        }
    }
    static func decode(_ text: String, anime: Int, episode: Int, gateway: URL) throws -> [ResolvedStream] {
        guard let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              json["anilistId"] as? Int == anime, json["episode"] as? Int == episode,
              json["audio"] as? String == "sub" else { throw StreamError.invalidResponse }
        let rows = json["streams"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard row["type"] as? String == "hls", let address = row["url"] as? String,
                  let url = SafeURL.https(address), url.path.hasSuffix(".m3u8") else { return nil }
            let supplied = row["headers"] as? [String: String] ?? [:]
            let headers = supplied.filter { key, value in
                ["User-Agent", "Referer", "Origin"].contains(key) && !value.contains("\r") && !value.contains("\n")
                    && (key == "User-Agent" || SafeURL.https(value) != nil)
            }
            let subtitles = (row["subtitles"] as? [[String: String]] ?? []).compactMap { track -> SubtitleTrack? in
                guard let url = SafeURL.https(track["url"] ?? "") else { return nil }
                return SubtitleTrack(url: url, language: track["srclang"] ?? "und", label: track["label"] ?? "Subtitles")
            }
            let quality = row["quality"] as? String ?? ""
            let height = Int(quality.filter(\.isNumber)) ?? 0
            return ResolvedStream(url: url, referer: SafeURL.https(headers["Referer"] ?? "") ?? gateway,
                                  height: height, source: "AniKoto / " + (row["server"] as? String ?? "HLS"),
                                  headers: headers, subtitles: subtitles)
        }
    }
}

/// A failed source gets TV's 30 minute cooldown; quality decides order within each tier.
actor SourceHealth {
    static let shared = SourceHealth()
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func failed(_ stream: ResolvedStream) { defaults.set(Date().addingTimeInterval(1800).timeIntervalSince1970, forKey: "sourceFailure:" + stream.reliabilityKey) }
    func succeeded(_ stream: ResolvedStream) { defaults.removeObject(forKey: "sourceFailure:" + stream.reliabilityKey) }
    func ranked(_ streams: [ResolvedStream], now: Date = Date()) -> [ResolvedStream] {
        streams.sorted {
            let left = defaults.double(forKey: "sourceFailure:" + $0.reliabilityKey) > now.timeIntervalSince1970
            let right = defaults.double(forKey: "sourceFailure:" + $1.reliabilityKey) > now.timeIntervalSince1970
            if left != right { return !left }
            if $0.height != $1.height { return $0.height > $1.height }
            return $0.source < $1.source
        }
    }
}
