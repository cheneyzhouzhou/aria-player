import SwiftUI

/// Grid of playlists, with a cover collaged from the first few tracks.
struct PlaylistListView: View {
    let playlists: [Playlist]

    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var playlistStore: PlaylistStore
    @EnvironmentObject var nav: Navigator
    @EnvironmentObject private var dialogs: DialogCenter
    @Environment(\.palette) private var palette

    @State private var newName = ""
    @State private var showingNew = false
    /// The playlist being renamed, held here rather than in the card: an alert
    /// presented from the card right after its context menu closes is dropped.
    @State private var renaming: Playlist?
    @State private var draftName = ""


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
                        Label(L("New playlist"), systemImage: "plus")
                    }
                    .buttonStyle(PillButtonStyle(
                        kind: .tonal, palette: palette,
                        padding: EdgeInsets(top: 9, leading: 18, bottom: 9, trailing: 18)))

                    Button {
                        // Always asks which folder, even when the library only
                        // holds one: the step makes the source explicit, and a
                        // button that sometimes imports and sometimes asks was
                        // indistinguishable from a dead button.
                        if library.sources.isEmpty {
                            dialogs.showNote(L("No library folder yet."))
                        } else {
                            dialogs.showsImportPicker = true
                        }
                    } label: {
                        Label(L("Import folders"), systemImage: "folder.badge.plus")
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PillButtonStyle(
                        kind: .tonal, palette: palette,
                        padding: EdgeInsets(top: 9, leading: 16, bottom: 9, trailing: 16)))

                    Spacer()
                }

                if let note = dialogs.note {
                    Text(note)
                        .font(.body(11))
                        .foregroundStyle(palette.onSurfaceVariant)
                        .transition(.opacity)
                        .padding(.top, -6)
                }

                if playlists.isEmpty {
                    VStack(spacing: 8) {
                        Text(L("No playlists yet"))
                            .font(.body(14, .medium))
                            .foregroundStyle(palette.onSurface)
                        Text(L("“Import folders” makes one playlist per top-level folder in your library."))
                            .font(.body(12))
                            .foregroundStyle(palette.onSurfaceVariant)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    LazyVGrid(columns: columns, spacing: 26) {
                        ForEach(playlists) { list in
                            PlaylistCard(playlist: list, onRename: { target in
                                draftName = target.name
                                // Let the menu finish closing first.
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { renaming = target }
                            }, onDelete: { target in
                                // A playlist holds hand-picked tracks, so the
                                // delete asks once before it goes.
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                    dialogs.confirm(
                                        title: L("Delete playlist"),
                                        message: L("“%@” will be deleted. This can’t be undone.")
                                            .replacingOccurrences(of: "%@", with: target.name),
                                        confirmTitle: L("Delete")
                                    ) { playlistStore.delete(target) }
                                }
                            })
                        }
                    }
                    .alert(L("Rename playlist"),
                           isPresented: Binding(get: { renaming != nil },
                                                set: { if !$0 { renaming = nil } })) {
                        TextField(L("Name"), text: $draftName)
                        Button(L("Cancel"), role: .cancel) { renaming = nil }
                        Button(L("Save")) {
                            let name = draftName.trimmingCharacters(in: .whitespaces)
                            if let target = renaming, !name.isEmpty, name != target.name {
                                playlistStore.rename(target, to: name)
                            }
                            renaming = nil
                        }
                    }
                }
            }
            .padding(.horizontal, screenInset)
            .padding(.top, 4)
            .padding(.bottom, playerClearance)

        }
        .scrollContentBackground(.hidden)
        .alert(L("New playlist"), isPresented: $showingNew) {
            TextField(L("Name"), text: $newName)
            Button(L("Cancel"), role: .cancel) { newName = "" }
            Button(L("Create")) {
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
    /// Asked the list to show the rename alert for this playlist.
    var onRename: (Playlist) -> Void = { _ in }
    /// Asked the list to confirm deleting this playlist.
    var onDelete: (Playlist) -> Void = { _ in }

    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var playlistStore: PlaylistStore
    /// Not `@EnvironmentObject`: the card only ever calls `playAll`, and
    /// observing the player would rebuild it on every playhead tick — the
    /// context menu anchored to it then drops item taps.
    @Environment(\.playerHandle) private var player
    @EnvironmentObject var nav: Navigator
    @Environment(\.palette) private var palette
    @State private var isHovering = false

    private var tracks: [Track] {
        playlistStore.tracks(in: playlist, library: library.tracks, root: library.rootPath)
    }

    /// Runs a context-menu action on the next runloop turn, so the menu is gone
    /// before the card's data changes.
    private func runLater(_ work: @escaping () -> Void) {
        DispatchQueue.main.async(execute: work)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                PlaylistMosaic(tracks: tracks, palette: palette)
                    .aspectRatio(1, contentMode: .fit)

                if !tracks.isEmpty {
                    Button {
                        player?.playAll(tracks)
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
            Text(Lplural(tracks.count, "song"))
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
            // Each item lets the menu close first: running the work inline keeps
            // the popup on screen while the row changes underneath it, and the
            // next tap lands nowhere.
            Button(L("Play")) { runLater { player?.playAll(tracks) } }
            Button(L("Shuffle")) { runLater { player?.playAll(tracks, shuffled: true) } }
            Divider()
            Button(L("Rename playlist")) { onRename(playlist) }
            Divider()
            Button(L("Delete"), role: .destructive) { onDelete(playlist) }
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
        for track in tracks where track.hasArtwork {
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
    /// Same reason as the card: only `playAll` and `shuffle` are needed here.
    @Environment(\.playerHandle) private var player
    @EnvironmentObject var nav: Navigator
    @Environment(\.palette) private var palette

    @State private var renaming = false
    @State private var draftName = ""

    private var tracks: [Track] {
        playlistStore.tracks(in: playlist, library: library.tracks, root: library.rootPath)
    }

    /// Runs a context-menu action on the next runloop turn, so the menu is gone
    /// before the card's data changes.
    private func runLater(_ work: @escaping () -> Void) {
        DispatchQueue.main.async(execute: work)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                LazyVStack(spacing: 4) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        // One closure, two menus: the row's ⋯ button and its
                        // long-press menu have to show the same actions.
                        let removeFromPlaylist: () -> Void = {
                            playlistStore.remove(track, from: playlist, root: library.rootPath)
                        }

                        TrackRow(track: track, context: tracks, trackNumber: index + 1,
                                 onRemoveFromPlaylist: removeFromPlaylist)
                            .contextMenu {
                                TrackMenu(track: track, context: tracks)
                                Divider()
                                Button(L("Remove from playlist"), role: .destructive,
                                       action: removeFromPlaylist)
                            }
                    }
                }
            }
            .padding(.horizontal, screenInset)
            .padding(.top, 6)
            .padding(.bottom, playerClearance)
        }
        .scrollContentBackground(.hidden)
        .alert(L("Rename playlist"), isPresented: $renaming) {
            TextField(L("Name"), text: $draftName)
            Button(L("Cancel"), role: .cancel) {}
            Button(L("Save")) {
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

            Text(Lplural(tracks.count, "song") + " · "
                 + Lduration(tracks.reduce(0) { $0 + $1.duration }))
                .font(.body(12))
                .foregroundStyle(palette.onSurfaceVariant)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button { player?.playAll(tracks) } label: {
                Label(L("Play"), systemImage: "play.fill")
            }
            .buttonStyle(PillButtonStyle(kind: .filled, palette: palette))

            Button { player?.playAll(tracks, shuffled: true) } label: {
                Label(L("Shuffle"), systemImage: "shuffle")
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
