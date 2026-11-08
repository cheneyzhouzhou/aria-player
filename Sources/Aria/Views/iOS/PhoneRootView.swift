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
    /// How far the page has been dragged sideways. It exists so the content
    /// follows the finger: without it a swipe that ends one point short of the
    /// threshold looks like a dead gesture.
    @State private var swipeOffset: CGFloat = 0
    /// How far the detail page has been pulled to the right by an edge swipe.
    @State private var backSwipeOffset: CGFloat = 0

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
            AppBackground(active).ignoresSafeArea()

            // One rounded glass container behind every tab, floating over the
            // aurora inside a small inset — the reference's segmented layout.
            content
                .background {
                    if AppearanceSettings.shared.usesGlass {
                        GlassSurface(shape: RoundedRectangle(cornerRadius: 26, style: .continuous),
                                     tint: active.surfaceContainer, border: active.outline,
                                     radius: 26, strong: true)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: AppearanceSettings.shared.usesGlass ? 26 : 0,
                                            style: .continuous))
                .padding(.horizontal, AppearanceSettings.shared.usesGlass ? 10 : 0)
                .padding(.top, AppearanceSettings.shared.usesGlass ? 6 : 0)
                // Native-style edge swipe back: a thin strip along the left
                // edge owns the gesture (a plain gesture on the page would be
                // swallowed by the list's ScrollView). The whole page follows
                // the finger; album, artist and playlist detail all use it.
                .overlay(alignment: .leading) {
                    if nav.route != nil {
                        Color.clear
                            .frame(width: 18)
                            .contentShape(Rectangle())
                            .highPriorityGesture(backSwipe)
                    }
                }
                .offset(x: nav.route != nil ? backSwipeOffset : 0)

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
        if let route = nav.route {
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
            case .library:
                // The empty state belongs to the library, not to the whole app:
                // Settings and Search have to stay reachable with no music yet.
                if library.tracks.isEmpty && library.isScanning {
                    scanningScreen
                } else if library.tracks.isEmpty {
                    EmptyLibraryView(palette: active)
                } else {
                    libraryScreen
                }
            case .search: SearchScreen(query: $search, palette: active)
            case .settings: SettingsView(palette: active, drawsBackdrop: false)
            }
        }
    }

    /// A first scan of a large folder takes a while; say so rather than
    /// showing an empty library that looks like a failure.
    private var scanningScreen: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text(L("Scanning your music folders…"))
                .font(.body(12))
                .foregroundStyle(active.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var libraryScreen: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("Library"))
                .font(.display(34, .semibold))
                .foregroundStyle(active.onSurface)
                .padding(.horizontal, 22)
                .padding(.bottom, 14)

            // A swipe can land on a chip that is scrolled off the edge, so the
            // row follows the selection rather than staying where it was.
            ScrollViewReader { chips in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 9) {
                        ForEach(LibraryTab.allCases, id: \.self) { item in
                            FilterChip(title: item.title, isSelected: tab == item, palette: active) {
                                withAnimation(.snappy(duration: 0.25)) { tab = item }
                            }
                            .id(item)
                        }
                    }
                    .padding(.horizontal, 22)
                }
                .onChange(of: tab) { _, now in
                    withAnimation(.snappy(duration: 0.25)) { chips.scrollTo(now, anchor: .center) }
                }
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
            .offset(x: swipeOffset)
            .simultaneousGesture(tabSwipe)
        }
    }

    // MARK: Swipe between tabs

    private var tabIndex: Int {
        LibraryTab.allCases.firstIndex(of: tab) ?? 0
    }

    /// Horizontal only: the lists underneath scroll vertically all day, and a
    /// vertical flick that happens to drift sideways must not change the tab.
    private var tabSwipe: some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > abs(dy) * 1.4 else { return }
                // Rubber-band at the ends, so the first and last tab still
                // answer the finger instead of feeling broken.
                let atStart = tabIndex == 0 && dx > 0
                let atEnd = tabIndex == LibraryTab.allCases.count - 1 && dx < 0
                swipeOffset = atStart || atEnd ? dx * 0.16 : dx * 0.5
            }
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                let flick = value.predictedEndTranslation.width
                defer {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        swipeOffset = 0
                    }
                }
                guard abs(dx) > abs(dy) * 1.2 else { return }

                let next = dx < 0 ? tabIndex + 1 : tabIndex - 1
                let passed = abs(dx) > 56 || abs(flick) > 130
                guard passed, LibraryTab.allCases.indices.contains(next) else { return }
                // No animation on the switch itself: the page is already
                // sitting where the finger left it, and the spring above
                // carries it back into place.
                tab = LibraryTab.allCases[next]
            }
    }

    // MARK: Swipe back from the left edge

    /// Native-style back gesture for the detail pages (album / artist /
    /// playlist). It only engages when the drag starts within the left edge and
    /// is mostly horizontal, so the vertical lists and any horizontal content
    /// underneath keep working. The page follows the finger and pops when the
    /// travel (or flick) passes the threshold, otherwise springs back.
    private var backSwipe: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard nav.route != nil, value.startLocation.x < 28 else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                guard dx > 0, abs(dx) > abs(dy) * 1.2 else { return }
                backSwipeOffset = dx
            }
            .onEnded { value in
                guard nav.route != nil, value.startLocation.x < 28 else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                let flick = value.predictedEndTranslation.width
                let passed = abs(dx) > abs(dy) * 1.2
                    && (dx > 90 || (dx > 30 && flick > 160))
                if passed {
                    // Popping swaps the content out; zero the offset first so the
                    // library never inherits a shifted page.
                    backSwipeOffset = 0
                    nav.back()
                } else {
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                        backSwipeOffset = 0
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
            SurfaceRole.panel.background(palette,
                shape: AnyShape(RoundedRectangle(cornerRadius: 30, style: .continuous)),
                radius: 30, strong: true)
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
            SurfaceRole.panel.background(palette,
                shape: AnyShape(Capsule()), radius: 999, strong: true)
        }
        .contentShape(Capsule())
        .shadow(color: .black.opacity(0.25), radius: 14, y: 5)
        .onTapGesture(perform: onExpand)
    }
}

