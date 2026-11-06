import AVKit
import AVFoundation
import SwiftUI

struct PlaybackRequest: Identifiable {
    let id = UUID()
    let title: AnimeTitle
    let episode: Episode
    let episodes: [Episode]
    var directURL: URL? = nil
}

@MainActor final class PlaybackSession: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var episode: Episode
    @Published private(set) var status: String? = "Opening episode…"
    @Published private(set) var error: String?
    @Published private(set) var sourceLabel = ""
    private var captionGroup: AVMediaSelectionGroup?
    private var captionsReady = false
    private var lastCaptionSelection: String?
    private var sourceConfirmed = false
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

    init(request: PlaybackRequest, library: LibraryStore) {
        self.request = request; self.library = library; profile = library.active.id; episode = request.episode
        player.automaticallyWaitsToMinimizeStalling = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in self?.tick(time.seconds) }
        }
    }

    var nextEpisode: Episode? {
        guard let index = request.episodes.firstIndex(where: { $0.id == episode.id }), index + 1 < request.episodes.count else { return nil }
        return request.episodes[index + 1]
    }

    func start() {
        shuttingDown = false
        task?.cancel(); startupTimeout?.cancel(); player.pause()
        observation = nil
        if let endedObserver { NotificationCenter.default.removeObserver(endedObserver); self.endedObserver = nil }
        generation = UUID(); let token = generation
        status = "Opening episode…"; error = nil; completed = false
        captionGroup = nil; captionsReady = false; sourceConfirmed = false
        resumePosition = library.resume(episode, profile: profile); lastSave = 0
        task = Task {
            do {
                if let direct = request.directURL {
                    candidates = [ResolvedStream(url: direct, referer: direct.deletingLastPathComponent(), height: 0, source: "Direct")]
                } else { candidates = try await resolver.resolve(episode) }
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
            let local = try await relay.start(candidates[candidateIndex])
            let source = candidates[candidateIndex]
            sourceLabel = source.source + (source.height > 0 ? " · \(source.height)p" : "")
            guard token == generation, !Task.isCancelled else { return }
            let item = AVPlayerItem(url: local)
            player.replaceCurrentItem(with: item)
            observation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                Task { @MainActor [weak self] in
                    guard let self, token == self.generation, self.player.currentItem === item else { return }
                    if item.status == .readyToPlay {
                        self.configureCaptions(item, token: token)
                        let duration = item.duration.seconds
                        let position = duration.isFinite ? min(self.resumePosition, max(0, duration - 1)) : self.resumePosition
                        self.player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                            Task { @MainActor [weak self] in
                                guard let self, finished, token == self.generation, !self.shuttingDown else { return }
                                self.player.play(); self.status = nil
                            }
                        }
                    } else if item.status == .failed { self.retryCandidate(token) }
                }
            }
            if let endedObserver { NotificationCenter.default.removeObserver(endedObserver) }
            endedObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, token == self.generation else { return }
                    self.completed = true; self.save()
                    if UserDefaults.standard.bool(forKey: "autoNextEpisode"), self.nextEpisode != nil { self.playNext() }
                }
            }
            startupTimeout?.cancel()
            startupTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(25))
                guard let self, !Task.isCancelled, token == self.generation,
                      !self.sourceConfirmed,
                      self.player.currentTime().seconds <= self.resumePosition + 0.1 else { return }
                self.retryCandidate(token)
            }
        } catch { if !Task.isCancelled { retryCandidate(token) } }
    }

    private func retryCandidate(_ token: UUID) {
        guard token == generation, !shuttingDown else { return }
        generation = UUID(); let nextToken = generation
        observation = nil; startupTimeout?.cancel(); player.pause()
        if candidateIndex < candidates.count {
            let failed = candidates[candidateIndex]
            Task { await SourceHealth.shared.failed(failed) }
        }
        captionsReady = false; captionGroup = nil; sourceConfirmed = false
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
        completed = true; save(); episode = next; start()
    }

    private func tick(_ position: Double) {
        guard position.isFinite, position > 0, !shuttingDown else { return }
        if !sourceConfirmed, position > resumePosition + 1, candidateIndex < candidates.count {
            sourceConfirmed = true
            let source = candidates[candidateIndex]
            Task { await SourceHealth.shared.succeeded(source) }
        }
        if captionsReady, let item = player.currentItem, let captionGroup {
            let selected = item.currentMediaSelection.selectedMediaOption(in: captionGroup)
            let language = selected.map { $0.extendedLanguageTag ?? $0.locale?.languageCode ?? "und" } ?? "off"
            if language != lastCaptionSelection {
                UserDefaults.standard.set(language, forKey: "subtitleLanguage")
                lastCaptionSelection = language
            }
        }
        if position - lastSave >= 5 { save(); lastSave = position }
    }

    private func configureCaptions(_ item: AVPlayerItem, token: UUID) {
        Task {
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible), token == generation,
                  player.currentItem === item else { return }
            captionGroup = group
            let language = UserDefaults.standard.string(forKey: "subtitleLanguage") ?? "en"
            if language == "off" { item.select(nil, in: group) }
            else if let option = group.options.first(where: {
                ($0.extendedLanguageTag ?? $0.locale?.languageCode ?? "").lowercased().hasPrefix(language.lowercased().split(separator: "-").first.map(String.init) ?? language)
            }) { item.select(option, in: group) }
            // If the preferred language is absent, retain the preference for the next episode.
            let selected = item.currentMediaSelection.selectedMediaOption(in: group)
            lastCaptionSelection = selected.map { $0.extendedLanguageTag ?? $0.locale?.languageCode ?? "und" } ?? "off"
            captionsReady = true
        }
    }

    func skip(_ seconds: Double) {
        let time = player.currentTime().seconds
        guard time.isFinite else { return }
        let duration = player.currentItem?.duration.seconds ?? .infinity
        player.seek(to: CMTime(seconds: min(max(0, time + seconds), duration.isFinite ? duration : .infinity), preferredTimescale: 600))
    }

    private func save() {
        guard request.directURL == nil else { return }
        let duration = player.currentItem?.duration.seconds ?? 0
        library.record(profile: profile, title: request.title, episode: episode,
                       position: player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0,
                       duration: duration.isFinite ? duration : 0, completed: completed)
    }

    func close() {
        save(); shuttingDown = true; generation = UUID()
        task?.cancel(); startupTimeout?.cancel(); player.pause(); player.replaceCurrentItem(with: nil)
        observation = nil
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        if let endedObserver { NotificationCenter.default.removeObserver(endedObserver); self.endedObserver = nil }
        Task { await relay.stop() }
    }
}

