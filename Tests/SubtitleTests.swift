import XCTest
@testable import StreamAnime

final class SubtitleTests: XCTestCase {
    func testWebVTTSettingsMarkupOverlapsAndSeekGaps() {
        let text = "\u{FEFF}WEBVTT\r\n\r\nNOTE not a cue\r\nignore me\r\n\r\nfirst\r\n00:01.000 --> 00:05.000 align:start\r\n<v Narrator>Hello &amp; <i>welcome</i>.</v>\r\n\r\n00:02.000 --> 00:03.000\r\nSecond line\r\n"
        let cues = SubtitleDocument.parse(text)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(SubtitleDocument.visible(cues, at: 0), "")
        XCTAssertEqual(SubtitleDocument.visible(cues, at: 2.5), "Hello & welcome.\nSecond line")
        XCTAssertEqual(SubtitleDocument.visible(cues, at: 3), "Hello & welcome.")
        XCTAssertEqual(SubtitleDocument.visible(cues, at: 5), "")
    }
    func testSRTAndMalformedTimestamps() {
        let cues = SubtitleDocument.parse("1\n01:02:03,500 --> 01:02:05,000\nA line\nAnother line\n\n2\nnot a timestamp --> 00:00:30\nBad\n")
        XCTAssertEqual(cues.count, 1); XCTAssertEqual(cues.first?.start, 3723.5)
        XCTAssertEqual(cues.first?.text, "A line\nAnother line")
        XCTAssertNil(SubtitleDocument.timestamp("00:99:00"))
        XCTAssertNil(SubtitleDocument.timestamp("nan:01"))
    }
    func testLanguagePreferenceDoesNotFallBackToAnotherLanguage() {
        let options = [CaptionOption(id: "ar", label: "Arabic", language: "ar"), CaptionOption(id: "en", label: "English", language: "eng")]
        XCTAssertEqual(CaptionLanguage.preferred(options, language: "en-US")?.id, "en")
        XCTAssertNil(CaptionLanguage.preferred(options, language: "off"))
        XCTAssertNil(CaptionLanguage.preferred(Array(options.prefix(1)), language: "en"))
    }
    func testMixedTypeGatewaySubtitleRecordsArePreserved() throws {
        let payload = #"{"anilistId":42,"episode":1,"audio":"sub","streams":[{"type":"hls","url":"https://media.example/master.m3u8","subtitles":[{"url":"https://captions.example/en.vtt","label":"English","srclang":"en","default":true,"source":"provider","headers":{"Referer":"https://player.example/","Cookie":"do-not-forward"}}]}]}"#
        let streams = try AniKotoAdapter.decode(payload, anime: 42, episode: 1, gateway: URL(string: "https://gateway.example")!)
        XCTAssertEqual(streams.first?.subtitles.count, 1)
        XCTAssertEqual(streams.first?.subtitles.first?.headers["Referer"], "https://player.example/")
        XCTAssertNil(streams.first?.subtitles.first?.headers["Cookie"])
    }
}
