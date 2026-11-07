import SwiftUI

@MainActor struct DiscoverScreen: View {
    @EnvironmentObject private var library: LibraryStore
    let catalog: AnimeCatalog
    let play: (PlaybackRequest) -> Void
    @State private var shelves: [String: [AnimeTitle]] = [:]
    @State private var errors: [String: String] = [:]
    @State private var loading = false
    private let sections = CatalogShelf.allCases
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
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
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 14) {
                        Text(section.title).font(.system(size: 20, weight: .bold)).padding(.horizontal, 16)
                        if let error = errors[section.title], shelves[section.title] == nil {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(error).font(.subheadline).foregroundStyle(.secondary)
                                Button("Try again") { Task { await load() } }.buttonStyle(.bordered)
                            }.padding(.horizontal, 16)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(shelves[section.title] ?? []) { title in
                                    NavigationLink(value: title) { PosterTile(title: title).frame(width: 125) }.buttonStyle(.plain).accessibilityIdentifier("home-title-\(section.rawValue)-\(title.slug)")
                                }
                            }.padding(.horizontal, 16)
                        }
                    }
                }
            }.padding(.top, 16).padding(.bottom, 24)
        }.background(AnimeTheme.background).navigationTitle("Stream Anime").navigationBarTitleDisplayMode(.inline)
            .task { if shelves.isEmpty { await load() } }
            .task(id: library.continuing.prefix(6).map(\.title.id)) { await refreshWatching() }
            .refreshable { await load(); await refreshWatching() }
    }
    @MainActor private func load() async {
        guard !loading else { return }
        loading = true
        for section in sections {
            guard !Task.isCancelled else { break }
            do {
                let titles = try await catalog.browse(shelf: section, refresh: section == .today)
                try Task.checkCancellation()
                shelves[section.title] = titles; errors[section.title] = nil
            } catch { if !Task.isCancelled { errors[section.title] = error.localizedDescription } }
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
