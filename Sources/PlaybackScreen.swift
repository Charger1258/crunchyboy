import SwiftUI
import AVKit

private final class VideoCanvas: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var videoLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

private struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> VideoCanvas {
        let view = VideoCanvas()
        view.backgroundColor = .black
        view.videoLayer.videoGravity = .resizeAspect
        view.videoLayer.player = player
        return view
    }
    func updateUIView(_ view: VideoCanvas, context: Context) {
        if view.videoLayer.player !== player { view.videoLayer.player = player }
    }
    static func dismantleUIView(_ view: VideoCanvas, coordinator: ()) { view.videoLayer.player = nil }
}

struct PlaybackScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session: PlaybackSession
    let close: () -> Void
    @State private var controls = true
    @State private var scrubbing = false
    @State private var seekPosition: Double = 0
    @State private var hideTask: Task<Void, Never>?
    @AppStorage("captionScale") private var captionScale = 1.0
    init(request: PlaybackRequest, library: LibraryStore, close: @escaping () -> Void) {
        _session = StateObject(wrappedValue: PlaybackSession(request: request, library: library))
        self.close = close
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                PlayerSurface(player: session.player).allowsHitTesting(false)
                if session.status != nil { Color.black.allowsHitTesting(false) }
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(SpatialTapGesture(count: 2).onEnded { event in
                        session.skip(event.location.x < geometry.size.width / 2 ? -10 : 10); showControls()
                    }.exclusively(before: SpatialTapGesture().onEnded { _ in
                        withAnimation(.easeInOut(duration: 0.18)) { controls.toggle() }
                        if controls { scheduleHide() }
                    }))
                if !session.captionText.isEmpty {
                    Text(session.captionText)
                        .font(.system(size: min(30, max(18, geometry.size.height * 0.057)) * captionScale, weight: .semibold))
                        .foregroundStyle(.white).multilineTextAlignment(.center).lineLimit(6)
                        .padding(.horizontal, 10).padding(.vertical, 5).background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 4))
                        .shadow(color: .black, radius: 2, y: 1)
                        .frame(maxWidth: geometry.size.width * 0.82, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, controls ? 108 : max(22, geometry.safeAreaInsets.bottom + 12))
                        .allowsHitTesting(false).accessibilityIdentifier("subtitle-text")
                }
                if controls {
                    LinearGradient(colors: [.black.opacity(0.8), .clear, .clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom).allowsHitTesting(false)
                    VStack(spacing: 0) {
                        topBar
                        Spacer(minLength: 8)
                        if session.status == nil && session.error == nil { transport }
                        Spacer(minLength: 8)
                        bottomBar
                    }.padding(.horizontal, max(24, geometry.safeAreaInsets.leading + 8))
                        .padding(.top, 12).padding(.bottom, max(12, geometry.safeAreaInsets.bottom + 4))
                        .transition(.opacity)
                }
                if let status = session.status {
                    VStack(spacing: 12) { ProgressView().tint(.white); Text(status).font(.caption).foregroundStyle(.white.opacity(0.8)) }
                        .padding(20).background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 10)).allowsHitTesting(false)
                }
                if let error = session.error {
                    VStack(spacing: 14) {
                        Image(systemName: "play.slash").font(.title)
                        Text("Playback unavailable").font(.headline)
                        Text(error).font(.caption).multilineTextAlignment(.center).lineLimit(4)
                        HStack { Button("Retry") { session.start(); showControls() }; Button("Close", action: close) }.buttonStyle(.borderedProminent)
                    }.foregroundStyle(.white).padding(24).frame(maxWidth: 460).background(.black.opacity(0.95), in: RoundedRectangle(cornerRadius: 12))
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }.ignoresSafeArea().background(.black).preferredColorScheme(.dark).statusBarHidden()
            .onAppear {
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                try? AVAudioSession.sharedInstance().setActive(true)
                session.start()
            }
            .onDisappear { hideTask?.cancel(); session.close(); try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
            .onChange(of: session.position) { _, position in if !scrubbing { seekPosition = position } }
            .onChange(of: session.isPlaying) { _, playing in if playing { scheduleHide() } }
            .onChange(of: scenePhase) { _, phase in if phase == .background { session.pause(); controls = true } }
    }
    private var topBar: some View {
        HStack(spacing: 16) {
            Button(action: close) { Image(systemName: "chevron.down").font(.title3.bold()).frame(width: 44, height: 44) }.accessibilityLabel("Close player")
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title).font(.headline).lineLimit(1)
                Text(session.episode.label + " · " + session.episode.name).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
            }
            Spacer(minLength: 0)
            captionMenu
            qualityMenu
        }.foregroundStyle(.white)
    }
    private var transport: some View {
        HStack(spacing: 56) {
            Button { session.skip(-10); showControls() } label: { Image(systemName: "gobackward.10").font(.system(size: 31)).frame(width: 56, height: 56) }.accessibilityLabel("Back 10 seconds")
            Button { session.togglePlay(); showControls() } label: {
                Image(systemName: session.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 37)).frame(width: 72, height: 72)
            }.accessibilityLabel(session.isPlaying ? "Pause" : "Play")
            Button { session.skip(10); showControls() } label: { Image(systemName: "goforward.10").font(.system(size: 31)).frame(width: 56, height: 56) }.accessibilityLabel("Forward 10 seconds")
        }.foregroundStyle(.white).shadow(color: .black.opacity(0.9), radius: 8)
    }
    private var bottomBar: some View {
        VStack(spacing: 8) {
            if let notice = session.captionNotice { Text(notice).font(.caption2).foregroundStyle(.white.opacity(0.8)).lineLimit(1) }
            HStack(spacing: 12) {
                Text(Self.time(scrubbing ? seekPosition : session.position)).monospacedDigit().frame(minWidth: 46)
                Slider(value: $seekPosition, in: 0...max(session.duration, 1), onEditingChanged: { editing in
                    scrubbing = editing
                    if editing { hideTask?.cancel() } else { session.seek(to: seekPosition); showControls() }
                }).tint(AnimeTheme.accent).accessibilityLabel("Episode timeline")
                    .background(alignment: .leading) {
                        GeometryReader { proxy in
                            Rectangle().fill(.white.opacity(0.35)).frame(width: proxy.size.width * min(1, session.buffered / max(1, session.duration)), height: 3).position(x: proxy.size.width * min(1, session.buffered / max(1, session.duration)) / 2, y: proxy.size.height / 2)
                        }.allowsHitTesting(false)
                    }
                Text(Self.time(session.duration)).monospacedDigit().frame(minWidth: 46)
            }.font(.caption).foregroundStyle(.white)
            HStack {
                Text(session.sourceLabel).font(.caption2).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                Spacer()
                if session.nextEpisode != nil {
                    Button { session.playNext(); showControls() } label: { Label("Next episode", systemImage: "forward.end.fill").font(.caption.bold()).padding(.vertical, 8) }
                        .accessibilityIdentifier("next-episode")
                }
            }.foregroundStyle(.white)
        }
    }
    private var captionMenu: some View {
        Menu {
            Button { session.selectCaption("off"); showControls() } label: { Label("Off", systemImage: session.selectedCaption == "off" ? "checkmark" : "") }
            ForEach(session.captionOptions) { option in
                Button { session.selectCaption(option.id); showControls() } label: { Label(option.label, systemImage: session.selectedCaption == option.id ? "checkmark" : "") }
            }
            if session.selectedCaption != "off" { Button("Reload subtitles") { session.selectCaption(session.selectedCaption); showControls() } }
            Menu("Text size") {
                Button("Small") { captionScale = 0.85 }; Button("Normal") { captionScale = 1 }; Button("Large") { captionScale = 1.25 }
            }
            Menu("Subtitle timing: \(session.subtitleOffset, specifier: "%.1f")s") {
                Button("Show 0.5s earlier") { session.setSubtitleOffset(session.subtitleOffset - 0.5); showControls() }
                Button("Show 0.5s later") { session.setSubtitleOffset(session.subtitleOffset + 0.5); showControls() }
                Button("Reset timing") { session.setSubtitleOffset(0); showControls() }
            }
        } label: {
            Image(systemName: "captions.bubble").font(.title3).foregroundStyle(session.selectedCaption == "off" ? .white : AnimeTheme.accent).frame(width: 44, height: 44)
        }.accessibilityLabel("Subtitles").accessibilityValue(session.captionLabel)
            .simultaneousGesture(TapGesture().onEnded { hideTask?.cancel() })
    }
    private var qualityMenu: some View {
        Menu {
            ForEach([0, 1080, 720, 480], id: \.self) { height in
                Button(height == 0 ? "Auto (best available)" : "Up to \(height)p") { session.setQuality(height); showControls() }
            }
        } label: { Image(systemName: "gearshape").font(.title3).frame(width: 44, height: 44) }
            .accessibilityLabel("Video quality").accessibilityValue(session.qualityHeight == 0 ? "Auto" : "\(session.qualityHeight)p")
            .simultaneousGesture(TapGesture().onEnded { hideTask?.cancel() })
    }
    private func showControls() { controls = true; scheduleHide() }
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, session.isPlaying, !scrubbing, session.error == nil else { return }
            withAnimation(.easeInOut(duration: 0.2)) { controls = false }
        }
    }
    static func time(_ seconds: Double) -> String {
        let value = seconds.isFinite ? Int(max(0, seconds)) : 0
        return value >= 3600 ? String(format: "%d:%02d:%02d", value/3600, value/60%60, value%60) : String(format: "%d:%02d", value/60, value%60)
    }
}
