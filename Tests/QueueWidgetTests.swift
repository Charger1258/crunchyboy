import XCTest
@testable import StreamAnime

final class QueueWidgetTests: XCTestCase {
    func testRefreshFindsOnlyUnwatchedEpisodesAfterTheAnchor() throws {
        let release = QueueSnapshot.WatchedShow.Release(slug: "example-42", season: 2)
        let show = QueueSnapshot.WatchedShow(id: "series-1", title: "Example", poster: nil,
            releases: [release], anchorNumber: 12, completedIDs: ["120"], next: nil)
        let old = #"<a class="ep-item" data-id="110" data-number="11" href="/watch/example-42?ep=110"></a>"#
        let watched = #"<a class="ep-item" data-id="120" data-number="12" href="/watch/example-42?ep=120"></a>"#
        let new = #"<a class="ep-item" data-id="130" data-number="13" href="/watch/example-42?ep=130"></a>"#
        func response(_ html: String) throws -> String {
            String(data: try JSONSerialization.data(withJSONObject: ["html": html]), encoding: .utf8)!
        }
        XCTAssertNil(try QueueRefresh.parseEpisodes(response(old + watched), show: show, release: release, anchor: release.slug))
        let next = try QueueRefresh.parseEpisodes(response(old + watched + new), show: show, release: release, anchor: release.slug)
        XCTAssertEqual(next?.id, "130")
        XCTAssertEqual(next?.episode, "S2 · E13")
    }
    func testQueueLinkRoundTripAndRejectsForeignLinks() throws {
        let snapshot = QueueSnapshot.preview
        let link = snapshot.link(for: snapshot.items[0])
        let destination = try XCTUnwrap(QueueSnapshot.destination(link))
        XCTAssertEqual(destination.profile, snapshot.profileID)
        XCTAssertEqual(destination.episode, snapshot.items[0].id)
        XCTAssertNil(QueueSnapshot.destination(URL(string: "https://example.com/queue")!))
        XCTAssertNil(QueueSnapshot.destination(URL(string: "streamanime://queue?profile=invalid")!))
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(QueueSnapshot.self, from: data), snapshot)
    }
}
