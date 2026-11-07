import Foundation

struct QueueSnapshot: Codable, Equatable {
    struct Item: Codable, Identifiable, Equatable {
        let id: String
        let title: String
        let episode: String
        let artwork: URL?
        var release: String? = nil
        var season: Int? = nil
        var number: Double? = nil
    }

    struct WatchedShow: Codable, Equatable, Identifiable {
        struct Release: Codable, Equatable {
            let slug: String
            let season: Int
        }
        let id: String
        let title: String
        let poster: URL?
        let releases: [Release]
        let anchorNumber: Double
        let completedIDs: Set<String>
        let next: Item?
    }

    let profileID: UUID
    let profileName: String
    let items: [Item]
    var watched: [WatchedShow] = []

    static let kind = "StreamAnimeQueue"
    static let scheme = "streamanime"

    static var preview: QueueSnapshot {
        QueueSnapshot(profileID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
                      profileName: "Me", items: [
            Item(id: "preview-1", title: "Your next episode", episode: "S1 · E4", artwork: nil),
            Item(id: "preview-2", title: "Continue your adventure", episode: "S2 · E1", artwork: nil),
            Item(id: "preview-3", title: "A new chapter", episode: "S1 · E12", artwork: nil)
        ])
    }

    func link(for item: Item? = nil) -> URL {
        var url = URLComponents()
        url.scheme = Self.scheme
        url.host = "queue"
        url.queryItems = [URLQueryItem(name: "profile", value: profileID.uuidString)]
        if let item { url.queryItems?.append(URLQueryItem(name: "episode", value: item.id)) }
        return url.url!
    }

    static func destination(_ url: URL) -> (profile: UUID, episode: String?)? {
        guard url.scheme == scheme, url.host == "queue",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = parts.queryItems?.first(where: { $0.name == "profile" })?.value,
              let profile = UUID(uuidString: value) else { return nil }
        return (profile, parts.queryItems?.first(where: { $0.name == "episode" })?.value)
    }
}

enum QueueSnapshotStore {
    // SideStore can suffix app groups during signing. Use the group granted by
    // this bundle's profile so the app and its extension open the same container.
    static var directory: URL? {
        let group = "group.com.streamanime.iphone"
        var groups = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] ?? []
        if let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
           let data = try? Data(contentsOf: url),
           let start = data.range(of: Data("<?xml".utf8)),
           let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
           let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
           let entitlements = plist["Entitlements"] as? [String: Any],
           let granted = entitlements["com.apple.security.application-groups"] as? [String] {
            groups += granted
        }
        let candidates = groups.filter { $0.contains(group) }.sorted { $0.count < $1.count } + [group]
        for candidate in candidates {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: candidate) { return url }
        }
        return nil
    }

    static func read() -> QueueSnapshot? {
        guard let directory, let data = try? Data(contentsOf: directory.appendingPathComponent("queue.json")) else { return nil }
        return try? JSONDecoder().decode(QueueSnapshot.self, from: data)
    }

    static func write(_ snapshot: QueueSnapshot) throws {
        guard let directory else { throw CocoaError(.fileNoSuchFile) }
        try JSONEncoder().encode(snapshot).write(to: directory.appendingPathComponent("queue.json"), options: .atomic)
    }
}

struct QueueRefreshCache: Codable {
    let baseline: QueueSnapshot
    var discoveries: [String: QueueSnapshot.Item] = [:]
    var checked: [String: Date] = [:]

    static func read() -> QueueRefreshCache? {
        guard let directory = QueueSnapshotStore.directory,
              let data = try? Data(contentsOf: directory.appendingPathComponent("queue-refresh.json")) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func write() throws {
        guard let directory = QueueSnapshotStore.directory else { return }
        try JSONEncoder().encode(self).write(to: directory.appendingPathComponent("queue-refresh.json"), options: .atomic)
    }
}
