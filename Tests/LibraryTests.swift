import XCTest
@testable import StreamAnime

final class LibraryTests: XCTestCase {
    @MainActor func testProfileIsolationPersistenceAndNextEpisode() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("library.json")
        let store = LibraryStore(file: file)
        let original = store.active
        let show = AnimeTitle(slug: "sample-42", name: "Sample", poster: nil)
        let first = Episode(id: "1", release: show.slug, season: 1, number: 1, name: "First")
        let second = Episode(id: "2", release: show.slug, season: 1, number: 2, name: "Second")
        store.remember(ShowDetail(title: show, episodes: [first, second]))
        store.record(profile: original.id, title: show, episode: first, position: 150, duration: 1200, completed: false)
        XCTAssertEqual(store.continuing.first?.episode.id, first.id)
        XCTAssertEqual(store.resume(first), 150)
        var enriched = first
        enriched.image = URL(string: "https://images.example.org/episode.jpg")!
        store.remember(ShowDetail(title: show, episodes: [enriched]))
        XCTAssertEqual(store.continuing.first?.episode.image, enriched.image)
        XCTAssertEqual(store.continuing.first?.position, 150)
        store.record(profile: original.id, title: show, episode: first, position: 1200, duration: 1200, completed: true)
        XCTAssertEqual(store.continuing.first?.episode.id, second.id)
        store.record(profile: original.id, title: show, episode: second, position: 1200, duration: 1200, completed: true)
        XCTAssertTrue(store.continuing.first!.caughtUp)
        XCTAssertEqual(store.continuing.first?.episode.id, second.id)
        XCTAssertTrue(store.add(name: "Guest", symbol: "hare.fill"))
        store.select(store.profiles.last!)
        XCTAssertTrue(store.continuing.isEmpty)
        let restored = LibraryStore(file: file)
        restored.select(original)
        XCTAssertTrue(restored.continuing.first!.caughtUp)
        let third = Episode(id: "3", release: show.slug, season: 2, number: 1, name: "New season")
        restored.remember(ShowDetail(title: show, episodes: [third]))
        XCTAssertEqual(restored.episodes(for: show).count, 3)
        XCTAssertEqual(restored.continuing.first?.episode.id, third.id)
        XCTAssertFalse(restored.continuing.first!.caughtUp)
    }
    @MainActor func testSyncMergesNewestProgressAndKeepsProfilesPrivate() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("library.json")
        let store = LibraryStore(file: file, accountID: "synthetic-account")
        let first = store.active.id
        let show = AnimeTitle(slug: "sample-42", name: "Sample", poster: nil)
        let episode = Episode(id: "100", release: show.slug, season: 2, number: 13, name: "First", localNumber: 1)
        func record(_ position: Double, _ time: Double) -> WatchRecord {
            WatchRecord(title: show, episode: episode, position: position, duration: 1200, completed: false,
                        updatedAt: Date(timeIntervalSince1970: time))
        }
        store.mergeCloudRecord(record(200, 200), profile: first, deleted: false)
        store.mergeCloudRecord(record(900, 100), profile: first, deleted: false)
        XCTAssertEqual(store.resume(episode), 200)
        store.mergeCloudRecord(record(30, 300), profile: first, deleted: false)
        XCTAssertEqual(store.resume(episode), 30, "A newer seek backwards must win")
        XCTAssertTrue(store.add(name: "Second", symbol: "hare.fill"))
        store.select(store.profiles.last!)
        XCTAssertTrue(store.continuing.isEmpty)
        XCTAssertTrue(store.watchlist.isEmpty)
        store.select(store.profiles.first!)
        let restored = LibraryStore(file: file, accountID: "synthetic-account")
        XCTAssertEqual(restored.resume(episode), 30)
        XCTAssertEqual(restored.records.first?.episode.localNumber, 1)
    }

    @MainActor func testWatchlistTombstonesAndCaptionPreferencesPersistPerProfile() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("library.json")
        let store = LibraryStore(file: file, accountID: "synthetic-account")
        let profile = store.active.id
        let show = AnimeTitle(slug: "sample-42", name: "Sample", poster: nil)
        store.mergeSaved(SavedAnime(title: show, changedAtMs: 200, deleted: true), profile: profile)
        store.mergeSaved(SavedAnime(title: show, changedAtMs: 100, deleted: false), profile: profile)
        XCTAssertFalse(store.isSaved(show), "An offline old save cannot restore a removed title")
        store.toggleSaved(show)
        XCTAssertTrue(store.isSaved(show))
        store.setCaptionSettings(profile: profile, language: "ar", size: "large")
        store.setCaptionSettings(profile: profile, size: "invalid")
        XCTAssertEqual(store.captionSettings(profile: profile).size, "large")
        store.mergeCaptionSettings(CaptionSettings(language: "en", size: "small", changedAtMs: 1), profile: profile)
        XCTAssertTrue(store.add(name: "Second", symbol: "hare.fill"))
        store.select(store.profiles.last!)
        XCTAssertEqual(store.captionSettings(profile: store.active.id).language, "en")
        XCTAssertTrue(store.watchlist.isEmpty)
        let restored = LibraryStore(file: file, accountID: "synthetic-account")
        XCTAssertEqual(restored.captionSettings(profile: profile).language, "ar")
        XCTAssertEqual(restored.captionSettings(profile: profile).size, "large")
        XCTAssertEqual(restored.savedEntries(profile: profile).count, 1)
    }

}
