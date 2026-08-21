import SwiftUI

/// Grid of playlists, with a cover collaged from the first few tracks.
struct PlaylistListView: View {
    let playlists: [Playlist]

    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var playlistStore: PlaylistStore
    @EnvironmentObject var nav: Navigator
    @Environment(\.palette) private var palette

    @State private var newName = ""
    @State private var showingNew = false

    private var columns: [GridItem] {
        #if os(iOS)
        [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 14)]
        #else
        [GridItem(.adaptive(minimum: 168, maximum: 210), spacing: 24)]
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Button {
                        showingNew = true
                    } label: {
                        Label("New playlist", systemImage: "plus")
                    }
                    .buttonStyle(PillButtonStyle(
                        kind: .tonal, palette: palette,
                        padding: EdgeInsets(top: 9, leading: 18, bottom: 9, trailing: 18)))

                    Button {
                        let added = playlistStore.importFolders(from: library.tracks, root: library.rootPath)
                        if added == 0 { /* nothing new to add */ }
                    } label: {
                        Label("Import folders", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(PillButtonStyle(
                        kind: .text, palette: palette,
                        padding: EdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 12)))

                    Spacer()
                }

                if playlists.isEmpty {
                    VStack(spacing: 8) {
                        Text("No playlists yet")
                            .font(.body(14, .medium))
                            .foregroundStyle(palette.onSurface)
                        Text("“Import folders” makes one playlist per top-level folder in your library.")
                            .font(.body(12))
                            .foregroundStyle(palette.onSurfaceVariant)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    LazyVGrid(columns: columns, spacing: 26) {
                        ForEach(playlists) { list in
                            PlaylistCard(playlist: list)
                        }
                    }
                }
            }
            .padding(.horizontal, screenInset)
            .padding(.top, 4)
            .padding(.bottom, playerClearance)
        }
        .scrollContentBackground(.hidden)
        .alert("New playlist", isPresented: $showingNew) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { newName = "" }
            Button("Create") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    playlistStore.create(named: name, root: library.rootPath)
                }
                newName = ""
            }
        }
    }
}

struct PlaylistCard: View {
    let playlist: Playlist

    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var playlistStore: PlaylistStore
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var nav: Navigator
    @Environment(\.palette) private var palette
    @State private var isHovering = false

    private var tracks: [Track] {
        playlistStore.tracks(in: playlist, library: library.tracks, root: library.rootPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                PlaylistMosaic(tracks: tracks, palette: palette)
                    .aspectRatio(1, contentMode: .fit)

                if !tracks.isEmpty {
                    Button {
                        player.playAll(tracks)
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(palette.onPrimary)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(palette.primary))
                            .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                    .opacity(isHovering ? 1 : 0)
                    .scaleEffect(isHovering ? 1 : 0.75)
                }
            }
            .scaleEffect(isHovering ? 1.02 : 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.body(13.5, .semibold))
                    .foregroundStyle(palette.onSurface)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(plural(tracks.count, "song"))
                    .font(.body(11.5))
                    .foregroundStyle(palette.onSurfaceVariant)
            }
            .frame(height: 48, alignment: .topLeading)
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onTapGesture { nav.open(.playlist(playlist)) }
        .onHover { isHovering = $0 }
        .animation(.snappy(duration: 0.22), value: isHovering)
        .contextMenu {
            Button("Play") { player.playAll(tracks) }
            Button("Shuffle") { player.playAll(tracks, shuffled: true) }
            Divider()
            Button("Delete", role: .destructive) { playlistStore.delete(playlist) }
        }
    }
}

/// Four covers in a grid, or one if that's all there is.
struct PlaylistMosaic: View {
    let tracks: [Track]
    let palette: M3Palette

    private var covers: [Track] {
        var seen = Set<String>()
        var out: [Track] = []
        for track in tracks where track.artRange != nil {
            if seen.insert(track.albumKey).inserted { out.append(track) }
            if out.count == 4 { break }
        }
        return out
    }