// MARK: - Now playing

/// Full-screen player. Same parts as the Mac version, stacked for a phone.
struct PhoneNowPlayingView: View {
    let palette: M3Palette
    let onDismiss: () -> Void

    @EnvironmentObject var player: AudioPlayer
    @StateObject private var backdrop = PhoneStageBackdrop()
    @State private var scrubFraction: Double?
    @State private var showQueue = false
    @State private var showEQ = false
    @State private var showAudioChain = false
    /// Tapping the cover swaps in the lyrics; tapping again swaps back.
    @State private var showLyrics = false
    /// Vertical offset while the player is being pulled down to dismiss it,
    /// so the full-screen cover behaves like the sheets it hosts.
    @State private var dismissDrag: CGFloat = 0

    /// Trial: when the processed cover fills the page, the foreground switches
    /// to white — the same treatment the macOS stage uses. Before the bitmap is
    /// ready (or when a track has no artwork) the original palette colours stay.
    private var onStage: Bool { backdrop.image != nil }
    /// A stage texture is now always available: real artwork when the track
    /// has it, the bundled default cover otherwise. Keeping this true for every
    /// track holds the neutral dark base in place until the texture arrives, so
    /// neither opening the player nor changing tracks flashes the light
    /// surface.
    private var expectsBackdrop: Bool { player.current?.hasArtwork == true || DefaultCover.isAvailable }
    private var titleColor: Color {
        onStage ? Color(red: 0.95, green: 0.92, blue: 0.88) : palette.onSurface
    }
    private var secondaryColor: Color {
        onStage ? Color.white.opacity(0.72) : palette.onSurfaceVariant
    }
    private var buttonFill: Color {
        onStage ? Color.white.opacity(0.24) : palette.surfaceContainer
    }
    private var chipFill: Color {
        onStage ? Color.white.opacity(0.22) : palette.surfaceContainerHigh
    }

    /// Both player states use muted controls. On the artwork backdrop the
    /// `vivid: true` accent and pure-white glyphs read as loud patches, so they
    /// become a warm, low-saturation tint. With no artwork the page is a plain
    /// light/dark surface, and that same vivid accent would be a heavy dark
    /// blue blob — so it is diluted with opacity instead. Opacity keeps the
    /// colours tied to the active theme and works in both appearance modes.
    /// Neutral control fill used by the transport's previous and next buttons.
    /// The play button instead uses the cover-hued `coverAccent`, so it reads as
    /// the hero control while the skips stay quiet.
    private var stageAccentSoft: Color {
        onStage ? Color.white.opacity(0.14)
                : palette.primary.opacity(0.12)
    }
    private var stageOnAccentSoft: Color {
        onStage ? Color.white.opacity(0.82)
                : palette.onSurface.opacity(0.58)
    }

