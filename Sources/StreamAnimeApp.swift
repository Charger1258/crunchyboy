import SwiftUI

@main struct StreamAnimeApp: App {
    @StateObject private var library = LibraryStore()
    var body: some Scene {
        WindowGroup {
            RootScreen().environmentObject(library).tint(AnimeTheme.accent).preferredColorScheme(.dark)
        }
    }
}

struct RootScreen: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var catalog = AnimeCatalog()
    @State private var profiles = true
    @State private var playback: PlaybackRequest?

    var body: some View {
        TabView {
            NavigationStack {
                DiscoverScreen(catalog: catalog, play: { playback = $0 })
                    .navigationDestination(for: AnimeTitle.self) { title in ShowScreen(title: title, catalog: catalog, play: { playback = $0 }) }
                    .toolbar { profileButton }
            }.tabItem { Label("Home", systemImage: "house.fill") }
            NavigationStack {
                SearchScreen(catalog: catalog)
                    .navigationDestination(for: AnimeTitle.self) { title in ShowScreen(title: title, catalog: catalog, play: { playback = $0 }) }
                    .toolbar { profileButton }
            }.tabItem { Label("Search", systemImage: "magnifyingglass") }
            NavigationStack {
                SettingsScreen(showProfiles: { profiles = true }, play: { playback = $0 })
            }.tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .fullScreenCover(isPresented: $profiles) { ProfilesScreen() }
        .fullScreenCover(item: $playback) { request in PlaybackScreen(request: request, library: library) }
    }

    @ToolbarContentBuilder private var profileButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { profiles = true } label: {
                Image(systemName: library.active.symbol).foregroundStyle(.orange).padding(8)
                    .background(.orange.opacity(0.14), in: Circle())
            }.accessibilityLabel("Switch profile, currently \(library.active.name)")
        }
    }
}

struct CoverImage: View {
    let url: URL?
    var body: some View {
        AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: {
            Rectangle().fill(.white.opacity(0.06)).overlay { Image(systemName: "play.square").foregroundStyle(.secondary) }
        }.clipped()
    }
}

struct PosterTile: View {
    let title: AnimeTitle
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverImage(url: title.poster).aspectRatio(2 / 3, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12))
            Text(title.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .topLeading)
        }.contentShape(Rectangle())
    }
}

struct ContinueCard: View {
    @EnvironmentObject private var library: LibraryStore
    let item: ContinueItem
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            CoverImage(url: item.episode.image ?? item.title.poster).frame(width: 260, height: 146)
                .saturation(item.caughtUp ? 0.35 : 1).brightness(item.caughtUp ? -0.35 : 0)
                .overlay(alignment: .topLeading) {
                    Text(item.caughtUp ? "ALL CAUGHT UP" : item.position > 0 ? "CONTINUE" : "UP NEXT")
                        .font(.caption2.bold()).padding(7).background(.black.opacity(0.8), in: Capsule()).padding(8)
                }.clipShape(RoundedRectangle(cornerRadius: 12))
            if !item.caughtUp, library.progress(item.episode) > 0 {
                ProgressView(value: library.progress(item.episode)).tint(AnimeTheme.accent)
            }
            Text(item.title.name).font(.subheadline.bold()).foregroundStyle(item.caughtUp ? .secondary : .primary).lineLimit(2)
            Text(item.episode.label + (item.position > 0 ? " · Resume \(Int(item.position / 60)):\(String(format: "%02d", Int(item.position) % 60))" : ""))
                .font(.caption).foregroundStyle(.secondary)
        }.frame(width: 260, alignment: .leading)
    }
}

struct SearchScreen: View {
    let catalog: AnimeCatalog
    @State private var query = ""
    @State private var results: [AnimeTitle] = []
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        ScrollView {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 {
                ContentUnavailableView("What are you looking for?", systemImage: "magnifyingglass", description: Text("Search for an anime title."))
            } else if loading { ProgressView("Searching…").padding(40) }
            else if let error { ContentUnavailableView("Search unavailable", systemImage: "wifi.exclamationmark", description: Text(error)) }
            else if results.isEmpty { ContentUnavailableView.search(text: query) }
            else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 20) {
                    ForEach(results) { title in NavigationLink(value: title) { PosterTile(title: title) }.buttonStyle(.plain) }
                }.padding(20)
            }
        }.navigationTitle("Search").searchable(text: $query, prompt: "Anime title")
            .task(id: query) {
                let submitted = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard submitted.count >= 2 else { results = []; return }
                loading = true; error = nil
                do {
                    try await Task.sleep(for: .milliseconds(450))
                    let matches = try await catalog.search(submitted)
                    try Task.checkCancellation(); results = matches; loading = false
                } catch { if !Task.isCancelled { self.error = error.localizedDescription; loading = false } }
            }
    }
}