    var body: some View {
        GeometryReader { geo in
            let side = geo.size.width
            ZStack {
                if covers.isEmpty {
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .fill(palette.surfaceContainerHigh)
                        .overlay {
                            Image(systemName: "music.note.list")
                                .font(.system(size: side * 0.22, weight: .light))
                                .foregroundStyle(palette.onSurfaceVariant.opacity(0.7))
                        }
                } else if covers.count < 4 {
                    CoverArt(track: covers[0], cacheKey: covers[0].albumKey,
                             radius: Radius.card, palette: palette)
                } else {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            quarter(covers[0], side)
                            quarter(covers[1], side)
                        }
                        HStack(spacing: 0) {
                            quarter(covers[2], side)
                            quarter(covers[3], side)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                }
            }
            .frame(width: side, height: side)
        }
    }

    private func quarter(_ track: Track, _ side: CGFloat) -> some View {
        CoverArt(track: track, cacheKey: track.albumKey, radius: 0, palette: palette)
            .frame(width: side / 2, height: side / 2)
    }
}

// MARK: - Detail

struct PlaylistDetailView: View {
    let playlist: Playlist

    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var playlistStore: PlaylistStore
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var nav: Navigator
    @Environment(\.palette) private var palette

    @State private var renaming = false
    @State private var draftName = ""

    private var tracks: [Track] {
        playlistStore.tracks(in: playlist, library: library.tracks, root: library.rootPath)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                LazyVStack(spacing: 4) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        TrackRow(track: track, context: tracks, trackNumber: index + 1)
                            .contextMenu {
                                TrackMenu(track: track, context: tracks)
                                Divider()
                                Button("Remove from playlist", role: .destructive) {
                                    playlistStore.remove(track, from: playlist, root: library.rootPath)
                                }
                            }
                    }
                }
            }
            .padding(.horizontal, screenInset)
            .padding(.top, 6)
            .padding(.bottom, playerClearance)
        }
        .scrollContentBackground(.hidden)
        .alert("Rename playlist", isPresented: $renaming) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let name = draftName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { playlistStore.rename(playlist, to: name) }
            }
        }
    }

    /// Side by side on a Mac, stacked on a phone — 170pt of artwork plus a
    /// column of text and buttons does not fit across a phone's width.
    @ViewBuilder
    private var header: some View {
        #if os(iOS)
        VStack(alignment: .leading, spacing: 14) {
            mosaic(size: 190)
                .frame(maxWidth: .infinity, alignment: .center)
            titleBlock
            actions
        }
        #else
        HStack(alignment: .bottom, spacing: 22) {
            mosaic(size: 170)
            VStack(alignment: .leading, spacing: 9) {
                titleBlock
                actions.padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        #endif
    }

    private func mosaic(size: CGFloat) -> some View {
        PlaylistMosaic(tracks: tracks, palette: palette)
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.28), radius: 20, y: 9)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(playlistStore.current(playlist).name)
                .font(.display(28, .semibold))
                .foregroundStyle(palette.onSurface)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(plural(tracks.count, "song") + " · "
                 + formatDurationLong(tracks.reduce(0) { $0 + $1.duration }))
                .font(.body(12))
                .foregroundStyle(palette.onSurfaceVariant)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button { player.playAll(tracks) } label: {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(PillButtonStyle(kind: .filled, palette: palette))

            Button { player.playAll(tracks, shuffled: true) } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
            .buttonStyle(PillButtonStyle(kind: .tonal, palette: palette))

            Button {
                draftName = playlistStore.current(playlist).name
                renaming = true
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(PillButtonStyle(
                kind: .text, palette: palette,
                padding: EdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 12)))
        }
        // Without this the pills stretch to fill any spare height they are offered.
        .fixedSize(horizontal: false, vertical: true)
        .disabled(tracks.isEmpty)
    }
}
