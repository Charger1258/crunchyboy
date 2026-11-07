import Combine
import CryptoKit
import FirebaseAuth
import FirebaseFirestore
import Foundation

@MainActor final class LibrarySync: ObservableObject {
    @Published private(set) var status = "Ready to sync"
    private var syncing = false
    private var progressCache: [String: [String: [String: Any]]] = [:]
    private var progressCursor: [String: Timestamp] = [:]
    private var episodeKeys: [String: String] = [:]

    func run(library: LibraryStore, userID: String) async {
        while !Task.isCancelled {
            await sync(library: library, userID: userID)
            try? await Task.sleep(for: .seconds(30))
        }
    }

    func sync(library: LibraryStore, userID: String) async {
        guard !syncing, Auth.auth().currentUser?.uid == userID else { return }
        syncing = true
        defer { syncing = false }
        status = "Syncing…"
        do {
            let db = Firestore.firestore()
            let profiles = db.collection("users").document(userID).collection("profiles")
            let remoteProfiles = try await profiles.getDocuments(source: .server)
            try checkAccount(userID)
            let known = Set(remoteProfiles.documents.map(\.documentID))
            let deleted = Set(remoteProfiles.documents.filter { $0.data()["deleted"] as? Bool == true }.map(\.documentID))
            for document in remoteProfiles.documents where !deleted.contains(document.documentID) {
                let fields = document.data()
                guard let id = UUID(uuidString: document.documentID), let name = fields["name"] as? String else { continue }
                let index = Int((fields["avatarKey"] as? String ?? "").dropFirst(7)) ?? 1
                let symbols = ViewerProfile.symbols
                let symbol = symbols.indices.contains(index) ? symbols[index] : symbols[0]
                let encoded = fields["avatarImage"] as? String ?? ""
                let image = !encoded.isEmpty && encoded.utf8.count <= 65536 ? Data(base64Encoded: encoded) : nil
                library.mergeCloudProfile(ViewerProfile(id: id, name: name, symbol: symbol, avatarImage: image))
            }
            for profile in library.profiles {
                try checkAccount(userID)
                let id = profile.id.uuidString.lowercased()
                guard !deleted.contains(id) else { continue }
                let document = profiles.document(id)
                if !known.contains(id) {
                    let index = ViewerProfile.symbols.firstIndex(of: profile.symbol) ?? 0
                    let fields: [String: Any] = ["schemaVersion": 1, "name": profile.name,
                        "avatarKey": "avatar-\(index)", "avatarImage": profile.avatarImage?.base64EncodedString() ?? "", "deleted": false]
                    try await commit(fields, to: document, watchedAt: nil)
                }
                let collection = document.collection("progress")
                var query: Query = collection.order(by: "updatedAt")
                if let cursor = progressCursor[id] { query = query.whereField("updatedAt", isGreaterThanOrEqualTo: cursor) }
                var remote = progressCache[id] ?? [:]
                var pageQuery = query.limit(to: 250)
                var downloaded = 0
                while true {
                    let snapshot = try await pageQuery.getDocuments(source: .server)
                    try checkAccount(userID)
                    var updates: [(record: WatchRecord, deleted: Bool)] = []
                    var cursor = progressCursor[id]
                    for row in snapshot.documents {
                        let fields = row.data()
                        remote[row.documentID] = fields
                        if let stamp = fields["updatedAt"] as? Timestamp { cursor = stamp }
                        if let record = decode(fields) {
                            updates.append((record: record, deleted: fields["deleted"] as? Bool == true))
                        }
                    }
                    library.mergeCloudRecords(updates, profile: profile.id)
                    progressCache[id] = remote
                    progressCursor[id] = cursor
                    downloaded += snapshot.documents.count
                    status = "Downloaded \(downloaded) history entries for \(profile.name)"
                    guard snapshot.documents.count == 250, let last = snapshot.documents.last else { break }
                    pageQuery = query.start(afterDocument: last).limit(to: 250)
                    await Task.yield()
                }
                for (index, record) in library.records(profile: profile.id).enumerated() {
                    if index.isMultiple(of: 100) { await Task.yield() }
                    try checkAccount(userID)
                    let key = episodeKey(record.episode.id)
                    let watchedAt = Int64(record.updatedAt.timeIntervalSince1970 * 1000)
                    if let previous = remote[key], previous["deleted"] as? Bool == true ||
                        ((previous["watchedAtMs"] as? NSNumber)?.int64Value ?? 0) >= watchedAt { continue }
                    guard let fields = encode(record) else { continue }
                    try await commit(fields, to: collection.document(key), watchedAt: watchedAt)
                }
                try await syncWatchlist(library, profile: profile.id, document: document, userID: userID)
                try await syncCaptions(library, profile: profile.id, document: document, userID: userID)
            }
            status = "Up to date"
        } catch is CancellationError {
            return
        } catch {
            status = "Sync unavailable. Your progress is saved on this iPhone."
        }
    }

