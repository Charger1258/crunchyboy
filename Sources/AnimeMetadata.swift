import Foundation
import SwiftSoup

/// The same generated, unambiguous title aliases and AniBridge ranges used on TV.
/// No per-show overrides: unknown or ambiguous identities retain provider coordinates.
final class AnimeMetadata: @unchecked Sendable {
    static let shared = AnimeMetadata()
    let aliases: [String: Int]
    let mappings: [String: [[Any]]]
    private init() {
        func read(_ name: String) -> Any? {
            guard let url = Bundle.main.url(forResource: name, withExtension: "plist"),
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? PropertyListSerialization.propertyList(from: data, format: nil)
        }
        aliases = read("anime-title-index") as? [String: Int] ?? [:]
        mappings = read("anibridge-tvdb") as? [String: [[Any]]] ?? [:]
    }
    static func normalize(_ value: String) -> String {
        value.decomposedStringWithCompatibilityMapping.lowercased()
            .unicodeScalars.filter { CharacterSet.letters.union(.decimalDigits).contains($0) }.map(String.init).joined()
    }
    func identity(_ names: [String]) -> Int? {
        let ids = Set(names.compactMap { aliases[Self.normalize($0)] })
        return ids.count == 1 ? ids.first : nil
    }
    func ranges(_ id: Int?) -> [[Any]] { id.flatMap { mappings[String($0)] } ?? [] }
    func series(_ id: Int?) -> Int? {
        let values = Set(ranges(id).compactMap { $0.first as? Int })
        return values.count == 1 ? values.first : nil
    }
    static func coordinate(_ number: Int, ranges: [[Any]]) -> (series: Int, season: Int, number: Int, title: String)? {
        var result: (Int, Int, Int, String)?
        for row in ranges {
            guard row.count >= 5, let series = row[0] as? Int, let season = row[1] as? Int,
                  let first = row[2] as? Int, let last = row[3] as? Int, let start = row[4] as? Int,
                  (first...max(first, last)).contains(number) else { continue }
            let candidate = (series, season, start + number - first, row.count > 5 ? row[5] as? String ?? "" : "")
            if let previous = result, previous.0 != candidate.0 || previous.1 != candidate.1 || previous.2 != candidate.2 { return nil }
            result = candidate
        }
        return result
    }
    static func offset(_ episodes: [Episode], ranges: [[Any]]) -> Int {
        var votes: [Int: Int] = [:]
        for episode in episodes {
            let name = normalize(episode.name)
            guard !name.isEmpty, !name.hasPrefix("episode"), episode.number.rounded() == episode.number else { continue }
            let matches = ranges.filter { row in
                row.count > 5 && (row[2] as? Int) == (row[3] as? Int) && normalize(row[5] as? String ?? "") == name
            }
            if matches.count == 1, let local = matches[0][2] as? Int { votes[local - Int(episode.number), default: 0] += 1 }
        }
        return votes.count == 1 && (votes.first?.value ?? 0) >= 2 ? votes.first!.key : 0
    }
    func mapped(_ episodes: [Episode], id: Int?) -> [Episode] {
        Self.map(episodes, ranges: ranges(id))
    }
    static func map(_ episodes: [Episode], ranges rows: [[Any]]) -> [Episode] {
        let offset = Self.offset(episodes, ranges: rows)
        return episodes.map { episode in
            guard episode.number.rounded() == episode.number,
                  let value = Self.coordinate(Int(episode.number) + offset, ranges: rows) else { return episode }
            return Episode(id: episode.id, release: episode.release, season: value.season, number: Double(value.number),
                           name: value.title.isEmpty ? episode.name : value.title,
                           localNumber: episode.localNumber ?? episode.number, image: episode.image)
        }
    }
}

actor EpisodeArtwork {
    static let shared = EpisodeArtwork()
    private var cache: [Int: [String: URL]] = [:]
    private var coordinates: [Int: [[Any]]] = [:]
    func enrich(_ episodes: [Episode], anime: Int) async -> [Episode] {
        if cache[anime] == nil {
            do {
                let text = try await HTTPClient(timeout: 5).text(URL(string: "https://api.ani.zip/mappings?anilist_id=\(anime)")!, limit: 2_000_000)
                let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
                guard (json?["mappings"] as? [String: Any])?["anilist_id"] as? Int == anime else { return episodes }
                let rows = json?["episodes"] as? [String: [String: Any]] ?? [:]
                let series = (json?["mappings"] as? [String: Any])?["thetvdb_id"] as? Int
                var images: [String: URL] = [:]
                var ranges: [[Any]] = []
                for (key, row) in rows {
                    guard let local = Int(key), let season = row["seasonNumber"] as? Int,
                          let number = row["episodeNumber"] as? Int, season >= 0, number > 0 else { continue }
                    let name = (row["title"] as? [String: String])?["en"] ?? row["title"] as? String ?? ""
                    if let series { ranges.append([series, season, local, local, number, name]) }
                    if let value = row["image"] as? String, let url = SafeURL.https(value) { images["\(season):\(number)"] = url }
                }
                cache[anime] = images
                coordinates[anime] = ranges
            } catch { return episodes }
        }
        let originals = episodes.map { Episode(id: $0.id, release: $0.release, season: $0.season, number: $0.localNumber ?? $0.number,
                                               name: $0.name, localNumber: $0.localNumber, image: $0.image) }
        let mapped = coordinates[anime]?.isEmpty == false ? AnimeMetadata.map(originals, ranges: coordinates[anime]!) : episodes
        return mapped.map { episode in
            var copy = episode
            if episode.number.rounded() == episode.number { copy.image = cache[anime]?["\(episode.season):\(Int(episode.number))"] ?? episode.image }
            return copy
        }
    }
}

actor ReleaseIdentity {
    static let shared = ReleaseIdentity()
    private var cache: [String: Int] = [:]
    private var retryAfter = Date.distantPast
    func resolve(_ names: [String]) async -> Int? {
        let names = names.filter { !$0.isEmpty }
        for name in names { if let id = cache[AnimeMetadata.normalize(name)] { return id } }
        if let id = AnimeMetadata.shared.identity(names) { return id }
        guard Date() >= retryAfter else { return nil }
        let query = "query($title:String!){Page(perPage:12){media(type:ANIME,search:$title){id title{romaji english native}}}}"
        for name in names.prefix(2) {
            do {
                let data = try await HTTPClient(timeout: 5).postJSON(URL(string: "https://graphql.anilist.co")!, body: ["query": query, "variables": ["title": name]])
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let page = (json?["data"] as? [String: Any])?["Page"] as? [String: Any]
                let rows = page?["media"] as? [[String: Any]] ?? []
                let expected = Set(names.map(AnimeMetadata.normalize))
                let ids = Set(rows.compactMap { row -> Int? in
                    let titles = row["title"] as? [String: String] ?? [:]
                    guard titles.values.contains(where: { expected.contains(AnimeMetadata.normalize($0)) }) else { return nil }
                    return row["id"] as? Int
                })
                if ids.count == 1, let id = ids.first {
                    for name in names { cache[AnimeMetadata.normalize(name)] = id }
                    return id
                }
            } catch { retryAfter = Date().addingTimeInterval(60); return nil }
        }
        return nil
    }
}
