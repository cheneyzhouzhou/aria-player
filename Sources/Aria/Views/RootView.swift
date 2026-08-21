import SwiftUI

// MARK: - Navigation

enum Route: Hashable {
    case album(Album)
    case artist(Artist)
    case playlist(Playlist)
}

@MainActor
final class Navigator: ObservableObject {
    @Published var route: Route?

    func open(_ route: Route) {
        withAnimation(.snappy(duration: 0.3)) { self.route = route }
    }

    func back() {
        withAnimation(.snappy(duration: 0.3)) { route = nil }
    }
}

enum RailDestination: String, CaseIterable {
    case library, search, settings

    var title: String {
        switch self {
        case .library: return "Library"
        case .search: return "Search"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .library: return "square.stack.fill"
        case .search: return "magnifyingglass"
        case .settings: return "gearshape.fill"
        }
    }
}

enum LibraryTab: String, CaseIterable {
    case songs, albums, artists, playlists, recent

    var title: String {
        switch self {
        case .songs: return "Songs"
        case .albums: return "Albums"
        case .artists: return "Artists"
        case .playlists: return "Playlists"
        case .recent: return "Recent"
        }
    }
}

// MARK: - Root

struct RootView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var palettes: PaletteStore
    @EnvironmentObject var playlistStore: PlaylistStore
    @StateObject private var nav = Navigator()
    @Environment(\.colorScheme) private var scheme

    @State private var destination: RailDestination = .library
    @State private var tab: LibraryTab = .albums
    @State private var search = ""
    @State private var showNowPlaying = false

    /// The chrome's own colour, independent of what's playing.
    private var chrome: M3Palette {
        M3Palette(seed: palettes.librarySeed, isDark: scheme == .dark)
    }

    /// Opening an album re-tints the whole window from its cover.
    private var active: M3Palette {
        if case .album(let album) = nav.route,
           let seed = palettes.seed(for: album.id, artwork: album.artworkTrack) {
            return M3Palette(seed: seed, isDark: scheme == .dark)
        }
        return chrome
    }

    private var nowPlayingPalette: M3Palette {
        guard let track = player.current,
              let seed = palettes.seed(for: track.albumKey, artwork: track) else {
            return M3Palette(seed: palettes.librarySeed, isDark: scheme == .dark, vivid: true)
        }
        return M3Palette(seed: seed, isDark: scheme == .dark, vivid: true)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            active.surface.ignoresSafeArea()

            HStack(spacing: 0) {
                rail
                mainColumn
            }

            if player.current != nil {
                MiniPlayer(palette: nowPlayingPalette) {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                        showNowPlaying = true
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 18)
                .padding(.leading, 92)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if showNowPlaying {
                NowPlayingView(palette: nowPlayingPalette) {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                        showNowPlaying = false
                    }
                }
                .transition(.move(edge: .bottom))
                .zIndex(10)
            }
        }
        .environmentObject(nav)
        .environment(\.palette, active)
        .animation(.easeInOut(duration: 0.45), value: active)
        .animation(.spring(response: 0.4, dampingFraction: 0.9), value: player.current)
        .onChange(of: destination) { _, _ in nav.back() }
        .onChange(of: tab) { _, _ in nav.back() }
    }

    // MARK: Rail

    private var rail: some View {
        VStack(spacing: 14) {
            // Clears the hidden title bar's traffic lights.
            Spacer().frame(height: 40)

            ForEach(RailDestination.allCases, id: \.self) { item in
                RailItem(system: item.icon, title: item.title,
                         isSelected: destination == item, palette: active) {
                    withAnimation(.snappy(duration: 0.25)) { destination = item }
                }
            }

            Spacer()

            if library.isScanning {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                    .padding(.bottom, 22)
            }
        }
        .frame(width: 92)
        .background(active.surface)
    }

    // MARK: Main column

    private var mainColumn: some View {
        VStack(spacing: 0) {
            if library.tracks.isEmpty && !library.isScanning {
                EmptyLibraryView(palette: active)
            } else if let route = nav.route {
                detail(route)
            } else {
                switch destination {
                case .library: libraryScreen
                case .search: SearchScreen(query: $search, palette: active)
                case .settings: SettingsView(palette: active)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func detail(_ route: Route) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                IconButton(system: "arrow.left", size: 40, glyph: 15,
                           fill: active.surfaceContainer, foreground: active.onSurface) {
                    nav.back()
                }
                Spacer()
            }
            .padding(.horizontal, 26)
            .padding(.top, 40)
            .padding(.bottom, 4)

            switch route {
            case .album(let album): AlbumDetailView(album: album)
            case .artist(let artist): ArtistDetailView(artist: artist)
            case .playlist(let list): PlaylistDetailView(playlist: list)
            }
        }
    }

    private var libraryScreen: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text("Library")
                    .font(.display(40, .semibold))
                    .foregroundStyle(active.onSurface)
                Spacer()
                SearchPill(text: $search, palette: active, width: 280)
            }
            .padding(.horizontal, 30)
            .padding(.top, 40)
            .padding(.bottom, 18)

            HStack(spacing: 10) {
                ForEach(LibraryTab.allCases, id: \.self) { item in
                    FilterChip(title: item.title, isSelected: tab == item, palette: active) {
                        withAnimation(.snappy(duration: 0.25)) { tab = item }
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 16)

            Group {
                switch tab {
                case .songs:
                    SongListView(tracks: filtered(library.tracks))
                case .albums:
                    AlbumGridView(albums: filteredAlbums)
                case .artists:
                    ArtistListView(artists: filteredArtists)
                case .playlists:
                    PlaylistListView(playlists: playlistStore.playlists)
                case .recent:
                    SongListView(tracks: filtered(library.tracks).sorted { $0.dateAdded > $1.dateAdded })
                }
            }
        }
    }

    // MARK: Filtering

    private var query: String {
        search.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private func filtered(_ tracks: [Track]) -> [Track] {
        let matches = query.isEmpty ? tracks : tracks.filter {
            $0.title.lowercased().contains(query)
                || $0.artist.lowercased().contains(query)
                || $0.album.lowercased().contains(query)
        }
        return matches.sorted { $0.title.lowercased() < $1.title.lowercased() }
    }

    private var filteredAlbums: [Album] {
        guard !query.isEmpty else { return library.albums }
        return library.albums.filter { album in
            album.title.lowercased().contains(query)
                || album.artist.lowercased().contains(query)
                || album.tracks.contains { $0.title.lowercased().contains(query) }
        }
    }

    private var filteredArtists: [Artist] {
        guard !query.isEmpty else { return library.artists }
        return library.artists.filter { $0.name.lowercased().contains(query) }
    }
}