    private func checkAccount(_ userID: String) throws {
        try Task.checkCancellation()
        guard Auth.auth().currentUser?.uid == userID else { throw CancellationError() }
    }

    private func syncWatchlist(_ library: LibraryStore, profile: UUID, document: DocumentReference, userID: String) async throws {
        let collection = document.collection("watchlist")
        let cacheKey = collection.path
        var query: Query = collection.order(by: "updatedAt")
        if let cursor = progressCursor[cacheKey] { query = query.whereField("updatedAt", isGreaterThanOrEqualTo: cursor) }
        let snapshot = try await query.getDocuments(source: .server)
        try checkAccount(userID)
        var remote = progressCache[cacheKey] ?? [:]
        for row in snapshot.documents {
            let fields = row.data()
            remote[row.documentID] = fields
            if let stamp = fields["updatedAt"] as? Timestamp { progressCursor[cacheKey] = stamp }
            guard let name = fields["title"] as? String, let changed = fields["changedAtMs"] as? NSNumber else { continue }
            let title = AnimeTitle(slug: row.documentID, name: name, poster: SafeURL.https(fields["posterUrl"] as? String ?? ""))
            library.mergeSaved(SavedAnime(title: title, changedAtMs: changed.int64Value,
                                          deleted: fields["deleted"] as? Bool == true), profile: profile)
        }
        progressCache[cacheKey] = remote
        for (slug, entry) in library.savedEntries(profile: profile) {
            try checkAccount(userID)
            guard slug.utf8.count <= 256, slug.range(of: "^[a-z0-9-]+-[0-9]+$", options: .regularExpression) != nil,
                  ((remote[slug]?["changedAtMs"] as? NSNumber)?.int64Value ?? -1) < entry.changedAtMs else { continue }
            let fields: [String: Any] = ["schemaVersion": 1, "title": String(entry.title.name.prefix(512)),
                "posterUrl": String((entry.title.poster?.absoluteString ?? "").prefix(2048)),
                "deleted": entry.deleted, "changedAtMs": entry.changedAtMs]
            try await commit(fields, to: collection.document(slug), watchedAt: entry.changedAtMs, timestampField: "changedAtMs")
        }
    }

    private func syncCaptions(_ library: LibraryStore, profile: UUID, document: DocumentReference, userID: String) async throws {
        let reference = document.collection("settings").document("playback")
        let snapshot = try await reference.getDocument(source: .server)
        try checkAccount(userID)
        let remoteTime = (snapshot.get("changedAtMs") as? NSNumber)?.int64Value ?? -1
        if let language = snapshot.get("subtitleLanguage") as? String,
           let size = snapshot.get("subtitleSize") as? String {
            library.mergeCaptionSettings(CaptionSettings(language: language, size: size, changedAtMs: remoteTime), profile: profile)
        }
        guard let local = library.savedCaptionSettings(profile: profile), local.changedAtMs > remoteTime else { return }
        try await commit(["schemaVersion": 1, "subtitleLanguage": local.language, "subtitleSize": local.size,
                          "changedAtMs": local.changedAtMs], to: reference, watchedAt: local.changedAtMs, timestampField: "changedAtMs")
    }

