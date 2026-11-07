import Foundation
import SwiftSoup

enum CatalogShelf: String, CaseIterable, Identifiable {
    case today, week, updated, series, films
    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: return "Popular today"
        case .week: return "Popular this week"
        case .updated: return "Recently updated"
        case .series: return "Anime series"
        case .films: return "Anime films"
        }
    }
    var path: String? {
        switch self {
        case .today, .week: return nil
        case .updated: return "/recently-updated"
        case .series: return "/tv"
        case .films: return "/movie"
        }
    }
    var chartID: String? {
        switch self {
        case .today: return "top-viewed-day"
        case .week: return "top-viewed-week"
        default: return nil
        }
    }
}

protocol AnimeCatalogProviding {
    func browse(path: String) async throws -> [AnimeTitle]
    func search(_ query: String) async throws -> [AnimeTitle]
    func details(_ title: AnimeTitle) async throws -> ShowDetail
}

actor AnimeCatalog: AnimeCatalogProviding {
    static let root = URL(string: "https://hianime.at")!
    private let http = HTTPClient()
    private var cache: [String: ShowDetail] = [:]
    private var rankingCache: (loaded: Date, lists: [CatalogShelf: [AnimeTitle]])?

    func browse(shelf: CatalogShelf, refresh: Bool = false) async throws -> [AnimeTitle] {
        if let path = shelf.path { return try await browse(path: path) }
        if !refresh, let cached = rankingCache, Date().timeIntervalSince(cached.loaded) < 60,
           let titles = cached.lists[shelf], !titles.isEmpty { return titles }
        let html = try await http.text(Self.root.appendingPathComponent("home"))
        let lists = try Self.parseRankings(html)
        rankingCache = (Date(), lists)
        guard let titles = lists[shelf], !titles.isEmpty else {
            throw StreamError.unavailable("This popularity chart couldn’t load. Try again.")
        }
        return titles
    }

    static func parseRankings(_ html: String) throws -> [CatalogShelf: [AnimeTitle]] {
        let page = try SwiftSoup.parse(html, root.absoluteString)
        var lists: [CatalogShelf: [AnimeTitle]] = [:]
        for shelf in CatalogShelf.allCases {
            guard let chart = shelf.chartID else { continue }
            var seen = Set<String>()
            var titles: [AnimeTitle] = []
            for row in try page.select("#\(chart) li").array() {
                guard let link = try row.select(".film-name a[href]").first(),
                      let url = SafeURL.https(try link.absUrl("href"), host: root.host) else { continue }
                let parts = url.path.split(separator: "/")
                guard parts.count == 1 || (parts.count == 2 && parts[0] == "watch") else { continue }
                let slug = url.lastPathComponent
                guard slug.range(of: "^[a-z0-9-]+-[0-9]+$", options: .regularExpression) != nil,
                      seen.insert(slug).inserted else { continue }
                let label = try link.attr("title").trimmingCharacters(in: .whitespacesAndNewlines)
                let name = try (label.isEmpty ? link.text() : label)
                guard !name.isEmpty else { continue }
                let image = try row.select("img.film-poster-img").first()
                let lazy = try image?.absUrl("data-src") ?? ""
                let immediate = try image?.absUrl("src") ?? ""
                titles.append(AnimeTitle(slug: slug, name: name, poster: SafeURL.https(lazy) ?? SafeURL.https(immediate)))
            }
            lists[shelf] = Self.group(titles)
        }
        return lists
    }

    func browse(path: String = "/most-popular") async throws -> [AnimeTitle] {
        let url = Self.root.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        return Self.group(try Self.parseTitles(await http.text(url)))
    }

    func search(_ query: String) async throws -> [AnimeTitle] {
        Self.group(try await searchReleases(query))
    }
    private func searchReleases(_ query: String) async throws -> [AnimeTitle] {
        var url = URLComponents(url: Self.root.appendingPathComponent("search"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "keyword", value: query)]
        return try Self.parseTitles(await http.text(url.url!))
    }

    static func group(_ titles: [AnimeTitle]) -> [AnimeTitle] {
        var seen = Set<String>()
        return titles.filter { seen.insert($0.id).inserted }
    }

    static func parseTitles(_ html: String) throws -> [AnimeTitle] {
        let page = try SwiftSoup.parse(html, root.absoluteString)
        var seen = Set<String>()
        return try page.select(".flw-item").array().compactMap { card in
            guard let link = try card.select("a.film-poster-ahref[href]").first(),
                  let url = SafeURL.https(try link.absUrl("href"), host: root.host),
                  url.path.hasPrefix("/watch/"), seen.insert(url.lastPathComponent).inserted else { return nil }
            let name = try link.attr("title").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let image = try card.select("img.film-poster-img").first()
            let lazy = try image?.absUrl("data-src") ?? ""
            let immediate = try image?.absUrl("src") ?? ""
            let poster = SafeURL.https(lazy) ?? SafeURL.https(immediate)
            return AnimeTitle(slug: url.lastPathComponent, name: name, poster: poster)
        }
    }

    func details(_ title: AnimeTitle) async throws -> ShowDetail {
        let watch = Self.root.appendingPathComponent("watch/\(title.slug)")
        let page = try SwiftSoup.parse(await http.text(watch), watch.absoluteString)
        var releases: [(String, Int)] = []
        for link in try page.select(".os-list a.os-item[href]").array() {
            let label = try link.select(".title").text()
            guard let season = Self.seasonNumber(label),
                  let url = SafeURL.https(try link.absUrl("href"), host: Self.root.host) else { continue }
            releases.append((url.lastPathComponent, season))
        }
        if !releases.contains(where: { $0.0 == title.slug }) { releases.append((title.slug, 1)) }
        let metadata = AnimeMetadata.shared
        var identities: [String: Int] = [:]
        if let id = await ReleaseIdentity.shared.resolve([try page.select("a.dynamic-name[data-jname]").attr("data-jname"), title.name]) { identities[title.slug] = id }
        // Search broadly, then require the same structured TVDB series identity.
        // Titles alone never establish a season relationship.
        if let series = metadata.series(identities[title.slug]) {
            let candidates = (try? await searchReleases(title.name)) ?? []
            for candidate in candidates {
                guard let id = await ReleaseIdentity.shared.resolve([candidate.name]), metadata.series(id) == series else { continue }
                identities[candidate.slug] = id
                if !releases.contains(where: { $0.0 == candidate.slug }) {
                    let season = metadata.ranges(id).first?[1] as? Int ?? 1
                    releases.append((candidate.slug, season))
                }
            }
        }
        var episodes: [Episode] = []
        var failures = 0
        for (slug, season) in releases {
            try Task.checkCancellation()
            guard let id = slug.split(separator: "-").last, Int(id) != nil else { continue }
            do {
                let address = Self.root.appendingPathComponent("api/theme/episode/list/\(id)")
                let response = try await http.text(address)
                var parsed = try Self.parseEpisodes(response, release: slug, season: season)
                var identity = identities[slug]
                if identity == nil, let html = try? await http.text(Self.root.appendingPathComponent("watch/\(slug)")),
                   let releasePage = try? SwiftSoup.parse(html) {
                    identity = await ReleaseIdentity.shared.resolve([try releasePage.select("a.dynamic-name[title]").attr("title"),
                                                  try releasePage.select("a.dynamic-name[data-jname]").attr("data-jname")])
                }
                parsed = metadata.mapped(parsed, id: identity)
                if let identity { parsed = await EpisodeArtwork.shared.enrich(parsed, anime: identity) }
                episodes += parsed
            } catch is CancellationError { throw CancellationError() }
            catch { failures += 1 }
        }
        // Preserve already-known releases if the provider temporarily returns only some seasons.
        let merged = Self.merge(episodes, cache[title.id]?.episodes ?? [])
        guard !merged.isEmpty else {
            throw StreamError.unavailable(failures > 0 ? "The episode list couldn’t load. Try again." : "No episodes are listed yet.")
        }
        let result = ShowDetail(title: title, episodes: merged)
        cache[title.id] = result
        return result
    }

    static func seasonNumber(_ label: String) -> Int? {
        let words = label.split(separator: " ")
        guard words.count >= 2, words[0].lowercased() == "season" else { return nil }
        return Int(words[1].prefix(while: { $0.isNumber }))
    }

    static func parseEpisodes(_ response: String, release: String, season: Int) throws -> [Episode] {
        struct Response: Decodable { let html: String }
        let payload = try JSONDecoder().decode(Response.self, from: Data(response.utf8))
        let page = try SwiftSoup.parseBodyFragment(payload.html, root.absoluteString)
        return try page.select("a.ep-item[data-number][data-id][href]").array().compactMap { row in
            let id = try row.attr("data-id")
            guard id.allSatisfy(\.isNumber), !id.isEmpty,
                  let number = Double(try row.attr("data-number")), number.isFinite, number > 0,
                  let url = SafeURL.https(try row.absUrl("href"), host: root.host),
                  url.path == "/watch/\(release)",
                  URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "ep" })?.value == id
            else { return nil }
            let name = try row.select(".ep-name").text()
            return Episode(id: id, release: release, season: season, number: number,
                           name: name.isEmpty ? "Episode \(number)" : name)
        }
    }

    static func merge(_ fresh: [Episode], _ saved: [Episode]) -> [Episode] {
        var seen = Set<String>()
        return (fresh + saved).filter { seen.insert($0.id).inserted }.sorted {
            if $0.season != $1.season { return $0.season < $1.season }
            if $0.number != $1.number { return $0.number < $1.number }
            return $0.id < $1.id
        }
    }
}
