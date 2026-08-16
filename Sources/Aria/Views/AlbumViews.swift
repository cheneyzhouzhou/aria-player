import SwiftUI

// MARK: - Albums grid

struct AlbumGridView: View {
    let albums: [Album]

    @Environment(\.palette) private var palette
    /// A 393pt phone fits two columns only below ~150pt per tile.
    private var columns: [GridItem] {
        #if os(iOS)
        [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 14)]
        #else
        [GridItem(.adaptive(minimum: 168, maximum: 210), spacing: 24)]
        #endif
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 26) {
                ForEach(albums) { album in
                    AlbumCard(album: album)
                }
            }
            .padding(.horizontal, screenInset)
            .padding(.top, 4)
            .padding(.bottom, playerClearance)
        }
        .scrollContentBackground(.hidden)
    }
}

struct AlbumCard: View {
    let album: Album

    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var nav: Navigator
    @Environment(\.palette) private var palette
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                CoverArt(track: album.artworkTrack, cacheKey: album.id,
                         radius: Radius.card, palette: palette)
                    .aspectRatio(1, contentMode: .fit)

                // Material's small FAB, revealed on hover.
                Button {
                    player.playAll(album.tracks)
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
            .scaleEffect(isHovering ? 1.02 : 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.body(13.5, .semibold))
                    .foregroundStyle(palette.onSurface)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(album.artist)
                    .font(.body(11.5))
                    .foregroundStyle(palette.onSurfaceVariant)
                    .lineLimit(1)
            }
            .frame(height: 48, alignment: .topLeading)
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onTapGesture { nav.open(.album(album)) }
        .onHover { isHovering = $0 }
        .animation(.snappy(duration: 0.22), value: isHovering)
    }
}

// MARK: - Album detail

struct AlbumDetailView: View {
    let album: Album

    @EnvironmentObject var player: AudioPlayer
    @Environment(\.palette) private var palette

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                LazyVStack(spacing: 4) {
                    ForEach(Array(album.tracks.enumerated()), id: \.element.id) { index, track in
                        TrackRow(track: track, context: album.tracks,
                                 trackNumber: track.trackNumber > 0 ? track.trackNumber : index + 1)
                    }
                }
            }
            .padding(.horizontal, screenInset)
            .padding(.top, 6)
            .padding(.bottom, playerClearance)
        }
        .scrollContentBackground(.hidden)
    }

    /// Side-by-side on a Mac; stacked on a phone, where a 200pt cover plus a
    /// column of text simply doesn't fit across 393 points.
    @ViewBuilder
    private var header: some View {
        #if os(iOS)
        VStack(alignment: .leading, spacing: 14) {
            cover(size: 200)
                .frame(maxWidth: .infinity, alignment: .center)
            titleBlock
            actions
        }
        #else
        HStack(alignment: .bottom, spacing: 26) {
            cover(size: 200)
            VStack(alignment: .leading, spacing: 10) {
                titleBlock
                actions.padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        #endif
    }

    private func cover(size: CGFloat) -> some View {
        CoverArt(track: album.artworkTrack, cacheKey: album.id,
                 radius: Radius.sheet, palette: palette)
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.28), radius: 22, y: 10)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(album.title)
                .font(.display(28, .semibold))
                .foregroundStyle(palette.onSurface)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            Text(album.artist)
                .font(.body(15, .medium))
                .foregroundStyle(palette.primary)

            Text([album.year, plural(album.tracks.count, "song"),
                  formatDurationLong(album.duration),
                  album.tracks.first?.qualityLabel ?? ""]
                    .filter { !$0.isEmpty }
                    .joined(separator: "  ·  "))
                .font(.body(12))
                .foregroundStyle(palette.onSurfaceVariant)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button { player.playAll(album.tracks) } label: {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(PillButtonStyle(kind: .filled, palette: palette))

            Button { player.playAll(album.tracks, shuffled: true) } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
            .buttonStyle(PillButtonStyle(kind: .tonal, palette: palette))
        }
    }
}

// MARK: - Artists

struct ArtistListView: View {
    let artists: [Artist]

    @Environment(\.palette) private var palette

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(artists) { artist in
                    ArtistRow(artist: artist)
                }
            }
            .padding(.horizontal, screenInset)
            .padding(.bottom, playerClearance)
        }
        .scrollContentBackground(.hidden)
    }
}

private struct ArtistRow: View {
    let artist: Artist

    @EnvironmentObject var nav: Navigator
    @Environment(\.palette) private var palette
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 14) {
            CoverArt(track: artist.albums.first?.artworkTrack,
                     cacheKey: artist.albums.first?.id ?? artist.name,
                     radius: 26, palette: palette)
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 2) {
                Text(artist.name)
                    .font(.body(14, .semibold))
                    .foregroundStyle(palette.onSurface)
                    .lineLimit(1)
                Text(plural(artist.albums.count, "album") + " · " + plural(artist.trackCount, "song"))
                    .font(.body(12))
                    .foregroundStyle(palette.onSurfaceVariant)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.onSurfaceVariant)
                .offset(x: isHovering ? 3 : 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(isHovering ? palette.surfaceContainer : .clear)
        }
        .contentShape(Rectangle())
        .onTapGesture { nav.open(.artist(artist)) }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovering)
    }
}

struct ArtistDetailView: View {
    let artist: Artist

    @EnvironmentObject var player: AudioPlayer
    @Environment(\.palette) private var palette

    /// A 393pt phone fits two columns only below ~150pt per tile.
    private var columns: [GridItem] {
        #if os(iOS)
        [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 14)]
        #else
        [GridItem(.adaptive(minimum: 168, maximum: 210), spacing: 24)]
        #endif
    }
    private var allTracks: [Track] { artist.albums.flatMap(\.tracks) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // Name beside the buttons where there's room, stacked when not.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .bottom) {
                        artistTitle
                        Spacer()
                        artistActions
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        artistTitle
                        artistActions
                    }
                }

                LazyVGrid(columns: columns, spacing: 26) {
                    ForEach(artist.albums) { album in
                        AlbumCard(album: album)
                    }
                }
            }
            .padding(.horizontal, screenInset)
            .padding(.top, 6)
            .padding(.bottom, playerClearance)
        }
        .scrollContentBackground(.hidden)
    }

    private var artistTitle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(artist.name)
                .font(.display(30, .semibold))
                .foregroundStyle(palette.onSurface)
                .fixedSize(horizontal: false, vertical: true)
            Text(plural(artist.albums.count, "album") + " · " + plural(artist.trackCount, "song"))
                .font(.body(12))
                .foregroundStyle(palette.onSurfaceVariant)
        }
    }

    private var artistActions: some View {
        HStack(spacing: 10) {
            Button { player.playAll(allTracks) } label: {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(PillButtonStyle(kind: .filled, palette: palette))

            Button { player.playAll(allTracks, shuffled: true) } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
            .buttonStyle(PillButtonStyle(kind: .tonal, palette: palette))
        }
    }
}