private struct NativePlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let view = AVPlayerViewController()
        view.player = player; view.videoGravity = .resizeAspect; view.showsPlaybackControls = true
        view.allowsPictureInPicturePlayback = false
        return view
    }
    func updateUIViewController(_ view: AVPlayerViewController, context: Context) { view.player = player }
}

struct PlaybackScreen: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: PlaybackSession
    init(request: PlaybackRequest, library: LibraryStore) {
        _session = StateObject(wrappedValue: PlaybackSession(request: request, library: library))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title2) }.accessibilityLabel("Close player")
                Text(session.episode.number > 0 ? session.episode.label + " · " + session.episode.name : "Playback test").font(.subheadline).lineLimit(2)
                Spacer()
                Button { session.skip(-10) } label: { Image(systemName: "gobackward.10") }.accessibilityLabel("Back 10 seconds")
                Button { session.skip(10) } label: { Image(systemName: "goforward.10") }.accessibilityLabel("Forward 10 seconds")
                if session.nextEpisode != nil { Button("Next episode") { session.playNext() }.buttonStyle(.bordered) }
            }.padding().background(.ultraThinMaterial)
            ZStack {
                Color.black
                NativePlayer(player: session.player)
                if let status = session.status {
                    VStack(spacing: 14) { ProgressView().tint(.orange); Text(status).font(.subheadline) }
                        .padding(24).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
                if let error = session.error {
                    ContentUnavailableView {
                        Label("Couldn’t start playback", systemImage: "play.slash")
                    } description: { Text(error) } actions: { Button("Try again") { session.start() }.buttonStyle(.borderedProminent) }
                }
            }
            if !session.sourceLabel.isEmpty { Text(session.sourceLabel).font(.caption).foregroundStyle(.secondary).padding(8) }
        }.background(.black).preferredColorScheme(.dark)
            .onAppear {
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                try? AVAudioSession.sharedInstance().setActive(true)
                session.start()
            }
            .onDisappear { session.close(); try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }
}
