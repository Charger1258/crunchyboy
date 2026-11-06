import XCTest
@testable import StreamAnime

final class MediaRelayTests: XCTestCase {
    func testRewritesVariantsKeysSubtitlesAndSegments() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",URI="captions/en.m3u8"
        #EXT-X-KEY:METHOD=AES-128,URI="../key.bin",IV=0x1234
        #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1920x1080
        video/high.m3u8
        #EXT-X-BYTERANGE:256@0
        https://cdn.example.org/segment.ts?token=sample
        """
        var visited: [URL] = []
        let result = try MediaRelay.rewritePlaylist(playlist, base: URL(string: "https://media.example.org/root/master.m3u8")!) { remote in
            visited.append(remote)
            return URL(string: "http://127.0.0.1:9999/\(visited.count)")!
        }
        XCTAssertEqual(visited.count, 4)
        XCTAssertEqual(visited[0].absoluteString, "https://media.example.org/root/captions/en.m3u8")
        XCTAssertEqual(visited[1].absoluteString, "https://media.example.org/key.bin")
        XCTAssertTrue(result.contains("URI=\"http://127.0.0.1:9999/1\""))
        XCTAssertTrue(result.contains("#EXT-X-BYTERANGE:256@0"))
        XCTAssertFalse(result.contains("token=sample"))
    }

    func testRelayBindsToLoopbackAndStops() async throws {
        let relay = MediaRelay()
        let stream = ResolvedStream(url: URL(string: "https://example.org/master.m3u8")!,
                                    referer: URL(string: "https://example.org/")!, height: 1080, source: "Fixture")
        let address = try await relay.start(stream)
        XCTAssertEqual(address.host, "127.0.0.1")
        XCTAssertNotNil(address.port)
        XCTAssertNotEqual(address.path, "/")
        await relay.stop()
    }
}
