import XCTest
@testable import StreamAnime

final class CatalogTests: XCTestCase {
    func testCatalogDeduplicatesAndRejectsForeignLinks() throws {
        let html = """
        <div class="flw-item"><a class="film-poster-ahref" href="/watch/sample-42" title="Sample"></a><img class="film-poster-img" data-src="https://images.example.org/poster.jpg"></div>
        <div class="flw-item"><a class="film-poster-ahref" href="/watch/sample-42" title="Duplicate"></a><img class="film-poster-img"></div>
        <div class="flw-item"><a class="film-poster-ahref" href="https://example.org/watch/other-4" title="Wrong host"></a></div>
        """
        let titles = try AnimeCatalog.parseTitles(html)
        XCTAssertEqual(titles.count, 1)
        XCTAssertEqual(titles[0].slug, "sample-42")
        XCTAssertEqual(titles[0].poster?.host, "images.example.org")
    }

    func testEpisodesVerifyProviderIdentityAndPreserveFractionalNumbers() throws {
        let html = """
        <a class="ep-item" data-id="21" data-number="1.5" href="https://hianime.at/watch/sample-42?ep=21"><span class="ep-name">Between chapters</span></a>
        <a class="ep-item" data-id="22" data-number="2" href="https://hianime.at/watch/different-43?ep=22"><span class="ep-name">Wrong release</span></a>
        <a class="ep-item" data-id="23" data-number="3" href="https://hianime.at/watch/sample-42?ep=999"><span class="ep-name">Wrong episode</span></a>
        """
        let data = try JSONSerialization.data(withJSONObject: ["html": html])
        let episodes = try AnimeCatalog.parseEpisodes(String(decoding: data, as: UTF8.self), release: "sample-42", season: 2)
        XCTAssertEqual(episodes.count, 1)
        XCTAssertEqual(episodes[0].number, 1.5)
        XCTAssertEqual(episodes[0].season, 2)
    }

    func testPartialListsKeepCachedEpisodesAndPreferFreshMetadata() {
        let old = Episode(id: "1", release: "sample-42", season: 1, number: 1, name: "Old")
        let corrected = Episode(id: "1", release: "sample-42", season: 2, number: 3, name: "Corrected")
        let second = Episode(id: "2", release: "other-43", season: 3, number: 1, name: "Another")
        let merged = AnimeCatalog.merge([corrected], [old, second])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].name, "Corrected")
        XCTAssertEqual(merged[1].id, "2")
        XCTAssertEqual(AnimeCatalog.seasonNumber("Season 12 (Part 2)"), 12)
        XCTAssertNil(AnimeCatalog.seasonNumber("Movie-1"))
    }

    func testPlayerConfigurationDecodesWithoutExecutingJavaScript() throws {
        let json = Data(#"{"src":"https://video.example.org/master.m3u8"}"#.utf8)
        let mask = Array("otaku-embed-v1".utf8)
        let encoded = Data(json.enumerated().map { index, byte in byte ^ mask[index % mask.count] }).base64EncodedString()
        let player = try HiAnimeStreamAdapter.decodePlayer("window.__P = \"\(encoded)\";")
        XCTAssertEqual(player.src, "https://video.example.org/master.m3u8")
    }

    func testResolverNetworkErrorsDescribeTheFailureWithoutExposingURLs() {
        XCTAssertTrue(HiAnimeStreamAdapter.networkReason(URLError(.timedOut)).contains("timed out"))
        XCTAssertTrue(HiAnimeStreamAdapter.networkReason(URLError(.cannotFindHost)).contains("could not be found"))
        XCTAssertTrue(HiAnimeStreamAdapter.networkReason(URLError(.cannotConnectToHost)).contains("could not be reached"))
    }

    func testPlaybackURLsRequireHTTPSWithoutCredentials() {
        XCTAssertNil(SafeURL.https("http://example.org/a.m3u8"))
        XCTAssertNil(SafeURL.https("https://user:secret@example.org/a.m3u8"))
        XCTAssertNil(SafeURL.https("https://foreign.example/a", host: "hianime.at"))
        XCTAssertNotNil(SafeURL.https("https://example.org/a.m3u8"))
    }
}
