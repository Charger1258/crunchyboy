import SwiftUI

@MainActor struct DiscoverScreen: View {
    @EnvironmentObject private var library: LibraryStore
    let catalog: AnimeCatalog
    let play: (PlaybackRequest) -> Void
    @State private var shelves: [String: [AnimeTitle]] = [:]
    @State private var errors: [String: String] = [:]
    @State private var loading = false
    @State private var refreshingEpisodes = false
    @State private var checkedEpisodes: [String: Date] = [:]
    private let sections = CatalogShelf.allCases
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Queue").font(.system(size: 20, weight: .bold)).padding(.horizontal, 16)
                    if library.queue.isEmpty {
                        Text("You're all caught up. New episodes from your watched shows will appear here.")
                            .font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 16)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(library.queue) { item in
                                    VStack(alignment: .leading, spacing: 8) {
                                        Button { play(PlaybackRequest(title: item.title, episode: item.episode, episodes: library.episodes(for: item.title))) } label: {
                                            ContinueCard(item: item)
                                        }.buttonStyle(.plain)
                                        Menu {
                                            NavigationLink("View episodes", value: item.title)
                                            Button("Remove from Queue", role: .destructive) {
                                                library.setQueueHidden(item.title, hidden: true)
                                            }
                                            if library.isSaved(item.title) {
                                                Button("Remove from Watchlist", role: .destructive) { library.toggleSaved(item.title) }
                                            }
                                        } label: {
                                            Label("Options", systemImage: "ellipsis").font(.caption)
                                        }.accessibilityLabel("Queue options for \(item.title.name)")
                                    }
                                }
                            }.padding(.horizontal, 16)
                        }
                    }
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
            .task(id: library.active.id) {
                while !Task.isCancelled {
                    await refreshWatching()
                    try? await Task.sleep(for: .seconds(60))
                }
            }
            .refreshable { await load(); await refreshWatching(force: true) }
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
    private func refreshWatching(force: Bool = false) async {
        guard !refreshingEpisodes else { return }
        refreshingEpisodes = true
        defer { refreshingEpisodes = false }
        let profile = library.active.id
        let titles = library.continuing.map(\.title).filter { !library.isQueueHidden($0) }
            .filter { force || Date().timeIntervalSince(checkedEpisodes[$0.id] ?? .distantPast) >= 900 }
            .sorted { (checkedEpisodes[$0.id] ?? .distantPast) < (checkedEpisodes[$1.id] ?? .distantPast) }
            .prefix(12)
        for title in titles {
            guard !Task.isCancelled, library.active.id == profile else { return }
            if let detail = try? await catalog.details(title) {
                guard !Task.isCancelled, library.active.id == profile else { return }
                library.remember(detail)
            }
            checkedEpisodes[title.id] = Date()
        }
    }
}
