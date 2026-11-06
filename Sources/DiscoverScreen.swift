import SwiftUI

struct DiscoverScreen: View {
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
            LazyVStack(alignment: .leading, spacing: 30) {
                if let featured = shelves[sections[0].0]?.first {
                    NavigationLink(value: featured) {
                        ZStack(alignment: .bottomLeading) {
                            CoverImage(url: featured.poster).frame(height: 360)
                            LinearGradient(colors: [.clear, .black.opacity(0.65), AnimeTheme.background], startPoint: .top, endPoint: .bottom)
                            VStack(alignment: .leading, spacing: 12) {
                                Text("YOUR NEXT WATCH").font(.caption.weight(.black)).tracking(2).foregroundStyle(AnimeTheme.accent)
                                Text(featured.name).font(.largeTitle.weight(.heavy)).foregroundStyle(.white).lineLimit(3)
                                Label("Explore episodes", systemImage: "play.fill").font(.subheadline.bold())
                                    .padding(.horizontal, 18).padding(.vertical, 12).foregroundStyle(.black)
                                    .background(AnimeTheme.accent, in: Capsule())
                            }.padding(24)
                        }.frame(height: 360).clipped()
                    }.buttonStyle(.plain).accessibilityIdentifier("featuredShow")
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("STREAM ANIME").font(.caption.bold()).tracking(3).foregroundStyle(AnimeTheme.accent)
                        Text("Your next adventure.").font(.largeTitle.weight(.heavy))
                    }.padding(.horizontal, 20).padding(.top, 24)
                }
                if !library.continuing.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Continue watching").font(.title2.bold()).padding(.horizontal, 20)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(library.continuing) { item in
                                    if item.caughtUp {
                                        NavigationLink(value: item.title) { ContinueCard(item: item) }.buttonStyle(.plain)
                                    } else {
                                        Button { play(PlaybackRequest(title: item.title, episode: item.episode, episodes: library.episodes(for: item.title))) } label: { ContinueCard(item: item) }.buttonStyle(.plain)
                                    }
                                }
                            }.padding(.horizontal, 20)
                        }
                    }
                }
                if loading && shelves.isEmpty { ProgressView("Finding anime...").frame(maxWidth: .infinity).padding(30) }
                ForEach(sections, id: \.0) { section in
                    VStack(alignment: .leading, spacing: 14) {
                        Text(section.0).font(.title2.bold()).padding(.horizontal, 20)
                        if let error = errors[section.0], shelves[section.0] == nil {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(error).font(.subheadline).foregroundStyle(.secondary)
                                Button("Try again") { Task { await load() } }.buttonStyle(.bordered)
                            }.padding(.horizontal, 20)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(shelves[section.0] ?? []) { title in
                                    NavigationLink(value: title) { PosterTile(title: title).frame(width: 145) }.buttonStyle(.plain)
                                }
                            }.padding(.horizontal, 20)
                        }
                    }
                }
                Text("Made for your next anime night.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(20)
            }.padding(.bottom, 24)
        }.background(AnimeTheme.background).navigationTitle("Stream Anime").navigationBarTitleDisplayMode(.inline)
            .task { if shelves.isEmpty { await load() }; await refreshWatching() }
            .refreshable { await load(); await refreshWatching() }
            .onChange(of: library.active.id) { _, _ in Task { await refreshWatching() } }
    }
    private func load() async {
        guard !loading else { return }
        loading = true
        await withTaskGroup(of: (String, [AnimeTitle]?, String?).self) { group in
            for section in sections {
                group.addTask {
                    do { return (section.0, try await catalog.browse(path: section.1), nil) }
                    catch { return (section.0, nil, error.localizedDescription) }
                }
            }
            for await (name, titles, error) in group {
                guard !Task.isCancelled else { break }
                if let titles { shelves[name] = titles }
                errors[name] = error
            }
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