    private func commit(_ fields: [String: Any], to document: DocumentReference, watchedAt: Int64?, timestampField: String = "watchedAtMs") async throws {
        _ = try await document.firestore.runTransaction { transaction, pointer in
            do {
                let previous = try transaction.getDocument(document)
                if previous.exists {
                    guard let watchedAt,
                          (timestampField != "watchedAtMs" || previous.get("deleted") as? Bool != true),
                          ((previous.get(timestampField) as? NSNumber)?.int64Value ?? 0) < watchedAt else { return nil }
                }
                var data = fields
                data["revision"] = ((previous.get("revision") as? NSNumber)?.intValue ?? 0) + 1
                data["updatedAt"] = FieldValue.serverTimestamp()
                transaction.setData(data, forDocument: document)
            } catch { pointer?.pointee = error as NSError }
            return nil
        }
    }

    private func episodeKey(_ id: String) -> String {
        if let cached = episodeKeys[id] { return cached }
        let key = SHA256.hash(data: Data("hianime\n\(id)".utf8)).map { String(format: "%02x", $0) }.joined()
        episodeKeys[id] = key
        return key
    }

    private func encode(_ record: WatchRecord) -> [String: Any]? {
        let episode = record.episode
        guard episode.id.range(of: "^[0-9]{1,256}$", options: .regularExpression) != nil,
              !episode.release.isEmpty, episode.number.isFinite, (0...1_000_000).contains(episode.number),
              (0...10000).contains(episode.season) else { return nil }
        let duration = Int64(min(604800, max(0, record.duration)) * 1000)
        let position = Int64(min(duration > 0 ? Double(duration) / 1000 : 604800, max(0, record.position)) * 1000)
        return ["schemaVersion": 1, "provider": "hianime", "episodeId": episode.id,
                "releaseId": episode.release, "seriesId": "hianime:" + record.title.slug,
                "season": episode.season, "episodeNumber": episode.number, "localEpisodeNumber": episode.localNumber ?? episode.number, "title": String(record.title.name.prefix(512)),
                "episodeTitle": String(episode.name.prefix(512)), "posterUrl": String((record.title.poster?.absoluteString ?? "").prefix(2048)),
                "positionMs": position, "durationMs": duration, "completed": record.completed,
                "watchedAtMs": Int64(record.updatedAt.timeIntervalSince1970 * 1000),
                "sessionId": "iphone-library", "deviceId": "iphone", "deleted": false]
    }

    private func decode(_ fields: [String: Any]) -> WatchRecord? {
        guard fields["provider"] as? String == "hianime", let id = fields["episodeId"] as? String,
              let release = fields["releaseId"] as? String, let title = fields["title"] as? String,
              let name = fields["episodeTitle"] as? String, let series = fields["seriesId"] as? String,
              let season = fields["season"] as? NSNumber, let number = fields["episodeNumber"] as? NSNumber,
              let position = fields["positionMs"] as? NSNumber, let duration = fields["durationMs"] as? NSNumber,
              let watched = fields["watchedAtMs"] as? NSNumber else { return nil }
        let slug = series.hasPrefix("hianime:") ? String(series.dropFirst(8)) : release
        return WatchRecord(title: AnimeTitle(slug: slug, name: title, poster: SafeURL.https(fields["posterUrl"] as? String ?? "")),
                           episode: Episode(id: id, release: release, season: season.intValue, number: number.doubleValue, name: name, localNumber: (fields["localEpisodeNumber"] as? NSNumber)?.doubleValue),
                           position: position.doubleValue / 1000, duration: duration.doubleValue / 1000,
                           completed: fields["completed"] as? Bool == true,
                           updatedAt: Date(timeIntervalSince1970: watched.doubleValue / 1000))
    }
}
