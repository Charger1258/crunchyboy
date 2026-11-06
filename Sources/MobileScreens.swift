import SwiftUI

@MainActor struct BrowseScreen: View {
    let catalog: AnimeCatalog
    @State private var query = ""
    @State private var category = 0
    @State private var titles: [AnimeTitle] = []
    @State private var loading = false
    @State private var error: String?
    private let categories = [("Popular", "/most-popular"), ("New episodes", "/recently-updated"), ("Series", "/tv"), ("Films", "/movie")]
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(categories.indices, id: \.self) { index in
                            Button { category = index } label: {
                                Text(categories[index].0).font(.subheadline.weight(.semibold)).padding(.horizontal, 16).padding(.vertical, 11)
                                    .foregroundStyle(category == index ? .black : .white)
                                    .background(category == index ? AnimeTheme.accent : AnimeTheme.surface, in: RoundedRectangle(cornerRadius: 4))
                            }
                        }
                    }.padding(.horizontal, 16)
                }
                if loading && titles.isEmpty { ProgressView().frame(maxWidth: .infinity).padding(40) }
                if let error { Text(error).foregroundStyle(.secondary).padding(.horizontal, 16) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: 12)], alignment: .leading, spacing: 22) {
                    ForEach(titles) { title in NavigationLink(value: title) { PosterTile(title: title) }.buttonStyle(.plain) }
                }.padding(.horizontal, 16)
                if !loading && error == nil && titles.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }.padding(.vertical, 12)
        }.background(AnimeTheme.background).navigationTitle("Browse").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search anime")
            .task(id: "\(category):\(query)") { await load() }
    }
    private func load() async {
        loading = true; error = nil
        let submitted = query.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if !submitted.isEmpty { try await Task.sleep(for: .milliseconds(350)) }
            let result = try await (submitted.isEmpty ? catalog.browse(path: categories[category].1) : catalog.search(submitted))
            try Task.checkCancellation(); titles = result; loading = false
        } catch { if !Task.isCancelled { self.error = error.localizedDescription; loading = false } }
    }
}

struct WatchLibraryScreen: View {
    @EnvironmentObject private var library: LibraryStore
    let play: (PlaybackRequest) -> Void
    let browse: () -> Void
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                Text("Your watch history").font(.subheadline).foregroundStyle(.secondary)
                if library.continuing.isEmpty {
                    ContentUnavailableView {
                        Label("Find your first anime", systemImage: "bookmark")
                    } description: { Text("Your shows and episode progress will appear here.") } actions: { Button("Browse anime", action: browse).buttonStyle(.borderedProminent) }
                }
                ForEach(library.continuing) { item in
                    if item.caughtUp { NavigationLink(value: item.title) { row(item) }.buttonStyle(.plain) }
                    else {
                        Button { play(PlaybackRequest(title: item.title, episode: item.episode, episodes: library.episodes(for: item.title))) } label: { row(item) }.buttonStyle(.plain)
                    }
                }
            }.padding(16)
        }.background(AnimeTheme.background).navigationTitle("My Library").navigationBarTitleDisplayMode(.inline)
    }
    private func row(_ item: ContinueItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            CoverImage(url: item.episode.image ?? item.title.poster).aspectRatio(16/9, contentMode: .fit)
                .saturation(item.caughtUp ? 0.3 : 1).brightness(item.caughtUp ? -0.4 : 0)
                .overlay(alignment: .center) { if !item.caughtUp { Image(systemName: "play.circle.fill").font(.system(size: 42)).foregroundStyle(.white) } }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            if library.progress(item.episode) > 0 { ProgressView(value: library.progress(item.episode)).tint(AnimeTheme.accent) }
            Text(item.title.name).font(.headline).foregroundStyle(item.caughtUp ? .secondary : .primary)
            Text(item.caughtUp ? "All caught up · " + item.episode.label : item.episode.label + " · " + item.episode.name)
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}
