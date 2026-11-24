import SwiftUI

/// Screen margin: a phone can't spare the desktop's gutters.
#if os(iOS)
let screenInset: CGFloat = 20
#else
let screenInset: CGFloat = 30
#endif

/// Clearance so the floating mini player never covers the last row.
#if os(iOS)
let playerClearance: CGFloat = 180   // mini player + nav bar + home indicator
#else
let playerClearance: CGFloat = 108
#endif

struct SongListView: View {
    let tracks: [Track]

    /// See `TrackRow`: the list must not observe the playhead either, or it
    /// rebuilds every row several times a second.
    @Environment(\.playerHandle) private var player
    @Environment(\.palette) private var palette

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(spacing: 6) {
                if !tracks.isEmpty {
                    HStack(spacing: 10) {
                        Button {
                            player?.playAll(tracks, shuffled: true)
                        } label: {
                            Label(L("Shuffle"), systemImage: "shuffle")
                        }
                        .buttonStyle(PillButtonStyle(
                            kind: .tonal, palette: palette,
                            padding: EdgeInsets(top: 9, leading: 18, bottom: 9, trailing: 18)))

                        Text(Lplural(tracks.count, "song"))
                            .font(.label(12))
                            .foregroundStyle(palette.onSurfaceVariant)
                        Spacer()
                    }
                    .padding(.bottom, 4)
                }

                ForEach(tracks) { track in
                    TrackRow(track: track, context: tracks)
                }
            }
            .padding(.horizontal, screenInset)
            .padding(.bottom, playerClearance)
        }
        .scrollContentBackground(.hidden)
        .overlay(alignment: .bottomTrailing) {
            NowPlayingLocator(tracks: tracks, proxy: proxy)
                .padding(.trailing, screenInset + 4)
                #if os(iOS)
                .padding(.bottom, 178)  // clear of the floating mini player
                #else
                .padding(.bottom, 96)
                #endif
        }
        }
    }
}

struct TrackRow: View {
    let track: Track
    let context: [Track]
    var trackNumber: Int? = nil
    /// Set only on a playlist page. It puts "Remove from playlist" in *both*
    /// menus — the ⋯ button and the long-press one — so the two can't drift
    /// apart again.
    var onRemoveFromPlaylist: (() -> Void)? = nil

    /// Deliberately not an `@EnvironmentObject`. The playhead publishes every
    /// 0.15 s while audio plays; a row that observed it would be rebuilt six or
    /// seven times a second, and the ⋯ menu — a UIKit popup anchored to this
    /// view — would keep losing the first tap or two. The playhead-dependent
    /// bits live in the small leaves below instead.
    @Environment(\.playerHandle) private var player
    @Environment(\.palette) private var palette
    @EnvironmentObject private var playlistStore: PlaylistStore
    @EnvironmentObject private var library: LibraryStore
    @State private var isHovering = false
    #if os(iOS)
    @State private var actionsShown = false
    @State private var playlistsShown = false
    #endif

    var body: some View {
        HStack(spacing: 14) {
            // The tap target and the ⋯ menu are siblings, not parent and child.
            content
                .contentShape(Rectangle())
                // A touchscreen expects one tap; double-click is the desktop idiom.
                #if os(iOS)
                .onTapGesture {
                    player?.play(track, in: context)
                }
                #else
                .onTapGesture(count: 2) { player?.play(track, in: context) }
                #endif

            #if os(iOS)
            // A system action sheet instead of an anchored `Menu`.
            //
            // The popup was the last thing standing between a tap and its
            // effect: it is a UIKit menu anchored to a row inside a lazy stack,
            // it can take a few hundred milliseconds to appear, and a second
            // tap while it is arriving closes it again — which reads exactly
            // like "the tap did nothing". A sheet is presented by the system in
            // one step, so the first tap always lands somewhere.
            Button {
                actionsShown = true
            } label: {
                ellipsisIcon
            }
            .buttonStyle(.plain)
            .frame(width: 34)
            .confirmationDialog(L("Track"), isPresented: $actionsShown, titleVisibility: .hidden) {
                Button(L("Play")) {
                    runLater { player?.play(track, in: context) }
                }
                Button(L("Play album")) {
                    runLater {
                        player?.play(track, in: context.filter { $0.albumKey == track.albumKey })
                    }
                }
                Button(L("Copy title")) {
                    runLater { Platform.copyToPasteboard(track.title) }
                }
                if !playlistStore.playlists.isEmpty {
                    Button(L("Add to playlist")) {
                        // The second sheet has to wait for this one to go.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            playlistsShown = true
                        }
                    }
                }
                if let onRemoveFromPlaylist {
                    Button(L("Remove from playlist"), role: .destructive) {
                        runLater(onRemoveFromPlaylist)
                    }
                }
                Button(L("Cancel"), role: .cancel) {}
            }
            .confirmationDialog(L("Add to playlist"), isPresented: $playlistsShown, titleVisibility: .visible) {
                ForEach(playlistStore.playlists) { list in
                    Button(list.name) {
                        runLater { playlistStore.add(track, to: list, root: library.rootPath) }
                    }
                }
                Button(L("Cancel"), role: .cancel) {}
            }
            #else
            Menu {
                TrackMenu(track: track, context: context)
                if let onRemoveFromPlaylist {
                    Divider()
                    Button(L("Remove from playlist"), role: .destructive) {
                        runLater(onRemoveFromPlaylist)
                    }
                }
            } label: {
                ellipsisIcon
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 34)
            #endif
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background {
            RowFill(trackID: track.id, isHovering: isHovering, palette: palette)
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovering)
    }

