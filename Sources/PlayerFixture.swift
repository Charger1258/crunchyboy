#if targetEnvironment(simulator)
import Foundation

/// Deterministic, silent visual UI harness; cloud Macs may lack a working audio device.
/// Never maps or substitutes any catalog entry. Audio requires a physical-device check.
enum PlayerFixture {
    static var request: PlaybackRequest {
        let title = AnimeTitle(slug: "local-player-test", name: "Player test pattern", poster: nil)
        let first = Episode(id: "fixture-1", release: title.slug, season: 1, number: 1, name: "Landscape and subtitle test")
        let next = Episode(id: "fixture-2", release: title.slug, season: 1, number: 2, name: "Subtitle preference test")
        var request = PlaybackRequest(title: title, episode: first, episodes: [first, next])
        request.fixtureURL = Bundle.main.url(forResource: "player-test", withExtension: "mp4")!
        request.fixtureSubtitles = ["en": "WEBVTT\n\n00:00:00.000 --> 00:00:08.000\nEnglish subtitles are visible.\n\n00:00:08.000 --> 00:00:20.000\nSubtitles remain synchronized after seeking.\n",
                                    "ar": "WEBVTT\n\n00:00:00.000 --> 00:00:20.000\nالترجمة العربية تعمل\n"]
        return request
    }
}
#endif
