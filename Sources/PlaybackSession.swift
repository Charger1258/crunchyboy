import AVKit
import AVFoundation
import SwiftUI

struct PlaybackRequest: Identifiable {
    let id = UUID()
    let title: AnimeTitle
    let episode: Episode
    let episodes: [Episode]
    var directURL: URL? = nil
    #if targetEnvironment(simulator)
    var fixtureURL: URL? = nil
    var fixtureSubtitles: [String: String]? = nil
    var fixturePauseAt: Double? = nil
    #endif
}

@MainActor final class PlaybackSession: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var episode: Episode
    @Published private(set) var status: String? = "Opening episode…"
    @Published private(set) var error: String?
    @Published private(set) var sourceLabel = ""
    private var captionGroup: AVMediaSelectionGroup?
    @Published private(set) var captionOptions: [CaptionOption] = []
    @Published private(set) var selectedCaption = "off"
    @Published private(set) var captionText = ""
    @Published private(set) var captionScale = 1.0
    @Published private(set) var captionNotice: String?
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var buffered: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var actualHeight = 0
    @Published private(set) var qualityHeight = UserDefaults.standard.integer(forKey: "videoMaxHeight")
    @Published var subtitleOffset: Double = 0
    private var cues: [SubtitleCue] = []
    private var captionTask: Task<Void, Never>?
    private var captionGeneration = UUID()
    private var sourceConfirmed = false
    private var skipMarkers = PlaybackSkipMarkers()
    private let request: PlaybackRequest
    private let library: LibraryStore
    private let profile: UUID
    private let resolver = StreamResolver()
    private let relay = MediaRelay()
    private var task: Task<Void, Never>?
    private var startupTimeout: Task<Void, Never>?
    private var observation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var endedObserver: NSObjectProtocol?
    private var candidates: [ResolvedStream] = []
    private var candidateIndex = 0
    private var generation = UUID()
    private var resumePosition: Double = 0
    private var lastSave: Double = 0
    private var completed = false
    private var shuttingDown = false
    #if targetEnvironment(simulator)
    private var fixturePaused = false
    #endif

    init(request: PlaybackRequest, library: LibraryStore) {
        self.request = request; self.library = library; profile = library.active.id; episode = request.episode
        player.automaticallyWaitsToMinimizeStalling = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in self?.tick(time.seconds) }
        }
    }

    var nextEpisode: Episode? {
        guard let index = request.episodes.firstIndex(where: { $0.id == episode.id }), index + 1 < request.episodes.count else { return nil }
        return request.episodes[index + 1]
    }

    var availableSkip: (label: String, target: Double)? {
        guard status == nil, error == nil, !completed else { return nil }
        if let target = skipMarkers.intro?.target(at: position, duration: duration) {
            return ("Skip Intro", target)
        }
        if let target = skipMarkers.outro?.target(at: position, duration: duration) {
            return ("Skip Outro", target)
        }
        return nil
    }

    func start() {
        captionScale = library.captionSettings(profile: profile).scale
        pendingSeek = nil
        diagnostic("start")
        shuttingDown = false
        task?.cancel(); startupTimeout?.cancel(); player.pause()
        observation = nil
        if let endedObserver { NotificationCenter.default.removeObserver(endedObserver); self.endedObserver = nil }
        generation = UUID(); let token = generation
        status = "Opening episode…"; error = nil; completed = false
        skipMarkers = PlaybackSkipMarkers()
        #if targetEnvironment(simulator)
        fixturePaused = false
        #endif
        resetCaptions(); sourceConfirmed = false; position = 0; duration = 0; buffered = 0; subtitleOffset = 0
        resumePosition = library.resume(episode, profile: profile); lastSave = 0
        task = Task {
            do {
                #if targetEnvironment(simulator)
                if request.fixtureURL != nil {
                    candidates = [ResolvedStream(url: URL(string: "https://fixture.example/master.m3u8")!, referer: URL(string: "https://fixture.example/")!, height: 360, source: "Local player test", subtitles: [
                        SubtitleTrack(url: URL(string: "https://fixture.example/en.vtt")!, language: "en", label: "English"),
                        SubtitleTrack(url: URL(string: "https://fixture.example/ar.vtt")!, language: "ar", label: "Arabic")],
                        skipMarkers: episode.id == request.episode.id
                            ? PlaybackSkipMarkers(intro: .init(start: 0, end: 3), outro: .init(start: 9, end: 14))
                            : PlaybackSkipMarkers())]
                } else if let direct = request.directURL {
                    candidates = [ResolvedStream(url: direct, referer: direct.deletingLastPathComponent(), height: 0, source: "Direct")]
                } else { candidates = try await resolver.resolve(episode) }
                #else
                if let direct = request.directURL {
                    candidates = [ResolvedStream(url: direct, referer: direct.deletingLastPathComponent(), height: 0, source: "Direct")]
                } else { candidates = try await resolver.resolve(episode) }
                #endif
                guard !Task.isCancelled, token == generation else { return }
                candidateIndex = 0
                await playCandidate(token)
            } catch {
                if !Task.isCancelled, token == generation { status = nil; self.error = error.localizedDescription }
            }
        }
    }

    private func playCandidate(_ token: UUID) async {
        guard !shuttingDown, token == generation, candidateIndex < candidates.count else { return }
        do {
            let local: URL
            #if targetEnvironment(simulator)
            if let fixture = request.fixtureURL { local = fixture }
            else { local = try await relay.start(candidates[candidateIndex]) }
            #else
            local = try await relay.start(candidates[candidateIndex])
            #endif
            let source = candidates[candidateIndex]
            guard token == generation, !Task.isCancelled else { return }
            sourceLabel = source.source
            skipMarkers = source.skipMarkers
            let item = AVPlayerItem(url: local)
            diagnostic("item created; file=\(local.isFileURL)")
            applyQuality(item)
            player.replaceCurrentItem(with: item)
            diagnostic("item installed")
            observation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                Task { @MainActor [weak self] in
                    guard let self, token == self.generation, self.player.currentItem === item else { return }
                    self.diagnostic("item status=\(item.status.rawValue)")
                    if item.status == .readyToPlay {
                        self.configureCaptions(item, token: token)
                        let duration = item.duration.seconds
                        self.duration = duration.isFinite ? max(0, duration) : 0
                        let position = duration.isFinite ? min(self.resumePosition, max(0, duration - 1)) : self.resumePosition
                        if position <= 0 {
                            self.player.play(); self.status = nil
                            return
                        }
                        self.player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                            Task { @MainActor [weak self] in
                                guard let self, finished, token == self.generation, !self.shuttingDown else { return }
                                self.diagnostic("initial seek finished")
                                self.player.play(); self.status = nil
                            }
                        }
                    } else if item.status == .failed { self.retryCandidate(token) }
                }
            }
            diagnostic("observation installed")
            // Signal playback intent while the item prepares; the ready handler applies
            // resume seeking before the loading cover is removed.
            player.play()
            diagnostic("play requested")
            if let endedObserver { NotificationCenter.default.removeObserver(endedObserver) }
            endedObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, token == self.generation else { return }
                    self.completed = true; self.save(); self.library.requestCloudSync?()
                    if UserDefaults.standard.bool(forKey: "autoNextEpisode"), self.nextEpisode != nil { self.playNext() }
                }
            }
            startupTimeout?.cancel()
            startupTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(25))
                guard let self, !Task.isCancelled, token == self.generation,
                      !self.sourceConfirmed,
                      self.position <= self.resumePosition + 0.1 else { return }
                self.retryCandidate(token)
            }
        } catch { if !Task.isCancelled { retryCandidate(token) } }
    }

    private func retryCandidate(_ token: UUID) {
        guard token == generation, !shuttingDown else { return }
        let current = position
        if current.isFinite, current > resumePosition { resumePosition = current; save() }
        generation = UUID(); let nextToken = generation
        observation = nil; startupTimeout?.cancel(); player.pause()
        if candidateIndex < candidates.count {
            let failed = candidates[candidateIndex]
            Task { await SourceHealth.shared.failed(failed) }
        }
        resetCaptions(); sourceConfirmed = false
        skipMarkers = PlaybackSkipMarkers()
        pendingSeek = nil
        candidateIndex += 1
        guard candidateIndex < candidates.count else {
            status = nil; error = "The video couldn’t start on this device. Try again, or choose another episode."; return
        }
        status = "Trying another stream…"
        task?.cancel()
        task = Task { await playCandidate(nextToken) }
    }

    func playNext() {
        guard let next = nextEpisode else { return }
        completed = true; save(); library.requestCloudSync?(); episode = next; start()
    }

    private var pendingSeek: UUID?

    private func tick(_ position: Double) {
        guard position.isFinite, position > 0, !shuttingDown, pendingSeek == nil else { return }
        if !sourceConfirmed, position > resumePosition + 1, candidateIndex < candidates.count {
            sourceConfirmed = true
            let source = candidates[candidateIndex]
            Task { await SourceHealth.shared.succeeded(source) }
        }
        self.position = position
        #if targetEnvironment(simulator)
        if let stop = request.fixturePauseAt, position >= stop, !fixturePaused {
            fixturePaused = true; player.pause()
            diagnostic("visual checkpoint reached at \(position)")
        }
        #endif
        let total = player.currentItem?.duration.seconds ?? 0
        duration = total.isFinite ? max(0, total) : 0
        isPlaying = player.rate > 0
        actualHeight = Int(player.currentItem?.presentationSize.height ?? 0)
        if let range = player.currentItem?.loadedTimeRanges.last?.timeRangeValue {
            let end = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
            buffered = end.isFinite ? max(0, end) : 0
        }
        captionText = SubtitleDocument.visible(cues, at: position - subtitleOffset)
        if position - lastSave >= 5 { save(); lastSave = position }
    }

    private func resetCaptions() {
        captionTask?.cancel(); captionGeneration = UUID()
        captionGroup = nil; captionOptions = []; selectedCaption = "off"; cues = []; captionText = ""; captionNotice = nil
    }

    private func configureCaptions(_ item: AVPlayerItem, token: UUID) {
        let source = candidates[candidateIndex]
        let external = source.subtitles.enumerated().map { index, track in
            CaptionOption(id: "external-" + String(index), label: track.label, language: track.language, external: track)
        }
        captionOptions = external
        let language = library.captionSettings(profile: profile).language
        if let preferred = CaptionLanguage.preferred(external, language: language) { selectCaption(preferred.id, remember: false) }
        Task {
            let group = try? await item.asset.loadMediaSelectionGroup(for: .legible)
            guard token == generation, player.currentItem === item else { return }
            captionGroup = group
            var options = external
            if let group {
                options += group.options.enumerated().map { index, option in
                    CaptionOption(id: "native-" + String(index), label: option.displayName,
                                  language: option.extendedLanguageTag ?? option.locale?.languageCode ?? "und", nativeIndex: index)
                }
            }
            captionOptions = options
            // Discovering embedded tracks must not delay external subtitles, or
            // override a language the viewer selected while discovery was running.
            guard selectedCaption == "off" else {
                if let group { item.select(nil, in: group) }
                return
            }
            let language = library.captionSettings(profile: profile).language
            if let preferred = CaptionLanguage.preferred(options, language: language) { selectCaption(preferred.id, remember: false) }
            else {
                if let group { item.select(nil, in: group) }
                if language != "off" { captionNotice = options.isEmpty ? "This source has no subtitle tracks." : "Your preferred subtitle language is unavailable on this source." }
            }
        }
    }

    func selectCaption(_ id: String, remember: Bool = true) {
        captionTask?.cancel(); captionGeneration = UUID(); let token = captionGeneration
        selectedCaption = id; cues = []; captionText = ""; captionNotice = nil
        if let captionGroup { player.currentItem?.select(nil, in: captionGroup) }
        guard let option = captionOptions.first(where: { $0.id == id }) else {
            if remember { library.setCaptionSettings(profile: profile, language: "off") }
            return
        }
        if remember { library.setCaptionSettings(profile: profile, language: option.language) }
        if let index = option.nativeIndex, let captionGroup, captionGroup.options.indices.contains(index) {
            player.currentItem?.select(captionGroup.options[index], in: captionGroup); return
        }
        guard let track = option.external, candidateIndex < candidates.count else { return }
        let source = candidates[candidateIndex]
        captionNotice = "Loading subtitles..."
        captionTask = Task {
            do {
                let text: String
                #if targetEnvironment(simulator)
                if let fixture = request.fixtureSubtitles?[track.language] { text = fixture }
                else {
                    let headers = source.headers.merging(track.headers) { _, caption in caption }
                    let (data, _) = try await HTTPClient(timeout: 10).bytes(track.url, referer: source.referer, limit: 3_000_000, headers: headers)
                    text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? ""
                }
                #else
                let headers = source.headers.merging(track.headers) { _, caption in caption }
                let (data, _) = try await HTTPClient(timeout: 10).bytes(track.url, referer: source.referer, limit: 3_000_000, headers: headers)
                text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? ""
                #endif
                let parsed = SubtitleDocument.parse(text)
                try Task.checkCancellation()
                guard token == captionGeneration else { return }
                guard !parsed.isEmpty else { throw StreamError.invalidResponse }
                cues = parsed; captionNotice = nil
                captionText = SubtitleDocument.visible(parsed, at: position - subtitleOffset)
            } catch {
                if !Task.isCancelled, token == captionGeneration { captionNotice = "Subtitles could not load. Choose another track or retry." }
            }
        }
    }

    var captionLabel: String { captionOptions.first { $0.id == selectedCaption }?.label ?? "Off" }
    var title: String { request.title.name }
    func setQuality(_ height: Int) {
        qualityHeight = height; UserDefaults.standard.set(height, forKey: "videoMaxHeight")
        if let item = player.currentItem { applyQuality(item) }
    }
    private func applyQuality(_ item: AVPlayerItem) {
        item.preferredMaximumResolution = qualityHeight > 0 ? CGSize(width: Double(qualityHeight) * 16/9, height: Double(qualityHeight)) : .zero
        item.preferredPeakBitRate = 0
    }
    func togglePlay() {
        if player.rate > 0 { pause() }
        else { player.play(); isPlaying = true }
    }
    func pause() { player.pause(); isPlaying = false; save(); library.requestCloudSync?() }
    func setCaptionSize(_ size: String) {
        library.setCaptionSettings(profile: profile, size: size)
        captionScale = library.captionSettings(profile: profile).scale
    }
    func setSubtitleOffset(_ seconds: Double) {
        subtitleOffset = seconds
        captionText = SubtitleDocument.visible(cues, at: position - subtitleOffset)
    }
    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        let total = duration
        let target = max(0, min(seconds, total.isFinite && total > 0 ? total : seconds))
        let seek = UUID()
        pendingSeek = seek
        position = target
        captionText = SubtitleDocument.visible(cues, at: target - subtitleOffset)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.pendingSeek == seek else { return }
                self.pendingSeek = nil
                guard finished else { return }
                self.position = target
                self.captionText = SubtitleDocument.visible(self.cues, at: target - self.subtitleOffset)
            }
        }
    }

    func skip(_ seconds: Double) {
        let time = position
        guard time.isFinite else { return }
        seek(to: time + seconds)
    }

    func skipCurrentSegment() {
        guard let segment = availableSkip else { return }
        seek(to: segment.target)
    }

    private func save() {
        #if targetEnvironment(simulator)
        if request.fixtureURL != nil { return }
        #endif
        guard request.directURL == nil else { return }
        library.record(profile: profile, title: request.title, episode: episode,
                       position: position,
                       duration: duration.isFinite ? duration : 0, completed: completed)
    }

    func close() {
        diagnostic("close")
        save(); library.requestCloudSync?(); shuttingDown = true; generation = UUID()
        task?.cancel(); startupTimeout?.cancel(); captionTask?.cancel(); player.pause(); player.replaceCurrentItem(with: nil)
        observation = nil
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        if let endedObserver { NotificationCenter.default.removeObserver(endedObserver); self.endedObserver = nil }
        Task { await relay.stop() }
    }

    private func diagnostic(_ message: String) {
        #if targetEnvironment(simulator)
        if request.fixtureURL != nil {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("player-diagnostics.log")
            let data = Data(("\(Date().timeIntervalSince1970) \(message)\n").utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data)
            } else { try? data.write(to: url) }
        }
        #endif
    }
}