// MARK: - Empty state

struct EmptyLibraryView: View {
    let palette: M3Palette
    @EnvironmentObject var library: LibraryStore

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note.list")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(palette.onSurfaceVariant)
            Text("Nothing here yet")
                .font(.display(26, .semibold))
                .foregroundStyle(palette.onSurface)
            Text(hint)
                .font(.body(12))
                .foregroundStyle(palette.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 34)

            HStack(spacing: 12) {
                // Picking a folder is macOS-only; on iOS the library is always
                // the app's Documents folder, so the button would do nothing.
                if Platform.supportsFolderPicker {
                    Button("Choose folder") { chooseFolder() }
                        .buttonStyle(PillButtonStyle(kind: .filled, palette: palette))
                    Button("Rescan") { Task { await library.scan() } }
                        .buttonStyle(PillButtonStyle(kind: .tonal, palette: palette))
                } else {
                    Button("Rescan") { Task { await library.scan() } }
                        .buttonStyle(PillButtonStyle(kind: .filled, palette: palette))
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The sandbox path is UUID soup on iOS; say what to do instead.
    private var hint: String {
        Platform.supportsFolderPicker
            ? library.rootPath
            : "Plug your iPhone in, then drag FLAC files into Aria under Finder \u{25B8} your iPhone \u{25B8} Files. Then tap Rescan."
    }

    private func chooseFolder() {
        Platform.chooseFolder(startingAt: library.rootPath) { path in
            library.rootPath = path
            Task { await library.scan() }
        }
    }
}

// MARK: - Search screen

struct SearchScreen: View {
    @Binding var query: String
    let palette: M3Palette

    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var player: AudioPlayer

    private var results: [Track] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return library.tracks.filter {
            $0.title.lowercased().contains(q)
                || $0.artist.lowercased().contains(q)
                || $0.album.lowercased().contains(q)
        }
        .sorted { $0.title.lowercased() < $1.title.lowercased() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Search")
                .font(.display(40, .semibold))
                .foregroundStyle(palette.onSurface)
                .padding(.horizontal, 30)
                .padding(.top, 40)
                .padding(.bottom, 18)

            SearchPill(text: $query, palette: palette, width: nil)
                .padding(.horizontal, 30)
                .padding(.bottom, 18)

            if query.isEmpty {
                Spacer()
                Text("Find something to play")
                    .font(.body(14))
                    .foregroundStyle(palette.onSurfaceVariant)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else if results.isEmpty {
                Spacer()
                Text("No matches for “\(query)”")
                    .font(.body(14))
                    .foregroundStyle(palette.onSurfaceVariant)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                SongListView(tracks: results)
            }
        }
    }
}
