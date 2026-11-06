import XCTest
@testable import StreamAnime

final class ParityTests: XCTestCase {
    func testStructuredCoordinatesPreserveProviderNumbersAndRejectConflicts() {
        let rows: [[Any]] = [[123, 2, 1, 4, 8]]
        let episode = Episode(id: "provider-1", release: "release-42", season: 1, number: 2, name: "Arrival")
        let result = AnimeMetadata.map([episode], ranges: rows)[0]
        XCTAssertEqual(result.season, 2); XCTAssertEqual(result.number, 9)
        XCTAssertEqual(result.localNumber, 2); XCTAssertEqual(result.id, episode.id)
        XCTAssertNil(AnimeMetadata.coordinate(2, ranges: rows + [[123, 3, 2, 2, 1]]))
        XCTAssertEqual(AnimeMetadata.shared.mappings.count, 9196)
        XCTAssertGreaterThan(AnimeMetadata.shared.aliases.count, 100000)
    }
    func testPartOffsetNeedsAgreementFromMultipleEpisodeTitles() {
        let rows: [[Any]] = [[123, 2, 8, 8, 8, "Arrival"], [123, 2, 9, 9, 9, "Departure"]]
        let first = Episode(id: "a", release: "release-42", season: 1, number: 1, name: "Arrival")
        let second = Episode(id: "b", release: "release-42", season: 1, number: 2, name: "Departure")
        XCTAssertEqual(AnimeMetadata.offset([first], ranges: rows), 0)
        XCTAssertEqual(AnimeMetadata.offset([first, second], ranges: rows), 7)
    }
    func testGatewayRejectsWrongEpisodeAndUnsafeHeaders() throws {
        let root = URL(string: "https://gateway.example")!
        let payload = #"{"anilistId":42,"episode":3,"audio":"sub","streams":[{"type":"hls","url":"https://media.example/master.m3u8","headers":{"Referer":"https://source.example/","Cookie":"private","Origin":"http://unsafe.example"},"subtitles":[{"url":"https://media.example/en.vtt","srclang":"en","label":"English"}]}]}"#
        XCTAssertThrowsError(try AniKotoAdapter.decode(payload, anime: 42, episode: 4, gateway: root))
        let streams = try AniKotoAdapter.decode(payload, anime: 42, episode: 3, gateway: root)
        XCTAssertEqual(streams.count, 1); XCTAssertNil(streams[0].headers["Cookie"])
        XCTAssertNil(streams[0].headers["Origin"]); XCTAssertEqual(streams[0].subtitles.first?.language, "en")
    }
    func testSubtitleConversionDoesNotChangeDialoguePunctuation() {
        let vtt = MediaRelay.webVTT("1\r\n00:00:01,000 --> 00:00:03,000\r\nHello, world!\r\n")
        XCTAssertTrue(vtt.hasPrefix("WEBVTT")); XCTAssertTrue(vtt.contains("00:00:01.000 --> 00:00:03.000"))
        XCTAssertTrue(vtt.contains("Hello, world!"))
    }
    func testFailedSourceRanksAfterHealthySourceAndRecovers() async throws {
        let suite = "source-health-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let health = SourceHealth(defaults: defaults)
        let high = ResolvedStream(url: URL(string: "https://one.example/a.m3u8")!, referer: URL(string: "https://one.example")!, height: 1080, source: "A")
        let low = ResolvedStream(url: URL(string: "https://two.example/b.m3u8")!, referer: URL(string: "https://two.example")!, height: 720, source: "B")
        await health.failed(high)
        var ranked = await health.ranked([high, low]); XCTAssertEqual(ranked.first?.source, "B")
        await health.succeeded(high)
        ranked = await health.ranked([low, high]); XCTAssertEqual(ranked.first?.source, "A")
    }
}
