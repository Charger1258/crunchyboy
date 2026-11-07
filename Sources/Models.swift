import Foundation

struct AnimeTitle: Identifiable, Codable, Hashable {
    var id: String {
        if let series = AnimeMetadata.shared.series(AnimeMetadata.shared.identity([name])) { return "tvdb:\(series)" }
        return slug
    }
    let slug: String
    let name: String
    let poster: URL?
}

struct Episode: Identifiable, Codable, Hashable {
    let id: String
    let release: String
    let season: Int
    let number: Double
    let name: String
    var localNumber: Double? = nil
    var image: URL? = nil
    var label: String { "S\(season) · E\(number.formatted(.number.precision(.fractionLength(0...1))))" }
}

struct ShowDetail {
    let title: AnimeTitle
    let episodes: [Episode]
    var seasons: [Int] { Array(Set(episodes.map(\.season))).sorted() }
}

struct ResolvedStream: Identifiable {
    var id: URL { url }
    let url: URL
    let referer: URL
    let height: Int
    let source: String
    var headers: [String: String] = [:]
    var subtitles: [SubtitleTrack] = []
    var skipMarkers = PlaybackSkipMarkers()
    var reliabilityKey: String { source + "|" + (url.host ?? "") }
}

struct PlaybackSkipMarkers: Decodable {
    struct Segment: Decodable {
        let start: Double
        let end: Double

        func target(at position: Double, duration: Double) -> Double? {
            guard start.isFinite, end.isFinite, start >= 0, end > start,
                  duration.isFinite, duration > 0, end <= duration + 1 else { return nil }
            let target = min(end, duration)
            return position >= start && position < target ? target : nil
        }
    }

    let intro: Segment?
    let outro: Segment?

    init(intro: Segment? = nil, outro: Segment? = nil) {
        self.intro = intro
        self.outro = outro
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        intro = try? container.decode(Segment.self, forKey: .intro)
        outro = try? container.decode(Segment.self, forKey: .outro)
    }

    private enum CodingKeys: String, CodingKey { case intro, outro }
}

struct SubtitleTrack: Codable, Hashable {
    let url: URL
    let language: String
    let label: String
    var headers: [String: String] = [:]
}

enum StreamError: LocalizedError {
    case invalidResponse, unavailable(String), insecureURL, noStream
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The source returned an unexpected response. Please try again."
        case .unavailable(let message): return message
        case .insecureURL: return "This source returned an unsupported address."
        case .noStream: return "No playable subtitled stream was found for this episode."
        }
    }
}

enum SafeURL {
    static func https(_ string: String, host: String? = nil) -> URL? {
        guard let url = URL(string: string), url.scheme == "https", url.user == nil,
              url.password == nil, url.port == nil, let domain = url.host,
              host == nil || domain == host else { return nil }
        return url
    }
}
