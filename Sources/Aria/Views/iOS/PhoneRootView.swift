#if os(iOS)
import SwiftUI

/// Phone layout: the same Material surfaces as the Mac, rearranged around a
/// floating nav bar and mini player the way the design was meant to be used.
struct PhoneRootView: View {
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

    private var chrome: M3Palette {
        M3Palette(seed: palettes.librarySeed, isDark: scheme == .dark)
    }

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

            content

            VStack(spacing: 10) {
                if player.current != nil {
                    PhoneMiniPlayer(palette: nowPlayingPalette) {
                        showNowPlaying = true
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                PhoneNavBar(destination: $destination, palette: active)
            }
            .padding(.horizontal, 14)
        }
        .environmentObject(nav)
        .environment(\.palette, active)
        .animation(.easeInOut(duration: 0.45), value: active)
        .animation(.spring(response: 0.4, dampingFraction: 0.9), value: player.current)
        .onChange(of: destination) { _, _ in nav.back() }
        .onChange(of: tab) { _, _ in nav.back() }
        .fullScreenCover(isPresented: $showNowPlaying) {
            PhoneNowPlayingView(palette: nowPlayingPalette) { showNowPlaying = false }
                .environmentObject(player)
        }
    }

    @ViewBuilder
    private var content: some View {
        if library.tracks.isEmpty && !library.isScanning {
            EmptyLibraryView(palette: active)
        } else if let route = nav.route {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    IconButton(system: "arrow.left", size: 40, glyph: 15,
                               fill: active.surfaceContainer, foreground: active.onSurface) {
                        nav.back()
                    }
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 2)

                switch route {
                case .album(let album): AlbumDetailView(album: album)
                case .artist(let artist): ArtistDetailView(artist: artist)
                case .playlist(let list): PlaylistDetailView(playlist: list)
                }
            }
        } else {
            switch destination {
            case .library: libraryScreen
            case .search: SearchScreen(query: $search, palette: active)
            case .settings: SettingsView(palette: active)
            }
        }
    }

    private var libraryScreen: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Library")
                .font(.display(34, .semibold))
                .foregroundStyle(active.onSurface)
                .padding(.horizontal, 22)
                .padding(.bottom, 14)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) {
                    ForEach(LibraryTab.allCases, id: \.self) { item in
                        FilterChip(title: item.title, isSelected: tab == item, palette: active) {
                            withAnimation(.snappy(duration: 0.25)) { tab = item }
                        }
                    }
                }
                .padding(.horizontal, 22)
            }
            .padding(.bottom, 12)

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
        }
    }

    private var filteredArtists: [Artist] {
        guard !query.isEmpty else { return library.artists }
        return library.artists.filter { $0.name.lowercased().contains(query) }
    }
}

// MARK: - Floating nav bar

struct PhoneNavBar: View {
    @Binding var destination: RailDestination
    let palette: M3Palette

    var body: some View {
        HStack(spacing: 4) {
            ForEach(RailDestination.allCases, id: \.self) { item in
                Button {
                    withAnimation(.snappy(duration: 0.25)) { destination = item }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: item.icon)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(destination == item
                                             ? palette.onPrimaryContainer : palette.onSurfaceVariant)
                            .frame(width: 58, height: 32)
                            .background {
                                Capsule().fill(destination == item
                                               ? palette.primaryContainer : .clear)
                            }
                        Text(item.title)
                            .font(.label(10.5, destination == item ? .semibold : .medium))
                            .foregroundStyle(destination == item
                                             ? palette.onSurface : palette.onSurfaceVariant)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(palette.surfaceContainer)
        }
    }
}

// MARK: - Mini player

struct PhoneMiniPlayer: View {
    let palette: M3Palette
    let onExpand: () -> Void

    @EnvironmentObject var player: AudioPlayer

    var body: some View {
        HStack(spacing: 11) {
            if let track = player.current {
                CoverArt(track: track, cacheKey: track.albumKey,
                         radius: Radius.thumb, palette: palette)
                    .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .font(.body(13, .semibold))
                        .foregroundStyle(palette.onSurface)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.body(11))
                        .foregroundStyle(palette.onSurfaceVariant)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(palette.onPrimary)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(palette.primary))
                }
                .buttonStyle(.plain)

                Button { player.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.onSurface)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(palette.surfaceContainerHigh))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background {
            Capsule().fill(palette.surfaceContainer)
                .shadow(color: .black.opacity(0.25), radius: 14, y: 5)
        }
        .contentShape(Capsule())
        .onTapGesture(perform: onExpand)
    }
}

// MARK: - Now playing

/// Full-screen player. Same parts as the Mac version, stacked for a phone.
struct PhoneNowPlayingView: View {
    let palette: M3Palette
    let onDismiss: () -> Void