    private var ellipsisIcon: some View {
        // Faded with the glyph's own colour rather than the view's `opacity`:
        // a view-level opacity also takes part in hit testing on iOS.
        Image(systemName: "ellipsis")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(palette.onSurfaceVariant.opacity(isHovering ? 1 : 0.35))
            .frame(width: 34, height: 34)
            .contentShape(Rectangle())
            // A 44pt finger target that costs no layout.
            .padding(5)
            .contentShape(Rectangle())
            .padding(-5)
    }

    /// Runs work on the next runloop turn, so the sheet can dismiss first.
    private func runLater(_ work: @escaping () -> Void) {
        DispatchQueue.main.async(execute: work)
    }

    /// Everything except the ⋯ menu: the number or the cover, titles, duration.
    private var content: some View {
        HStack(spacing: 14) {
            if let trackNumber {
                NumberOrBars(trackID: track.id, number: trackNumber, palette: palette)
            } else {
                ZStack(alignment: .bottomTrailing) {
                    CoverArt(track: track, cacheKey: track.albumKey,
                             radius: Radius.thumb, palette: palette)
                        .frame(width: 50, height: 50)
                    CoverPlayingBadge(trackID: track.id, palette: palette)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                NowPlayingTitle(trackID: track.id, title: track.title, palette: palette)
                Text(track.artist)
                    .font(.body(12))
                    .foregroundStyle(palette.onSurfaceVariant)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            Text(formatTime(track.duration))
                .font(.ticker(12))
                .foregroundStyle(palette.onSurfaceVariant)
        }
    }
}

// MARK: - Leaves that watch the playhead

/// The 26pt slot: a bar meter for the current track, the track number otherwise.
private struct NumberOrBars: View {
    let trackID: String
    let number: Int
    let palette: M3Palette

    @EnvironmentObject private var player: AudioPlayer

    var body: some View {
        ZStack {
            if player.current?.id == trackID {
                PlayingIndicator(animating: player.isPlaying, color: palette.primary)
            } else {
                Text("\(number)")
                    .font(.ticker(12))
                    .foregroundStyle(palette.onSurfaceVariant)
            }
        }
        .frame(width: 26)
    }
}

/// The little "now playing" dot on the artwork of the current row.
private struct CoverPlayingBadge: View {
    let trackID: String
    let palette: M3Palette

    @EnvironmentObject private var player: AudioPlayer

    var body: some View {
        Group {
            if player.current?.id == trackID {
                PlayingIndicator(animating: player.isPlaying, color: palette.onPrimary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(palette.primary))
                    .offset(x: 5, y: 5)
            }
        }
    }
}

/// Title in the accent colour while the row is the one playing.
private struct NowPlayingTitle: View {
    let trackID: String
    let title: String
    let palette: M3Palette

    @EnvironmentObject private var player: AudioPlayer

    var body: some View {
        let isCurrent = player.current?.id == trackID
        Text(title)
            .font(.body(14, isCurrent ? .semibold : .medium))
            .foregroundStyle(isCurrent ? palette.primary : palette.onSurface)
            .lineLimit(1)
    }
}

/// The row's selection wash.
private struct RowFill: View {
    let trackID: String
    let isHovering: Bool
    let palette: M3Palette

    @EnvironmentObject private var player: AudioPlayer

    var body: some View {
        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .fill(player.current?.id == trackID
                  ? palette.primaryContainer.opacity(0.55)
                  : (isHovering ? palette.surfaceContainer : .clear))
    }
}

/// Four bars that bounce while audio plays and hold a shape at rest.
struct PlayingIndicator: View {
    let animating: Bool
    var color: Color = .accentColor
    @State private var phase: CGFloat = 0

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 2.5, height: height(for: i))
            }
        }
        .frame(height: 16)
        .onAppear { start() }
        .onChange(of: animating) { _, _ in start() }
    }

    private func height(for index: Int) -> CGFloat {
        guard animating else { return [6, 11, 4, 8][index] }
        let offsets: [CGFloat] = [0, 0.8, 1.6, 2.4]
        return 4 + 9 * abs(sin(phase + offsets[index]))
    }

    private func start() {
        guard animating else { return }
        withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
            phase = .pi * 2
        }
    }
}

struct TrackMenu: View {
    let track: Track
    let context: [Track]

    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var playlistStore: PlaylistStore
    @EnvironmentObject var library: LibraryStore

    var body: some View {
        Button(L("Play")) {
            runLater { player.play(track, in: context) }
        }
        Button(L("Play album")) {
            runLater { player.play(track, in: context.filter { $0.albumKey == track.albumKey }) }
        }
        Divider()
        if Platform.canRevealInFileManager {
            Button(L("Reveal in Finder")) {
                runLater { Platform.reveal(track.url) }
            }
        }
        Button(L("Copy title")) {
            runLater { Platform.copyToPasteboard(track.title) }
        }

        if !playlistStore.playlists.isEmpty {
            Divider()
            Menu(L("Add to playlist")) {
                ForEach(playlistStore.playlists) { list in
                    Button(list.name) {
                        runLater { playlistStore.add(track, to: list, root: library.rootPath) }
                    }
                }
            }
        }
    }

    /// Runs a menu item's work on the next runloop turn.
    ///
    /// UIKit dismisses the popup only after the item's closure returns. Doing
    /// the work inline kept the menu on screen — looking interactive but
    /// swallowing the next tap — for however long playback took to start, which
    /// is why switching tracks *from the popup* needed several tries while the
    /// same track switched fine from the row. Returning immediately lets the
    /// dismissal start first.
    private func runLater(_ work: @escaping () -> Void) {
        DispatchQueue.main.async(execute: work)
    }
}
