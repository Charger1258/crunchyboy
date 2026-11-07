import SwiftUI

struct ProfilesScreen: View {
    var onComplete: (() -> Void)? = nil
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
                                    ProfileAvatar(symbol: avatar, selected: symbol == avatar)
                                }.accessibilityLabel(avatar.replacingOccurrences(of: ".fill", with: "") + " avatar")
                            }
                        }
                        if let error { Text(error).foregroundStyle(.red).font(.caption) }
                        Button("Create profile") {
                            if library.add(name: name, symbol: symbol) { library.select(library.profiles.last!); finish() }
                            else { error = "Enter a unique name, up to 32 characters." }
                        }.buttonStyle(.borderedProminent).controlSize(.large)
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: min(3, library.profiles.count)), spacing: 24) {
                            ForEach(library.profiles) { profile in
                                Button { library.select(profile); finish() } label: {
                                    VStack(spacing: 12) {
                                        ProfileAvatar(symbol: profile.symbol, selected: library.active.id == profile.id, image: profile.avatarImage)
                                        Text(profile.name).font(.subheadline.bold()).foregroundStyle(.primary).lineLimit(2)
                                    }
                                }.buttonStyle(.plain).accessibilityIdentifier("profileChoice")
                            }
                        }
                        Button { creating = true } label: { Label("Add profile", systemImage: "plus.circle") }.buttonStyle(.bordered)
                    }
                }.padding(24)
            }.background(AnimeTheme.background).toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button(creating ? "Cancel" : "Done") { if creating { creating = false } else { finish() } } }
            }
        }.tint(AnimeTheme.accent).preferredColorScheme(.dark)
    }
    private func finish() { if let onComplete { onComplete() } else { dismiss() } }
}

struct SettingsScreen: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var account: SyncAccount
    @EnvironmentObject private var sync: LibrarySync
    let showProfiles: () -> Void
    let play: (PlaybackRequest) -> Void
    @State private var streamURL = ""
    @State private var invalidURL = false
    @State private var showingAccount = false
    @State private var accountError: String?
    @State private var confirmingImport = false
    @AppStorage("subtitleLanguage") private var subtitleLanguage = "en"
    @AppStorage("autoNextEpisode") private var autoNextEpisode = false
    var body: some View {
        Form {
            if account.auth != nil {
                Section("Stream Anime account") {
                    if let email = account.email {
                        Text(email)
                        Text(sync.status).font(.footnote).foregroundStyle(.secondary)
                        Button("Sync now") {
                            if let id = account.userID { Task { await sync.sync(library: library, userID: id) } }
                        }
                        Button("Copy guest profiles and history") { confirmingImport = true }
                        Button("Sign out", role: .destructive) {
                            do { try account.signOut() }
                            catch { accountError = error.localizedDescription }
                        }
                    } else {
                        Button("Sign in or create account") { showingAccount = true }
                    }
                    if let accountError { Text(accountError).foregroundStyle(.red) }
                }
            }
            Section("Your profile") {
                HStack(spacing: 16) {
                    ProfileAvatar(symbol: library.active.symbol, size: 62, image: library.active.avatarImage)
                    VStack(alignment: .leading, spacing: 5) { Text(library.active.name).font(.title3.bold()); Text("Local profile").font(.caption).foregroundStyle(.secondary) }
                }.padding(.vertical, 8)
                Button { showProfiles() } label: { Label(library.active.name, systemImage: library.active.symbol) }
                Text("Watch history is saved separately for each profile on this iPhone.").font(.footnote).foregroundStyle(.secondary)
                if let error = library.storageError { Text(error).foregroundStyle(.red) }
            }
            Section("Playback") {
                Picker("Subtitle language", selection: $subtitleLanguage) {
                    Text("English").tag("en"); Text("Arabic").tag("ar"); Text("Spanish").tag("es")
                    Text("French").tag("fr"); Text("German").tag("de"); Text("Portuguese").tag("pt"); Text("Off").tag("off")
                    if !["en", "ar", "es", "fr", "de", "pt", "off"].contains(subtitleLanguage) { Text(subtitleLanguage.uppercased()).tag(subtitleLanguage) }
                }
                Toggle("Play next episode automatically", isOn: $autoNextEpisode)
                Text("The player remembers caption changes across episodes. Streams are ranked by quality, with recently failed sources tried later.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Stream sources") {
                Label("ZokoAnime", systemImage: "play.rectangle")
                Label("AniKoto · two gateway routes", systemImage: "arrow.triangle.branch")
                Text("Only subtitled streams with matching episode identities are accepted. Availability depends on each source.").font(.footnote).foregroundStyle(.secondary)
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
                LabeledContent("Version", value: "0.3 · Mobile preview")
                Text("Structured seasons, episode previews, separate profiles, and native playback. Crunchyroll import and cross-device sync are not available yet.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.scrollContentBackground(.hidden).background(AnimeTheme.background).navigationTitle("Account").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingAccount) { SyncAccountScreen() }
            .confirmationDialog("Copy guest profiles to this account?", isPresented: $confirmingImport) {
                Button("Copy profiles and history") {
                    library.importGuestProfiles()
                    if let id = account.userID { Task { await sync.sync(library: library, userID: id) } }
                }
            } message: { Text("The copied profiles and watch history will be available on devices signed into this account.") }
            .alert("Use an HTTPS address", isPresented: $invalidURL) {
                Button("OK", role: .cancel) {}
            } message: { Text("Enter the full HTTPS stream URL.") }
    }
}
