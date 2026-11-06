import SwiftUI

@MainActor struct DiscoverScreen: View {
    @EnvironmentObject private var library: LibraryStore
    let catalog: AnimeCatalog
    let play: (PlaybackRequest) -> Void
    @State private var shelves: [String: [AnimeTitle]] = [:]
    @State private var errors: [String: String] = [:]
    @State private var loading = false
    private let sections = [("Popular now", "/most-popular"), ("Recently updated", "/recently-updated"),
                            ("Anime series", "/tv"), ("Anime films", "/movie")]
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if let featured = shelves[sections[0].0]?.first {
                    NavigationLink(value: featured) {
                        VStack(alignment: .leading, spacing: 14) {
                            CoverImage(url: featured.poster).frame(height: 235).clipped()
                                .overlay(alignment: .bottom) { LinearGradient(colors: [.clear, AnimeTheme.background], startPoint: .top, endPoint: .bottom).frame(height: 90) }
                            VStack(alignment: .leading, spacing: 12) {
                                Text("FEATURED ANIME").font(.system(size: 10, weight: .bold)).tracking(1.5).foregroundStyle(.secondary)
                                Text(featured.name).font(.system(size: 27, weight: .bold)).foregroundStyle(.white).lineLimit(2)
                                HStack {
                                    Text("View episodes").font(.subheadline.bold())
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption.bold())
                                }.padding(15).foregroundStyle(.black)
                                    .background(AnimeTheme.accent, in: RoundedRectangle(cornerRadius: 4))
                            }.padding(.horizontal, 16)
                        }
                    }.buttonStyle(.plain).accessibilityIdentifier("featuredShow")
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("STREAM ANIME").font(.caption.bold()).tracking(2).foregroundStyle(AnimeTheme.accent)
                        Text("Find your next anime.").font(.title.bold())
                    }.padding(.horizontal, 16).padding(.top, 20)
                }
                if !library.continuing.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Continue watching").font(.system(size: 20, weight: .bold)).padding(.horizontal, 16)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(library.continuing) { item in
                                    if item.caughtUp {
                                        NavigationLink(value: item.title) { ContinueCard(item: item) }.buttonStyle(.plain)
                                    } else {
                                        Button { play(PlaybackRequest(title: item.title, episode: item.episode, episodes: library.episodes(for: item.title))) } label: { ContinueCard(item: item) }.buttonStyle(.plain)
                                    }
                                }
                            }.padding(.horizontal, 16)
                        }
                    }
                }
                if loading && shelves.isEmpty { ProgressView("Finding anime...").frame(maxWidth: .infinity).padding(30) }
                ForEach(sections, id: \.0) { section in
                    VStack(alignment: .leading, spacing: 14) {
                        Text(section.0).font(.system(size: 20, weight: .bold)).padding(.horizontal, 16)
                        if let error = errors[section.0], shelves[section.0] == nil {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(error).font(.subheadline).foregroundStyle(.secondary)
                                Button("Try again") { Task { await load() } }.buttonStyle(.bordered)
                            }.padding(.horizontal, 16)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(shelves[section.0] ?? []) { title in
                                    NavigationLink(value: title) { PosterTile(title: title).frame(width: 125) }.buttonStyle(.plain)
                                }
                            }.padding(.horizontal, 16)
                        }
                    }
                }
            }.padding(.bottom, 24)
        }.background(AnimeTheme.background).navigationTitle("Stream Anime").navigationBarTitleDisplayMode(.inline)
            .task { if shelves.isEmpty { await load() }; await refreshWatching() }
            .refreshable { await load(); await refreshWatching() }
            .onChange(of: library.active.id) { _, _ in Task { await refreshWatching() } }
    }
    @MainActor private func load() async {
        guard !loading else { return }
        loading = true
        for section in sections {
            guard !Task.isCancelled else { break }
            do {
                let titles = try await catalog.browse(path: section.1)
                try Task.checkCancellation()
                shelves[section.0] = titles; errors[section.0] = nil
            } catch { if !Task.isCancelled { errors[section.0] = error.localizedDescription } }
        }
        loading = false
    }
    private func refreshWatching() async {
        // Bounded refresh discovers new episodes without changing watch timestamps/order.
        let titles = Array(library.continuing.prefix(6).map(\.title))
        for title in titles {
            guard !Task.isCancelled else { return }
            if let detail = try? await catalog.details(title) { library.remember(detail) }
        }
    }
}
