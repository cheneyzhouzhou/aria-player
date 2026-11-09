import SwiftUI
import UniformTypeIdentifiers

// MARK: - Navigation

enum Route: Hashable {
    case album(Album)
    case artist(Artist)
    case playlist(Playlist)
}

@MainActor
final class Navigator: ObservableObject {
    /// Pages pushed on top of the tab's own list, innermost first.
    ///
    /// A single `route` could not express "artist → one of that artist's
    /// albums": opening the album replaced the artist page, so going back
    /// dropped straight to the library instead of the artist. Keeping the
    /// whole stack makes back mean "one step", wherever the user came from.
    @Published private(set) var stack: [Route] = []

    /// The page on screen, or `nil` when a tab's list is showing.
    var route: Route? { stack.last }

    /// True when there is a page to go back from.
    var canGoBack: Bool { !stack.isEmpty }

    func open(_ route: Route) {
        withAnimation(.snappy(duration: 0.3)) { stack.append(route) }
    }

    func back() {
        guard !stack.isEmpty else { return }
        withAnimation(.snappy(duration: 0.3)) { stack.removeLast() }
    }

    /// Leaving the tab — or switching library tabs — drops everything, not just
    /// the page on top.
    func reset() {
        guard !stack.isEmpty else { return }
        withAnimation(.snappy(duration: 0.3)) { stack.removeAll() }
    }
}

enum RailDestination: String, CaseIterable {
    case library, search, settings

    var title: String {
        switch self {
        case .library: return L("Library")
        case .search: return L("Search")
        case .settings: return L("Settings")
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
        case .songs: return L("Songs")
        case .albums: return L("Albums")
        case .artists: return L("Artists")
        case .playlists: return L("Playlists")
        case .recent: return L("Recent")
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
    @ObservedObject private var appearance = AppearanceSettings.shared
    @State private var showNowPlaying = false

    /// The chrome's own colour, independent of what's playing.
    private var chrome: M3Palette {
        themePalette(seed: palettes.librarySeed, isDark: scheme == .dark)
    }

    /// Opening an album re-tints the whole window from its cover.
    private var active: M3Palette {
        if case .album(let album) = nav.route,
           let seed = palettes.seed(for: album.id, artwork: album.artworkTrack) {
            return themePalette(seed: seed, isDark: scheme == .dark)
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
            AppBackground(active).ignoresSafeArea()

            HStack(spacing: AppearanceSettings.shared.usesGlass ? 16 : 0) {
                rail
                mainColumn
            }
            // Glass theme: the rail and the content column become two separate
            // glass panels floating inside a padded window over the aurora —
            // the segmented, elevated look of the reference. The solid theme
            // keeps its flush, single-column layout.
            .padding(AppearanceSettings.shared.usesGlass ? 16 : 0)
            .ignoresSafeArea(edges: .top)

            if player.current != nil {
                // The floating bar sits on the themed window, so in Morandi it
                // takes the theme palette instead of the artwork's — otherwise
                // a vivid slab floats on a greige page. The full-screen stage
                // keeps its artwork colour either way.
                MiniPlayer(palette: AppearanceSettings.shared.usesMorandi ? active : nowPlayingPalette) {
                    withAnimation(.easeOut(duration: 0.26)) {
                        showNowPlaying = true
                    }
                }
                .padding(.horizontal, AppearanceSettings.shared.usesGlass ? 16 : 22)
                .padding(.bottom, AppearanceSettings.shared.usesGlass ? 16 : 18)
                .padding(.leading, AppearanceSettings.shared.usesGlass ? 124 : 92)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if showNowPlaying {
                NowPlayingView(palette: nowPlayingPalette) {
                    withAnimation(.easeOut(duration: 0.26)) {
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
        .onChange(of: destination) { _, _ in nav.reset() }
        .onChange(of: tab) { _, _ in nav.reset() }
    }

    // MARK: Rail

    private var rail: some View {
        VStack(spacing: 14) {
            // Clears the hidden title bar's traffic lights when the rail runs
            // flush to the window top; the floating glass panel is inset, so it
            // needs less headroom.
            Spacer().frame(height: AppearanceSettings.shared.usesGlass ? 14 : 40)

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
        .background {
            if AppearanceSettings.shared.usesGlass {
                GlassSurface(shape: RoundedRectangle(cornerRadius: 22, style: .continuous),
                             tint: active.surfaceContainer, border: active.outline,
                             radius: 22, strong: true)
            } else {
                active.surface
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AppearanceSettings.shared.usesGlass ? 22 : 0,
                                    style: .continuous))
        .shadow(color: AppearanceSettings.shared.usesGlass ? .black.opacity(0.18) : .clear,
                radius: 22, y: 10)
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
                case .settings: SettingsView(palette: active, drawsBackdrop: false)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A single rounded glass container behind every tab (library, search,
        // settings); its sections are separate glass cards on top.
        .background {
            if AppearanceSettings.shared.usesGlass {
                GlassSurface(shape: RoundedRectangle(cornerRadius: 22, style: .continuous),
                             tint: active.surfaceContainer, border: active.outline,
                             radius: 22, strong: true)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AppearanceSettings.shared.usesGlass ? 22 : 0,
                                    style: .continuous))
        .shadow(color: AppearanceSettings.shared.usesGlass ? .black.opacity(0.18) : .clear,
                radius: 24, y: 12)
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
                Text(L("Library"))
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
            Text(L("Nothing here yet"))
                .font(.display(26, .semibold))
                .foregroundStyle(palette.onSurface)
            Text(hint)
                .font(.body(12))
                .foregroundStyle(palette.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 34)

            VStack(spacing: 8) {
                Button(L("Add folder")) { addFolder() }
                    .buttonStyle(PillButtonStyle(kind: .tonal, palette: palette))
                Button(L("Rescan")) { Task { await library.scan() } }
                    .buttonStyle(PillButtonStyle(kind: .text, palette: palette, size: 13,
                                                 padding: EdgeInsets(top: 4, leading: 10,
                                                                     bottom: 4, trailing: 10)))
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The sandbox path is UUID soup on iOS; say what to do instead.
    private var hint: String {
        #if os(macOS)
        library.rootPath
        #else
        L("No music files in your music folders yet. Add the folder they live in — On My iPhone, iCloud Drive, or anywhere the Files app can reach. Aria reads FLAC, ALAC, MP3, AAC, WAV or AIFF.")
        #endif
    }

    private func addFolder() {
        #if os(iOS)
        FolderPicker.present(startingAt: library.pickerStartDirectory) { folder in
            if library.addPrepared(folder) {
                Task { await library.scan() }
            }
        }
        #else
        Platform.chooseFolder(startingAt: library.rootPath) { path in
            Task {
                await library.addSource(URL(fileURLWithPath: path))
                await library.scan()
            }
        }
        #endif
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
            Text(L("Search"))
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
                Text(L("Find something to play"))
                    .font(.body(14))
                    .foregroundStyle(palette.onSurfaceVariant)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else if results.isEmpty {
                Spacer()
                Text(Lmatch(query))
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
