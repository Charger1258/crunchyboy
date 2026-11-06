import Foundation

struct AnimeTitle: Identifiable, Codable, Hashable {
    var id: String { slug }
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