struct ShowScreen: View {
    @EnvironmentObject private var library: LibraryStore
    let title: AnimeTitle
    let catalog: AnimeCatalog
    let play: (PlaybackRequest) -> Void
    @State private var detail: ShowDetail?
    @State private var season = 1
    @State private var error: String?
    @State private var loading = false
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 18) {
                        CoverImage(url: title.poster).frame(width: 110, height: 165).clipShape(RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 12) {
                            Text(title.name).font(.title2.bold())
                            if let detail { Text("\(detail.seasons.filter { $0 > 0 }.count) seasons · \(detail.episodes.count) episodes").font(.caption).foregroundStyle(.secondary) }
                            if let current = library.continuing.first(where: { $0.title.id == title.id }) {
                                Button(current.caughtUp ? "Watch again" : current.position > 0 ? "Resume episode" : "Play next episode") {
                                    launch(current.episode)
                                }.buttonStyle(.borderedProminent)
                            } else if let first = detail?.episodes.first(where: { $0.season > 0 }) ?? detail?.episodes.first {
                                Button("Start watching") { launch(first) }.buttonStyle(.borderedProminent)
                            }
                        }
                    }
                    if let error { Text(error).foregroundStyle(.secondary); Button("Retry") { Task { await load() } } }
                    if loading && detail == nil { ProgressView("Loading episodes…").frame(maxWidth: .infinity).padding(32) }
                    if let detail {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(detail.seasons, id: \.self) { number in
                                    Button(number == 0 ? "Specials" : "Season \(number)") { season = number }
                                        .buttonStyle(.bordered).tint(season == number ? .orange : .gray)
                                        .accessibilityValue(season == number ? "Selected" : "")
                                }
                            }
                        }
                        ForEach(detail.episodes.filter { $0.season == season }) { episode in
                            Button { launch(episode) } label: {
                                HStack(spacing: 14) {
                                    Text(episode.number.formatted(.number.precision(.fractionLength(0...1))))
                                        .font(.caption.bold()).foregroundStyle(AnimeTheme.accent).frame(width: 22)
                                    CoverImage(url: episode.image ?? title.poster).frame(width: 108, height: 64)
                                        .overlay(alignment: .bottom) { if library.progress(episode) > 0 { ProgressView(value: library.progress(episode)).tint(AnimeTheme.accent) } }
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(episode.name).font(.body.weight(.medium)).foregroundStyle(.primary)
                                        if library.resume(episode) > 0 { Text("Resume \(Int(library.resume(episode) / 60)) min").font(.caption).foregroundStyle(.secondary) }
                                        if library.watched(episode) { Label("Watched", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "play.fill").foregroundStyle(AnimeTheme.accent)
                                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(AnimeTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(.plain).id(episode.id).accessibilityIdentifier("episodeRow")
                        }
                    }
                }.padding(20)
            }.background(AnimeTheme.background).task {
                await load()
                if let current = library.continuing.first(where: { $0.title.id == title.id }) { proxy.scrollTo(current.episode.id, anchor: .center) }
            }
                .onChange(of: season) { _, _ in
                    if let current = library.continuing.first(where: { $0.title.id == title.id }), current.episode.season == season {
                        withAnimation { proxy.scrollTo(current.episode.id, anchor: .center) }
                    }
                }
        }.navigationBarTitleDisplayMode(.inline)
    }
    private func launch(_ episode: Episode) { play(PlaybackRequest(title: title, episode: episode, episodes: detail?.episodes ?? library.episodes(for: title))) }
    private func load() async {
        loading = true; error = nil
        let saved = library.episodes(for: title)
        if !saved.isEmpty { detail = ShowDetail(title: title, episodes: saved) }
        do {
            let loaded = try await catalog.details(title)
            try Task.checkCancellation(); library.remember(loaded)
            detail = ShowDetail(title: title, episodes: library.episodes(for: title))
            season = library.continuing.first(where: { $0.title.id == title.id })?.episode.season ?? loaded.seasons.first(where: { $0 > 0 }) ?? loaded.seasons.first ?? 1
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        loading = false
    }
}
