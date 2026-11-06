import SwiftUI

struct ProfilesScreen: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    @State private var name = ""
    @State private var symbol = ViewerProfile.symbols[0]
    @State private var error: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 10) {
                        Text(creating ? "Make it yours." : "Who’s watching?").font(.largeTitle.bold())
                        Text(creating ? "Choose a name and an avatar." : "Your shows. Your progress.").foregroundStyle(.secondary)
                    }.padding(.top, 30)
                    if creating {
                        TextField("Profile name", text: $name).textFieldStyle(.roundedBorder).textInputAutocapitalization(.words)
                            .onChange(of: name) { _, value in name = String(value.prefix(32)) }
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 20) {
                            ForEach(ViewerProfile.symbols, id: \.self) { avatar in
                                Button { symbol = avatar } label: {
                                    Image(systemName: avatar).font(.system(size: 36)).frame(width: 76, height: 76)
                                        .background(.orange.opacity(symbol == avatar ? 0.35 : 0.08), in: RoundedRectangle(cornerRadius: 22))
                                        .overlay(RoundedRectangle(cornerRadius: 22).stroke(symbol == avatar ? .orange : .clear, lineWidth: 2))
                                }.accessibilityLabel(avatar.replacingOccurrences(of: ".fill", with: "") + " avatar")
                            }
                        }
                        if let error { Text(error).foregroundStyle(.red).font(.caption) }
                        Button("Create profile") {
                            if library.add(name: name, symbol: symbol) { creating = false; name = ""; error = nil }
                            else { error = "Enter a unique name, up to 32 characters." }
                        }.buttonStyle(.borderedProminent).controlSize(.large)
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 24) {
                            ForEach(library.profiles) { profile in
                                Button { library.select(profile); dismiss() } label: {
                                    VStack(spacing: 12) {
                                        Image(systemName: profile.symbol).font(.system(size: 36)).frame(width: 76, height: 76)
                                            .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 22))
                                            .overlay(RoundedRectangle(cornerRadius: 22).stroke(library.active.id == profile.id ? .orange : .clear, lineWidth: 2))
                                        Text(profile.name).font(.subheadline.bold()).foregroundStyle(.primary).lineLimit(2)
                                    }
                                }.buttonStyle(.plain)
                            }
                        }
                        Button { creating = true } label: { Label("Add profile", systemImage: "plus.circle") }.buttonStyle(.bordered)
                    }
                }.padding(24)
            }.toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button(creating ? "Cancel" : "Done") { if creating { creating = false } else { dismiss() } } }
            }
        }.tint(.orange).preferredColorScheme(.dark)
    }
}

struct SettingsScreen: View {
    @EnvironmentObject private var library: LibraryStore
    let showProfiles: () -> Void
    let play: (PlaybackRequest) -> Void
    @State private var streamURL = ""
    @State private var invalidURL = false
    var body: some View {
        Form {
            Section("Your profile") {
                Button { showProfiles() } label: { Label(library.active.name, systemImage: library.active.symbol) }
                Text("Watch history is saved separately for each profile on this iPhone.").font(.footnote).foregroundStyle(.secondary)
                if let error = library.storageError { Text(error).foregroundStyle(.red) }
            }
            Section("Playback test") {
                Text("Have a direct HTTPS HLS stream? Open it here to check playback separately from the catalog.")
                    .font(.footnote).foregroundStyle(.secondary)
                TextField("https://…/playlist.m3u8", text: $streamURL).keyboardType(.URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Open stream") {
                    guard let url = SafeURL.https(streamURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { invalidURL = true; return }
                    play(PlaybackRequest(title: AnimeTitle(slug: "playback-test", name: "Playback test", poster: nil),
                                         episode: Episode(id: UUID().uuidString, release: "", season: 0, number: 0, name: "Playback test"),
                                         episodes: [], directURL: url))
                }.disabled(streamURL.isEmpty)
            }
            Section("About") {
                LabeledContent("Version", value: "0.1 · iPhone preview")
                Text("This first version focuses on catalog browsing, native playback, profiles, and saved progress.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("Settings")
            .alert("Use an HTTPS address", isPresented: $invalidURL) {
                Button("OK", role: .cancel) {}
            } message: { Text("Enter the full HTTPS stream URL.") }
    }
}
