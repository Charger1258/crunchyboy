import CryptoKit
import Foundation
import SwiftUI

struct ViewerProfile: Identifiable, Codable {
    let id: UUID
    var name: String
    var symbol: String
    var avatarImage: Data? = nil
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

struct SavedAnime: Codable {
    let title: AnimeTitle
    let changedAtMs: Int64
    let deleted: Bool
}

struct CaptionSettings: Codable {
    var language: String
    var size: String
    var changedAtMs: Int64
    var scale: Double { size == "large" ? 1.25 : size == "small" ? 0.85 : 1 }
}

@MainActor final class LibraryStore: ObservableObject {
    static let defaultCloudProfile = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private struct State: Codable {
        var profiles: [ViewerProfile]
        var active: UUID
        var history: [String: [WatchRecord]] = [:]
        var episodes: [String: [Episode]] = [:]
        var watchlists: [String: [String: SavedAnime]]? = nil
        var captions: [String: CaptionSettings]? = nil
    }
    @Published private var state: State
    @Published private(set) var storageError: String?
    private let file: URL
    private let accountID: String?
    var requestCloudSync: (() -> Void)?

    init(file: URL? = nil, accountID: String? = nil) {
        self.accountID = accountID
        let directory = URL.applicationSupportDirectory.appendingPathComponent("StreamAnime")
        let accountFile = accountID.map {
            let key = SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined()
            return directory.appendingPathComponent("accounts").appendingPathComponent(key + ".json")
        }
        self.file = file ?? accountFile ?? directory.appendingPathComponent("library.json")
        if let data = try? Data(contentsOf: self.file), var restored = try? JSONDecoder().decode(State.self, from: data),
           !restored.profiles.isEmpty {
            // Build 5 created the default account profile with a device-local UUID.
            if accountID != nil, !restored.profiles.contains(where: { $0.id == Self.defaultCloudProfile }),
               let first = restored.profiles.first, first.name == "Me" {
                let id = Self.defaultCloudProfile
                restored.profiles[0] = ViewerProfile(id: id, name: first.name, symbol: first.symbol, avatarImage: first.avatarImage)
                if restored.active == first.id { restored.active = id }
                let history = restored.history.removeValue(forKey: first.id.uuidString)
                let watchlist = restored.watchlists?.removeValue(forKey: first.id.uuidString)
                let captions = restored.captions?.removeValue(forKey: first.id.uuidString)
                restored.history[id.uuidString] = history
                restored.watchlists?[id.uuidString] = watchlist
                restored.captions?[id.uuidString] = captions
            }
            state = restored
        } else {
            let profile = ViewerProfile(id: accountID == nil ? UUID() : Self.defaultCloudProfile, name: "Me", symbol: "cat.fill")
            state = State(profiles: [profile], active: profile.id)
        }
    }

    var profiles: [ViewerProfile] { state.profiles }
    var active: ViewerProfile { state.profiles.first { $0.id == state.active } ?? state.profiles[0] }
    var records: [WatchRecord] { state.history[active.id.uuidString] ?? [] }
    func records(profile: UUID) -> [WatchRecord] { state.history[profile.uuidString] ?? [] }

    func savedCaptionSettings(profile: UUID) -> CaptionSettings? { state.captions?[profile.uuidString] }
    func captionSettings(profile: UUID) -> CaptionSettings {
        if let saved = savedCaptionSettings(profile: profile) { return saved }
        if accountID != nil { return CaptionSettings(language: "en", size: "normal", changedAtMs: 0) }
        let defaults = UserDefaults.standard
        let scale = defaults.double(forKey: "captionScale")
        return CaptionSettings(language: defaults.string(forKey: "subtitleLanguage") ?? "en",
                               size: scale >= 1.2 ? "large" : scale > 0 && scale < 1 ? "small" : "normal", changedAtMs: 0)
    }
    func setCaptionSettings(profile: UUID, language: String? = nil, size: String? = nil) {
        var settings = captionSettings(profile: profile)
        if let language {
            let code = CaptionLanguage.normalize(language)
            guard code.range(of: "^(off|[a-z]{2,3})$", options: .regularExpression) != nil else { return }
            settings.language = code
        }
        if let size { settings.size = size }
        settings.changedAtMs = max(settings.changedAtMs + 1, Int64(Date().timeIntervalSince1970 * 1000))
        mergeCaptionSettings(settings, profile: profile)
        requestCloudSync?()
    }
    func mergeCaptionSettings(_ settings: CaptionSettings, profile: UUID) {
        var all = state.captions ?? [:]
        guard (all[profile.uuidString]?.changedAtMs ?? -1) < settings.changedAtMs else { return }
        all[profile.uuidString] = settings
        state.captions = all
        persist()
    }

    func savedEntries(profile: UUID) -> [String: SavedAnime] { state.watchlists?[profile.uuidString] ?? [:] }
    var watchlist: [AnimeTitle] {
        savedEntries(profile: active.id).values.filter { !$0.deleted }
            .sorted { $0.changedAtMs > $1.changedAtMs }.map(\.title)
    }
    func isSaved(_ title: AnimeTitle) -> Bool { savedEntries(profile: active.id)[title.slug]?.deleted == false }
    func toggleSaved(_ title: AnimeTitle) {
        let now = max((savedEntries(profile: active.id)[title.slug]?.changedAtMs ?? 0) + 1,
                      Int64(Date().timeIntervalSince1970 * 1000))
        mergeSaved(SavedAnime(title: title, changedAtMs: now, deleted: isSaved(title)), profile: active.id)
        requestCloudSync?()
    }
    func mergeSaved(_ entry: SavedAnime, profile: UUID) {
        var entries = savedEntries(profile: profile)
        guard (entries[entry.title.slug]?.changedAtMs ?? -1) < entry.changedAtMs else { return }
        entries[entry.title.slug] = entry
        var all = state.watchlists ?? [:]
        all[profile.uuidString] = entries
        state.watchlists = all
        persist()
    }

    func mergeCloudProfile(_ profile: ViewerProfile) {
        if let index = state.profiles.firstIndex(where: { $0.id == profile.id }) {
            guard state.profiles[index].name != profile.name || state.profiles[index].symbol != profile.symbol
                    || state.profiles[index].avatarImage != profile.avatarImage else { return }
            state.profiles[index] = profile
        } else {
            state.profiles.append(profile)
        }
        persist()
    }

    func mergeCloudRecord(_ record: WatchRecord, profile: UUID, deleted: Bool) {
        var rows = records(profile: profile)
        if let local = rows.first(where: { $0.episode.id == record.episode.id }),
           local.updatedAt >= record.updatedAt, !deleted { return }
        rows.removeAll { $0.episode.id == record.episode.id }
        if !deleted { rows.append(record) }
        state.history[profile.uuidString] = rows
        persist()
    }

    func importGuestProfiles() {
        let guest = LibraryStore()
        for profile in guest.profiles where !state.profiles.contains(where: { $0.id == profile.id }) {
            state.profiles.append(profile)
            state.history[profile.id.uuidString] = guest.records(profile: profile.id)
            for entry in guest.savedEntries(profile: profile.id).values { mergeSaved(entry, profile: profile.id) }
            if let settings = guest.savedCaptionSettings(profile: profile.id) { mergeCaptionSettings(settings, profile: profile.id) }
        }
        for (id, episodes) in guest.state.episodes {
            state.episodes[id] = AnimeCatalog.merge(episodes, state.episodes[id] ?? [])
        }
        persist()
    }
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
            let current = sequence.first { $0.id == record.episode.id } ?? record.episode
            return ContinueItem(title: record.title, episode: current,
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