    @EnvironmentObject var player: AudioPlayer
    @State private var scrubFraction: Double?
    @State private var showQueue = false
    @State private var showEQ = false

    private var shownTime: Double {
        if let scrubFraction { return scrubFraction * player.duration }
        return player.currentTime
    }

    var body: some View {
        ZStack {
            palette.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                Spacer(minLength: 8)

                if let track = player.current {
                    GeometryReader { geo in
                        CoverArt(track: track, cacheKey: track.albumKey,
                                 radius: 30, palette: palette)
                            .frame(width: geo.size.width, height: geo.size.width)
                            .shadow(color: .black.opacity(0.35), radius: 26, y: 12)
                    }
                    .aspectRatio(1, contentMode: .fit)
                    .padding(.horizontal, 34)

                    VStack(spacing: 5) {
                        Text(track.title)
                            .font(.display(23, .semibold))
                            .foregroundStyle(palette.onSurface)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                        Text(track.artist)
                            .font(.body(14, .medium))
                            .foregroundStyle(palette.onSurfaceVariant)
                            .lineLimit(1)
                    }
                    .padding(.top, 24)
                    .padding(.horizontal, 30)
                }

                scrubber.padding(.top, 22)
                transport.padding(.top, 20)
                secondaryRow.padding(.top, 16)

                Spacer(minLength: 10)
            }
            .padding(.bottom, 16)
        }
        .sheet(isPresented: $showQueue) {
            QueueList(palette: palette)
                .environmentObject(player)
                .presentationDetents([.medium, .large])
                .presentationBackground(palette.surfaceContainer)
        }
        .sheet(isPresented: $showEQ) {
            EqualizerView(palette: palette) { showEQ = false }
                .environmentObject(player)
                .presentationDetents([.large])
                .presentationBackground(palette.surface)
        }
    }

    private var header: some View {
        HStack {
            IconButton(system: "chevron.down", size: 40, glyph: 15,
                       fill: palette.surfaceContainer, foreground: palette.onSurface,
                       action: onDismiss)
            Spacer()
            Text("Now Playing")
                .font(.label(12.5, .semibold))
                .foregroundStyle(palette.onSurfaceVariant)
            Spacer()
            IconButton(system: "list.bullet", size: 40, glyph: 15,
                       fill: palette.surfaceContainer, foreground: palette.onSurface) {
                showQueue = true
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
    }

    private var scrubber: some View {
        VStack(spacing: 4) {
            MascotScrubber(
                progress: player.duration > 0 ? shownTime / player.duration : 0,
                isAnimating: player.isPlaying,
                height: 54, mascotSize: 38, trackWidth: 5,
                activeColor: palette.primary,
                inactiveColor: palette.onSurfaceVariant.opacity(0.3),
                inkColor: palette.onPrimary,
                onScrub: { scrubFraction = $0 },
                onCommit: {
                    player.seek(to: $0 * player.duration)
                    scrubFraction = nil
                }
            )

            HStack {
                Text(formatTime(shownTime))
                Spacer()
                Text(formatTime(player.duration))
            }
            .font(.ticker(11.5))
            .foregroundStyle(palette.onSurfaceVariant)
        }
        .padding(.horizontal, 34)
    }

    private var transport: some View {
        HStack(spacing: 10) {
            Button { player.previous() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(palette.onPrimaryContainer)
                    .frame(width: 84, height: 60)
                    .background(RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(palette.primaryContainer.opacity(0.6)))
            }
            .buttonStyle(.plain)

            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(palette.onPrimary)
                    .frame(width: 96, height: 70)
                    .background(RoundedRectangle(cornerRadius: player.isPlaying ? 24 : 35,
                                                 style: .continuous)
                        .fill(palette.primary))
            }
            .buttonStyle(.plain)
            .animation(.spring(response: 0.32, dampingFraction: 0.7), value: player.isPlaying)

            Button { player.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(palette.onPrimaryContainer)
                    .frame(width: 84, height: 60)
                    .background(RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(palette.primaryContainer.opacity(0.6)))
            }
            .buttonStyle(.plain)
        }
    }

    private var secondaryRow: some View {
        HStack(spacing: 10) {
            chip(system: "shuffle", isOn: player.isShuffled) { player.isShuffled.toggle() }
            chip(system: player.repeatMode.symbol, isOn: player.repeatMode != .off) {
                switch player.repeatMode {
                case .off: player.repeatMode = .all
                case .all: player.repeatMode = .one
                case .one: player.repeatMode = .off
                }
            }
            chip(system: "slider.vertical.3", isOn: player.eqEnabled) { showEQ = true }
        }
    }

    private func chip(system: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isOn ? palette.onPrimary : palette.onSurfaceVariant)
                .frame(width: 66, height: 42)
                .background(Capsule().fill(isOn ? palette.primary : palette.surfaceContainerHigh))
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.2), value: isOn)
    }
}
#endif