    /// Accent pulled from the *cover* and muted: low saturation, mid brightness.
    /// The played progress bar, the mascot and the "on" highlights (EQ, shuffle,
    /// repeat) tint with whatever sleeve is playing instead of a fixed warm
    /// beige, so they harmonise with the blurred artwork behind them. Held back
    /// from full brightness so it reads as a calm wash over the dark, scrimmed
    /// backdrop rather than a glowing bar.
    private var coverAccent: Color {
        Color(hue: palette.seed.hue, saturation: 0.20, brightness: 0.78)
    }
    /// Dark companion of the same hue for the mascot's pupils/mouth and the
    /// glyphs sitting on a `coverAccent` fill — keeps contrast inside the
    /// cover's colour family rather than snapping to brown.
    private var coverAccentOn: Color {
        Color(hue: palette.seed.hue, saturation: 0.32, brightness: 0.20)
    }
    /// Eye whites for the mascot: pure-ish white reads cleanly against the
    /// light pastel head.
    private var mascotEye: Color { Color.white.opacity(0.9) }

    private var shownTime: Double {
        if let scrubFraction { return scrubFraction * player.duration }
        return player.currentTime
    }

    var body: some View {
        ZStack {
            // A neutral dark base for tracks with artwork: the texture covers
            // it completely once ready, but this keeps the frame before it
            // arrives (opening the player, or replacing it on a track change)
            // from showing the light surface as a bright flash.
            Group {
                if expectsBackdrop {
                    Color(white: 0.12)
                } else {
                    AppBackground(palette)
                }
            }
            .ignoresSafeArea()

            // The processed cover sits under everything and is dimmed so the
            // white foreground stays legible, exactly like the desktop stage.
            if let image = backdrop.image {
                Image(platformImage: image)
                    .resizable(resizingMode: .stretch)
                    .interpolation(.high)
                    .overlay(Color.black.opacity(StageBackdropFilter.scrim))
                    .ignoresSafeArea()
                    .transition(.opacity)
            }

            VStack(spacing: 0) {
                header

                Spacer(minLength: 8)

                if let track = player.current {
                    Group {
                        if showLyrics {
                            LyricsPane(track: track, currentTime: player.currentTime,
                                       palette: palette,
                                       onTap: {
                                           withAnimation(.snappy(duration: 0.28)) { showLyrics = false }
                                       },
                                       // Never draw a standalone card: lyrics
                                       // sit on the player background whether
                                       // the track has artwork or not.
                                       showsPanel: false,
                                       primaryColor: titleColor,
                                       secondaryColor: secondaryColor,
                                       accentColor: coverAccent)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .transition(.opacity)
                        } else {
                            CoverArt(track: track, cacheKey: track.albumKey,
                                     radius: 30, palette: palette,
                                     // Tracks without their own sleeve fall
                                     // back to the bundled default cover, so the
                                     // player shows the same rounded rectangle
                                     // either way — no second display path.
                                     fallback: track.hasArtwork ? nil : DefaultCover.image)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .shadow(color: .black.opacity(0.35), radius: 26, y: 12)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(.snappy(duration: 0.28)) { showLyrics = true }
                                }
                                .transition(.opacity)
                        }
                    }
                    // Both states live in one square whose side is derived from
                    // the *width* (minus the horizontal inset), never from the
                    // content. Insetting on the *outside* of the aspect-ratio
                    // is what keeps the square — and therefore the scrubber,
                    // title and transport below it — identical whether the
                    // middle shows the cover or the lyrics. The earlier order
                    // (inset *inside* the aspect-ratio) let the cover's own
                    // size pull the square wider, dragging the progress bar and
                    // the top buttons toward the screen edges.
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                    .padding(.horizontal, 34)

                    VStack(spacing: 5) {
                        Text(track.title)
                            .font(.display(23, .semibold))
                            .foregroundStyle(titleColor)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                        Text(track.artist)
                            .font(.body(14, .medium))
                            .foregroundStyle(secondaryColor)
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

            // Dim the player while a popup is open. The popups offer both a
            // half-height and a full-height detent; without this, the gap under
            // a half-height card would show a bright band of the cover.
            if showQueue || showEQ || showAudioChain {
                Color.black.opacity(0.38)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .onAppear { backdrop.load(for: player.current) }
        .animation(.easeInOut(duration: 0.22), value: showQueue)
        .animation(.easeInOut(duration: 0.22), value: showEQ)
        .animation(.easeInOut(duration: 0.22), value: showAudioChain)
        .onChange(of: player.current?.albumKey) { _, _ in
            // No withAnimation here: the backdrop swaps in one atomic update
            // once the new texture is ready, and an animated empty state would
            // show the light surface underneath as a bright flash.
            backdrop.load(for: player.current)
        }
        // A fullScreenCover has no built-in swipe-to-dismiss (unlike the
        // sheets above). Follow the finger and close on a long pull or a
        // quick flick; everything else springs back.
        .offset(y: max(0, dismissDrag))
        .gesture(
            DragGesture(minimumDistance: 24)
                .onChanged { value in
                    let height = value.translation.height
                    let width = value.translation.width
                    guard height > 0, height > abs(width) * 1.2 else { return }
                    dismissDrag = height
                }
                .onEnded { value in
                    let height = value.translation.height
                    let predicted = value.predictedEndTranslation.height
                    if height > 140 || predicted > 240 {
                        dismissDrag = 0
                        onDismiss()
                    } else {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                            dismissDrag = 0
                        }
                    }
                }
        )
        .sheet(isPresented: $showQueue) {
            // The queue draws its own full-bleed frost inside the sheet: it
            // fills the sheet (no rows spilling below a shorter panel) and keeps
            // the same frosted glass as the other player popups.
            QueueList(palette: playerOverlayPalette(palette), background: .fullBleedGlass)
                .environmentObject(player)
                .environment(\.colorScheme, .dark)
                // Reach under the home indicator so the glass fills the whole
                // sheet; otherwise a bare light strip shows at the bottom.
                .ignoresSafeArea(edges: .bottom)
                // Half or full height. The player is dimmed underneath, so the
                // half-height card doesn't sit over a bright band.
                .presentationDetents([.medium, .large])
                .presentationBackground(.clear)
        }
        .sheet(isPresented: $showEQ) {
            EqualizerView(palette: playerOverlayPalette(palette)) { showEQ = false }
                .environmentObject(player)
                .ignoresSafeArea(edges: .bottom)
                .presentationDetents([.medium, .large])
                .presentationBackground(.clear)
        }
        .sheet(isPresented: $showAudioChain) {
            AudioChainView(palette: playerOverlayPalette(palette)) { showAudioChain = false }
                .environmentObject(player)
                .ignoresSafeArea(edges: .bottom)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.clear)
        }
    }

    private var header: some View {
        HStack {
            IconButton(system: "chevron.down", size: 40, glyph: 15,
                       fill: buttonFill,
                       foreground: onStage ? Color.white.opacity(0.9) : palette.onSurface,
                       action: onDismiss)
            Spacer()
            Text(L("Now Playing"))
                .font(.label(12.5, .semibold))
                .foregroundStyle(secondaryColor)
            Spacer()
            IconButton(system: "slider.vertical.3", size: 40, glyph: 15,
                       fill: player.eqEnabled ? coverAccent : buttonFill,
                       foreground: player.eqEnabled
                           ? coverAccentOn
                           : (onStage ? Color.white.opacity(0.9) : palette.onSurface)) {
                showEQ = true
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
                activeColor: coverAccent,
                inactiveColor: onStage
                    ? Color.white.opacity(0.24)
                    : palette.onSurfaceVariant.opacity(0.3),
                inkColor: coverAccentOn,
                eyeColor: mascotEye,
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
            .foregroundStyle(secondaryColor)
        }
        .padding(.horizontal, 34)
    }

    private var transport: some View {
        HStack(spacing: 10) {
            Button { player.previous() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(stageOnAccentSoft)
                    .frame(width: 84, height: 60)
                    .background(RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(stageAccentSoft))
            }
            .buttonStyle(.plain)

            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(coverAccentOn)
                    .frame(width: 96, height: 70)
                    .background(RoundedRectangle(cornerRadius: player.isPlaying ? 24 : 35,
                                                 style: .continuous)
                        .fill(coverAccent))
            }
            .buttonStyle(.plain)
            .animation(.spring(response: 0.32, dampingFraction: 0.7), value: player.isPlaying)

            Button { player.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(stageOnAccentSoft)
                    .frame(width: 84, height: 60)
                    .background(RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(stageAccentSoft))
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
            chip(system: "list.bullet", isOn: false) { showQueue = true }
            chainChip
        }
    }

    /// Rightmost control in the bottom row. The dot reports the signal-chain
    /// verdict without needing to open the panel.
    private var chainChip: some View {
        let quality = player.audioChain.quality
        return Button { showAudioChain = true } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(secondaryColor)
                    .frame(width: 66, height: 42)
                    .background(Capsule().fill(chipFill))
                Circle()
                    .fill(quality.color)
                    .frame(width: 7, height: 7)
                    .offset(x: -12, y: 7)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("Audio chain") + ", " + L(quality.profile))
    }

    private func chip(system: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(isOn
                ? coverAccentOn
                : (onStage ? Color.white.opacity(0.82) : palette.onSurfaceVariant))
            .frame(width: 66, height: 42)
            .background(Capsule().fill(isOn ? coverAccent : chipFill))
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.2), value: isOn)
    }
}
#endif
