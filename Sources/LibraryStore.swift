import Foundation
import SwiftUI

struct ViewerProfile: Identifiable, Codable {
    let id: UUID
    var name: String
    var symbol: String
    static let symbols = ["cat.fill", "hare.fill", "bolt.fill", "moon.stars.fill", "flame.fill", "sparkles"]
}

struct WatchRecord: Codable {
    let title: AnimeTitle
    let episode: Episode
    let position: Double
    let duration: Double
    let completed: Bool
    let updatedAt: Date
}

struct ContinueItem: Identifiable {
    var id: String { title.id }
    let title: AnimeTitle
    let episode: Episode
    let position: Double
    let caughtUp: Bool
}

@MainActor final class LibraryStore: ObservableObject {
    private struct State: Codable {
        var profiles: [ViewerProfile]
        var active: UUID
        var history: [String: [WatchRecord]] = [:]
        var episodes: [String: [Episode]] = [:]
    }
    @Published private var state: State
    @Published private(set) var storageError: String?
    private let file: URL

    init(file: URL? = nil) {
        self.file = file ?? URL.applicationSupportDirectory.appendingPathComponent("StreamAnime/library.json")
        if let data = try? Data(contentsOf: self.file), let restored = try? JSONDecoder().decode(State.self, from: data),
           !restored.profiles.isEmpty {
            state = restored
        } else {
            let profile = ViewerProfile(id: UUID(), name: "Me", symbol: "cat.fill")
            state = State(profiles: [profile], active: profile.id)
        }
    }

    var profiles: [ViewerProfile] { state.profiles }
    var active: ViewerProfile { state.profiles.first { $0.id == state.active } ?? state.profiles[0] }
    var records: [WatchRecord] { state.history[active.id.uuidString] ?? [] }
    func episodes(for title: AnimeTitle) -> [Episode] { state.episodes[title.id] ?? state.episodes[title.slug] ?? [] }
    func watched(_ episode: Episode) -> Bool { records.first { $0.episode.id == episode.id }?.completed ?? false }
    func progress(_ episode: Episode) -> Double {
        guard let row = records.first(where: { $0.episode.id == episode.id }), row.duration > 0 else { return 0 }
        return min(1, max(0, row.position / row.duration))
    }

    func select(_ profile: ViewerProfile) { state.active = profile.id; persist() }
    func add(name: String, symbol: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 32,
              !profiles.contains(where: { $0.name.lowercased() == trimmed.lowercased() }) else { return false }
        state.profiles.append(ViewerProfile(id: UUID(), name: trimmed, symbol: symbol)); persist(); return true
    }

    func remember(_ detail: ShowDetail) {
        state.episodes[detail.title.id] = AnimeCatalog.merge(detail.episodes, episodes(for: detail.title))
        persist()
    }

    func record(profile: UUID, title: AnimeTitle, episode: Episode, position: Double, duration: Double, completed: Bool) {
        guard position.isFinite, duration.isFinite, position > 1 || completed else { return }
        var rows = state.history[profile.uuidString] ?? []
        rows.removeAll { $0.episode.id == episode.id }
        rows.insert(WatchRecord(title: title, episode: episode, position: max(0, position), duration: max(0, duration),
                                completed: completed || (duration > 0 && position / duration >= 0.95), updatedAt: Date()), at: 0)
        state.history[profile.uuidString] = rows
        persist()
    }

    func resume(_ episode: Episode, profile: UUID? = nil) -> Double {
        let rows = state.history[(profile ?? active.id).uuidString] ?? []
        guard let record = rows.first(where: { $0.episode.id == episode.id }), !record.completed else { return 0 }
        return record.position
    }

    var continuing: [ContinueItem] {
        var seen = Set<String>()
        return records.sorted { $0.updatedAt > $1.updatedAt }.compactMap { record in
            guard seen.insert(record.title.id).inserted else { return nil }
            let sequence = episodes(for: record.title)
            if record.completed, let index = sequence.firstIndex(where: { $0.id == record.episode.id }), index + 1 < sequence.count {
                let next = sequence[index + 1]
                return ContinueItem(title: record.title, episode: next, position: resume(next), caughtUp: false)
            }
            return ContinueItem(title: record.title, episode: record.episode,
                                position: record.completed ? 0 : record.position, caughtUp: record.completed)
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: file, options: .atomic)
            storageError = nil
        } catch { storageError = "Your latest progress couldn’t be saved on this device." }
    }
}
