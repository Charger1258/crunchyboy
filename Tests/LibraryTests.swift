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
}
