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

    @EnvironmentObject var player: AudioPlayer
    @Environment(\.palette) private var palette

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                if !tracks.isEmpty {
                    HStack(spacing: 10) {
                        Button {
                            player.playAll(tracks, shuffled: true)
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                        }
                        .buttonStyle(PillButtonStyle(
                            kind: .tonal, palette: palette,
                            padding: EdgeInsets(top: 9, leading: 18, bottom: 9, trailing: 18)))

                        Text(plural(tracks.count, "song"))
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
    }
}

struct TrackRow: View {
    let track: Track
    let context: [Track]
    var trackNumber: Int? = nil

    @EnvironmentObject var player: AudioPlayer
    @Environment(\.palette) private var palette
    @State private var isHovering = false

    private var isCurrent: Bool { player.current?.id == track.id }

    var body: some View {
        HStack(spacing: 14) {
            if let trackNumber {
                ZStack {
                    if isCurrent {
                        PlayingIndicator(animating: player.isPlaying, color: palette.primary)
                    } else {
                        Text("\(trackNumber)")
                            .font(.ticker(12))
                            .foregroundStyle(palette.onSurfaceVariant)
                    }
                }
                .frame(width: 26)
            } else {
                ZStack(alignment: .bottomTrailing) {
                    CoverArt(track: track, cacheKey: track.albumKey,
                             radius: Radius.thumb, palette: palette)
                        .frame(width: 50, height: 50)
                    if isCurrent {
                        PlayingIndicator(animating: player.isPlaying, color: palette.onPrimary)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(palette.primary))
                            .offset(x: 5, y: 5)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body(14, isCurrent ? .semibold : .medium))
                    .foregroundStyle(isCurrent ? palette.primary : palette.onSurface)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.body(12))
                    .foregroundStyle(palette.onSurfaceVariant)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            Text(formatTime(track.duration))
                .font(.ticker(12))
                .foregroundStyle(palette.onSurfaceVariant)

            Menu {
                TrackMenu(track: track, context: context)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.onSurfaceVariant)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            #if os(macOS)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            #endif
            .frame(width: 30)
            .opacity(isHovering ? 1 : 0.35)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(isCurrent ? palette.primaryContainer.opacity(0.55)
                                : (isHovering ? palette.surfaceContainer : .clear))
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        // A touchscreen expects one tap; double-click is the desktop idiom.
        #if os(iOS)
        .onTapGesture { player.play(track, in: context) }
        #else
        .onTapGesture(count: 2) { player.play(track, in: context) }
        #endif
        .animation(.easeOut(duration: 0.14), value: isHovering)
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
        Button("Play") { player.play(track, in: context) }
        Button("Play album") {
            player.play(track, in: context.filter { $0.albumKey == track.albumKey })
        }
        Divider()
        if Platform.canRevealInFileManager {
            Button("Reveal in Finder") { Platform.reveal(track.url) }
        }
        Button("Copy title") { Platform.copyToPasteboard(track.title) }

        if !playlistStore.playlists.isEmpty {
            Divider()
            Menu("Add to playlist") {
                ForEach(playlistStore.playlists) { list in
                    Button(list.name) {
                        playlistStore.add(track, to: list, root: library.rootPath)
                    }
                }
            }
        }
    }
}
