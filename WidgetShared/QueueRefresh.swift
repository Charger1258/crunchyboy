import Foundation
import SwiftSoup

enum QueueRefresh {
    private static let root = URL(string: "https://hianime.at")!

    static func refresh(_ snapshot: QueueSnapshot) async -> QueueSnapshot {
        let previous = QueueRefreshCache.read()
        var cache = QueueRefreshCache(baseline: snapshot)
        if let previous, previous.baseline.profileID == snapshot.profileID {
            for show in snapshot.watched where previous.baseline.watched.contains(show) {
                cache.discoveries[show.id] = previous.discoveries[show.id]
                cache.checked[show.id] = previous.checked[show.id]
            }
        }
        // Bound requests per widget execution. Recently watched shows are exported
        // first, then older checks rotate forward on subsequent timelines.
        let pending = snapshot.watched.filter { $0.next == nil }
            .sorted { (cache.checked[$0.id] ?? .distantPast) < (cache.checked[$1.id] ?? .distantPast) }
            .prefix(12)
        let shows = Array(pending)
        for offset in stride(from: 0, to: shows.count, by: 4) {
            await withTaskGroup(of: (String, QueueSnapshot.Item?, Bool).self) { group in
                for show in shows[offset..<min(offset + 4, shows.count)] {
                    group.addTask {
                        do { return (show.id, try await nextEpisode(show), true) }
                        catch { return (show.id, nil, false) }
                    }
                }
                for await (id, item, success) in group {
                    cache.checked[id] = .now
                    if success { cache.discoveries[id] = item }
                }
            }
        }
        // A profile change or playback update may have happened during requests.
        guard QueueSnapshotStore.read() == snapshot else { return QueueSnapshotStore.read() ?? snapshot }
        try? cache.write()
        var result = snapshot
        result.items = snapshot.watched.compactMap { $0.next ?? cache.discoveries[$0.id] }
        return result
    }

    private static func nextEpisode(_ show: QueueSnapshot.WatchedShow) async throws -> QueueSnapshot.Item? {
        guard let first = show.releases.first else { return nil }
        var releases = show.releases
        // Follow catalog season links so newly listed seasons can be discovered.
        let watch = root.appendingPathComponent("watch/" + first.slug)
        let page = try SwiftSoup.parse(await text(watch), root.absoluteString)
        let lastSeason = releases.map(\.season).max() ?? first.season
        for link in try page.select(".os-list a.os-item[href]").array() {
            let words = try link.select(".title").text().split(separator: " ")
            guard words.count >= 2, words[0].lowercased() == "season",
                  let season = Int(words[1].prefix(while: \.isNumber)), season > lastSeason,
                  let url = URL(string: try link.absUrl("href")), url.host == root.host,
                  url.scheme == "https",
                  !releases.contains(where: { $0.slug == url.lastPathComponent }) else { continue }
            releases.append(.init(slug: url.lastPathComponent, season: season))
        }
        releases.sort { $0.season < $1.season }
        for release in releases {
            guard let id = release.slug.split(separator: "-").last, Int(id) != nil else { continue }
            let html = try await text(root.appendingPathComponent("api/theme/episode/list/" + id))
            if let item = try parseEpisodes(html, show: show, release: release, anchor: first.slug) {
                return item
            }
        }
        return nil
    }

    static func parseEpisodes(_ html: String, show: QueueSnapshot.WatchedShow,
                              release: QueueSnapshot.WatchedShow.Release, anchor: String) throws -> QueueSnapshot.Item? {
            struct Response: Decodable { let html: String }
            let response = try JSONDecoder().decode(Response.self, from: Data(html.utf8))
            let document = try SwiftSoup.parseBodyFragment(response.html, root.absoluteString)
            var candidates: [(Double, String)] = []
            for row in try document.select("a.ep-item[data-id][data-number][href]").array() {
                let id = try row.attr("data-id")
                guard !id.isEmpty, id.allSatisfy(\.isNumber), !show.completedIDs.contains(id),
                      let number = Double(try row.attr("data-number")), number.isFinite, number > 0,
                      release.slug != anchor || number >= show.anchorNumber,
                      let url = URL(string: try row.absUrl("href")), url.scheme == "https", url.host == root.host,
                      url.path == "/watch/" + release.slug,
                      URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "ep" })?.value == id else { continue }
                candidates.append((number, id))
            }
            if let next = candidates.min(by: { $0.0 < $1.0 }) {
                let label = "S\(release.season) · E\(next.0.formatted(.number.precision(.fractionLength(0...1))))"
                return .init(id: next.1, title: show.title, episode: label, artwork: show.poster,
                             release: release.slug, season: release.season, number: next.0)
            }
        return nil
    }

    private static func text(_ url: URL) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue(root.absoluteString + "/", forHTTPHeaderField: "Referer")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              data.count <= 3_000_000, let text = String(data: data, encoding: .utf8) else {
            throw URLError(.badServerResponse)
        }
        return text
    }
}
