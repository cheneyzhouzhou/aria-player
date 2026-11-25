#if os(iOS)
import SwiftUI
import UIKit

/// Phone layout: the same Material surfaces as the Mac, rearranged around a
/// floating nav bar and mini player the way the design was meant to be used.
struct PhoneRootView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var palettes: PaletteStore
    @EnvironmentObject var playlistStore: PlaylistStore
    @StateObject private var nav = Navigator()
    @Environment(\.colorScheme) private var scheme

    @ObservedObject private var appearance = AppearanceSettings.shared
    @State private var destination: RailDestination = .library
    @State private var tab: LibraryTab = .albums
    /// The library's own search term, exactly as on the desktop. It lives on
    /// the page it filters, so whatever is narrowing the list is visible there
    /// and can be cleared there.
    @State private var search = ""
    /// Plain boolean now: the iOS field is a UITextField that focuses itself.
    @State private var searchFocused = false
    @State private var showNowPlaying = false
    @Environment(\.scenePhase) private var scenePhase
    /// Set when the app goes away, so the return trip re-reads the folders:
    /// files can be deleted in the Files app or dropped in from Finder while
    /// Aria is in the background, and nothing else would notice.
    @State private var needsRescanOnReturn = false
    /// Last resolved colour for the mini player — see `refreshNowPlayingSeed`.
    @State private var nowPlayingSeed: PaletteSeed?
    /// How far the page has been dragged sideways. It exists so the content
    /// follows the finger: without it a swipe that ends one point short of the
    /// threshold looks like a dead gesture.
    @State private var swipeOffset: CGFloat = 0
    /// How far the detail page has been pulled to the right by an edge swipe.
    @State private var backSwipeOffset: CGFloat = 0

    private var chrome: M3Palette {
        themePalette(seed: palettes.librarySeed, isDark: scheme == .dark)
    }

    private var active: M3Palette {
        if case .album(let album) = nav.route,
           let seed = palettes.seed(for: album.id, artwork: album.artworkTrack) {
            return themePalette(seed: seed, isDark: scheme == .dark)
        }
        return chrome
    }

    private var nowPlayingPalette: M3Palette {
        M3Palette(seed: nowPlayingSeed ?? palettes.librarySeed,
                  isDark: scheme == .dark, vivid: true)
    }

    /// Seeds resolve off the main thread, so asking for one on the first visit
    /// to an album returns nothing for a moment. Painting the library colour
    /// during that gap is what made the floating bar flash on every track
    /// change — the buttons and (in the solid theme) the whole capsule jumped
    /// to an unrelated hue and then jumped back. Hold whatever is already on
    /// screen instead; the palette is animated, so the real colour arrives as
    /// a short crossfade.
    private func refreshNowPlayingSeed() {
        guard let track = player.current else { return }
        if let seed = palettes.seed(for: track.albumKey, artwork: track) {
            nowPlayingSeed = seed
        } else if !track.hasArtwork {
            // Nothing to extract here, so use the library colour on purpose
            // rather than holding the previous album's tint forever.
            nowPlayingSeed = palettes.librarySeed
        }
    }

    @EnvironmentObject private var dialogs: DialogCenter

    private var portraitRoot: some View {
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
                // The page runs all the way down and the floating bars sit on
                // top of it. Glass reads as glass because of what passes
                // *behind* it — covers and rows scrolling under the bars are
                // what the frost picks up, so shortening the page to make room
                // for them actually flattened the effect.
                // Swipe back from anywhere on the page, the same idea as the
                // player's pull-to-dismiss. This used to be an 18pt strip on
                // the left edge, which a normal swipe mostly missed.
                // `simultaneousGesture` leaves the detail lists scrolling
                // vertically as usual; `backSwipe` only claims the drag once it
                // is clearly horizontal and rightward.
                .offset(x: nav.route != nil ? backSwipeOffset : 0)
                // Only route events to it when a detail page is open: on the
                // library page it did nothing but compete with the rows for the
                // same touches — the ⋯ menu was the casualty.
                .simultaneousGesture(backSwipe, including: nav.route == nil ? .none : .all)

            VStack(spacing: 10) {
                if player.current != nil {
                    PhoneMiniPlayer(palette: AppearanceSettings.shared.usesMorandi ? active : nowPlayingPalette) {
                        showNowPlaying = true
                    }
                    // Crossfade the tint instead of snapping to it: a palette
                    // swap lands as a colour jump otherwise, which reads as the
                    // bar flashing.
                    .animation(.easeInOut(duration: 0.30), value: nowPlayingSeed)
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
        .onChange(of: player.current?.albumKey, initial: true) { _, _ in refreshNowPlayingSeed() }
        .onChange(of: palettes.revision) { _, _ in refreshNowPlayingSeed() }
        .onChange(of: destination) { _, _ in nav.reset() }
        .onChange(of: tab) { _, _ in nav.reset() }


        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                needsRescanOnReturn = true
            } else if phase == .active, needsRescanOnReturn {
                needsRescanOnReturn = false
                Task { await library.scan() }
            }
        }
        // Above the bars as well as the page: a question has to dim the whole
        // window, or it reads as a patch of black and the bar stays live.
        // The host sits outside the page's subtree, so the active palette has
        // to be handed to it explicitly.
        .overlay { DialogHost(center: dialogs).environment(\.palette, active) }
    }

    var body: some View {
        // Keep the presentation owner stable across rotations. Attaching the
        // full-screen cover directly to the geometry wrapper made a portrait
        // -> landscape switch tear the cover down for one frame and show the
        // library underneath before the player came back.
        ZStack {
            GeometryReader { geo in
                if geo.size.width > geo.size.height {
                    landscapeRoot
                } else {
                    portraitRoot
                }
            }

            // An in-window layer, not a system fullScreenCover: UIKit rebuilt
            // the presented controller on a portrait -> landscape switch and
            // for one frame exposed the library underneath. As a sibling of
            // the geometry branch this view is never torn down by rotation.
            if showNowPlaying {
                PhoneNowPlayingView(palette: nowPlayingPalette) { showNowPlaying = false }
                    .environmentObject(player)
                    .environmentObject(dialogs)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .zIndex(100)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.28), value: showNowPlaying)
        // Both orientations share the same environment, dialogs and player.
        .environmentObject(nav)
        .environment(\.palette, active)
        .animation(.easeInOut(duration: 0.45), value: active)
        .onChange(of: destination) { _, _ in nav.reset() }
        .onChange(of: tab) { _, _ in nav.reset() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                needsRescanOnReturn = true
            } else if phase == .active, needsRescanOnReturn {
                needsRescanOnReturn = false
                Task { await library.scan() }
            }
        }
        .overlay {
            DialogHost(center: dialogs)
                .environment(\.palette, active)
                // An empty host must not swallow touches meant for the page.
                .allowsHitTesting(dialogs.request != nil || dialogs.showsImportPicker)
        }
        .onChange(of: searchFocused) { _, active in
            guard !active else { return }
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                            to: nil, from: nil, for: nil)
        }
    }

    /// Landscape shell: the destinations become a vertical rail on the far
    /// left and the page occupies the space that is left, so nothing is
    /// covered by chrome. The mini player drops to the bottom edge because
    /// there is no bar underneath it any more.
    @ViewBuilder
    private var landscapeRoot: some View {
        ZStack(alignment: .bottom) {
            AppBackground(active).ignoresSafeArea()

            HStack(spacing: 0) {
                PhoneNavRail(destination: $destination, palette: active)
                    .frame(width: 84)

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
                    .padding(.trailing, 8)
                    .padding(.vertical, 6)
                    .offset(x: nav.route != nil ? backSwipeOffset : 0)
                    .simultaneousGesture(backSwipe, including: nav.route == nil ? .none : .all)
            }

            if player.current != nil {
                PhoneMiniPlayer(palette: AppearanceSettings.shared.usesMorandi ? active : nowPlayingPalette) {
                    showNowPlaying = true
                }
                .animation(.easeInOut(duration: 0.30), value: nowPlayingSeed)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.leading, 90)
                .padding(.trailing, 12)
                .padding(.bottom, 4)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.9), value: player.current)
        .onChange(of: player.current?.albumKey, initial: true) { _, _ in refreshNowPlayingSeed() }
        .onChange(of: palettes.revision) { _, _ in refreshNowPlayingSeed() }
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
                // In the glass theme this page is a rounded card. With no top
                // inset the 40pt back button sat right inside the 26pt corner
                // arc, so its left margin read as a few points while the side
                // inset was 18 — the button looked jammed into the curve. This
                // lifts it to the same distance as the side inset. Solid and
                // Morandi have no card, so they keep the original spacing.
                .padding(.top, AppearanceSettings.shared.usesGlass ? 20 : 0)
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
                // Playlists and Settings have to stay reachable with no music
                // yet.
                if library.tracks.isEmpty && library.isScanning {
                    scanningScreen
                } else if library.tracks.isEmpty {
                    EmptyLibraryView(palette: active)
                } else {
                    libraryScreen
                }
            case .playlists: playlistsScreen
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
            // The library carries its own small search field, the way the
            // desktop layout does: the term that narrows the list is visible on
            // the same page and can be cleared right there.
            HStack(alignment: .center, spacing: 12) {
                Text(L("Library"))
                    .font(.display(34, .semibold))
                    .foregroundStyle(active.onSurface)
                Spacer(minLength: 8)
                SearchPill(text: $search, palette: active,
                           prompt: L("Search"), width: 148,
                           focus: $searchFocused)
                    // The pill sits inside several nested ZStacks now (root,
                    // orientation branch, glass page). Give the whole pill an
                    // explicit focus target so a tap always reaches the field
                    // regardless of what the surrounding gesture recognisers
                    // claim; the clear button still wins over this gesture.
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Defer one turn: a sibling tap gesture on the page
                        // clears focus on the same touch, so setting it
                        // inline loses immediately. Re-assert after it runs.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                            searchFocused = true
                        }
                    }
            }
            // In the glass theme the page sits inside the floating panel, and
            // without this the title's cap-height lands ~14pt from the
            // panel's top edge — visibly tighter than the Search and
            // Settings pages, which both use 40pt. Only the glass theme
            // needs it; Solid and Morandi are unchanged.
            .padding(.top, AppearanceSettings.shared.usesGlass ? 22 : 0)
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
                case .recent:
                    SongListView(tracks: filtered(library.tracks).sorted { $0.dateAdded > $1.dateAdded })
                }
            }
            .offset(x: swipeOffset)
            // Tapping the list or a tab chip puts the keyboard away: a SwiftUI
            // text field does not resign when another control is tapped.
            .simultaneousGesture(TapGesture().onEnded { searchFocused = false })
            .onChange(of: tab) { _, _ in searchFocused = false }
            // Back on: the row menu is a system action sheet now, so it no
            // longer shares a gesture arena with this drag — the two were only
            // ever in conflict while the popup was a UIKit menu anchored to a
            // row that the swipe recogniser also covered.
            .simultaneousGesture(tabSwipe)
        }
    }

    /// Standalone playlists page: the list the library used to hide behind its
    /// fifth chip, now its own destination in the bottom bar.
    private var playlistsScreen: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("Playlists"))
                .font(.display(34, .semibold))
                .foregroundStyle(active.onSurface)
                .padding(.top, AppearanceSettings.shared.usesGlass ? 22 : 0)
                .padding(.horizontal, 22)
                .padding(.bottom, 8)

            PlaylistListView(playlists: playlistStore.playlists)
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

    // MARK: Swipe back

    /// Swipe-back for the detail pages (album / artist / playlist). It answers
    /// a drag that starts **anywhere** on the page — the old version required
    /// the drag to begin inside a 28pt strip on the left edge, which is why it
    /// so often felt dead. The ratio guard is what protects the vertical lists:
    /// a drag that is not clearly more horizontal than vertical is left
    /// entirely to the ScrollView underneath, and only a rightward one moves
    /// the page. The page follows the finger and pops when the travel (or the
    /// flick) passes the threshold, otherwise springs back.
    private var backSwipe: some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { value in
                guard nav.route != nil else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                guard dx > 0, dx > abs(dy) * 1.8 else { return }
                backSwipeOffset = dx
            }
            .onEnded { value in
                guard nav.route != nil else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                let flick = value.predictedEndTranslation.width
                // Same guard as `onChanged`: releasing a vertical scroll must
                // not pop the page.
                let horizontal = dx > 0 && dx > abs(dy) * 1.8
                let passed = horizontal && (dx > 80 || (dx > 30 && flick > 150))
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
                || album.tracks.contains { $0.title.lowercased().contains(query) }
        }
    }

    private var filteredArtists: [Artist] {
        guard !query.isEmpty else { return library.artists }
        return library.artists.filter { $0.name.lowercased().contains(query) }
    }
}

// MARK: - Floating nav bar

/// The landscape counterpart of `PhoneNavBar`: same destinations, same
/// material, stacked down the left edge instead of along the bottom.
struct PhoneNavRail: View {
    @Binding var destination: RailDestination
    let palette: M3Palette
    @ObservedObject private var appearance = AppearanceSettings.shared

    var body: some View {
        VStack(spacing: 12) {
            ForEach(RailDestination.allCases, id: \.self) { item in
                Button {
                    withAnimation(.snappy(duration: 0.25)) { destination = item }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.icon)
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(destination == item
                                             ? palette.onPrimaryContainer : palette.onSurfaceVariant)
                            .frame(width: 52, height: 44)
                            .background {
                                Capsule().fill(destination == item
                                               ? palette.primaryContainer : .clear)
                            }
                        Text(item.title)
                            .font(.label(9.5, destination == item ? .semibold : .medium))
                            .foregroundStyle(destination == item
                                             ? palette.onSurface : palette.onSurfaceVariant)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 14)
        .background {
            SurfaceRole.panel.background(palette,
                shape: AnyShape(Capsule()), radius: 999, strong: true)
        }
        .padding(.leading, 6)
    }
}

struct PhoneNavBar: View {
    @Binding var destination: RailDestination
    let palette: M3Palette

    /// The bar has to observe the appearance itself. Solid and frosted glass
    /// share the *same* palette, so when the theme flips the only stored input
    /// here is unchanged and SwiftUI skips re-running this body — the bar kept
    /// its old material until the next navigation changed `destination`.
    @ObservedObject private var appearance = AppearanceSettings.shared

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
                    // Same reason as the desktop rail: a plain button only
                    // answers clicks on drawn pixels, so the title and the gap
                    // under the icon were dead. This turns the whole column —
                    // and the bar's vertical padding — into one target without
                    // changing the bar's height (the padding moved in from the
                    // HStack below).
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .background {
            // Same material *and* same outline family as the floating player
            // pill: a capsule. At radius 30 the bar read as a solid slab,
            // while the pill beside it reads as glass — the difference was
            // the silhouette, not the frost.
            SurfaceRole.panel.background(palette,
                shape: AnyShape(Capsule()), radius: 999, strong: true)
        }
    }
}

// MARK: - Mini player

struct PhoneMiniPlayer: View {
    let palette: M3Palette
    let onExpand: () -> Void

    @EnvironmentObject var player: AudioPlayer
    /// Same reason as `PhoneNavBar`: the mini player's own inputs don't change
    /// between Solid and glass, so it has to watch the appearance itself or it
    /// keeps the previous material until something else forces a redraw.
    @ObservedObject private var appearance = AppearanceSettings.shared

    var body: some View {
        HStack(spacing: 11) {
            if let track = player.current {
                SpinningCover(track: track, cacheKey: track.albumKey,
                              radius: Radius.thumb, palette: palette,
                              fallback: track.hasArtwork ? nil : DefaultCover.image,
                              isPlaying: player.isPlaying)
                    .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .font(.body(13, .semibold))
                        .foregroundStyle(palette.onSurface)
                        .lineLimit(1)
                        // The page animates on `player.current`, which makes a
                        // changed string crossfade — two titles on top of each
                        // other for a beat. Swap it instead.
                        .contentTransition(.identity)
                    Text(track.artist)
                        .font(.body(11))
                        .foregroundStyle(palette.onSurfaceVariant)
                        .lineLimit(1)
                        .contentTransition(.identity)
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
    @ObservedObject private var appearance = AppearanceSettings.shared
    /// Stable signal for the orientation change: the geometry reader's size
    /// can pass through intermediate values, but this flips once per turn and
    /// drives the crossfade between the two stage layouts.
    @Environment(\.verticalSizeClass) private var sizeClass
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
    /// Wet-mac behaviour for the landscape stage: the chrome floats over the
    /// artwork and fades away after a few idle seconds, so the page is just
    /// cover and lyrics until it is touched again.
    @State private var chromeVisible = true
    @State private var chromeTask: Task<Void, Never>?
    @Environment(\.verticalSizeClass) private var vSizeClass

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

            GeometryReader { geo in
                let landscape = geo.size.width > geo.size.height
                if landscape {
                    landscapeStage(in: geo.size)
                        .transition(.scale(scale: 0.97).combined(with: .opacity))
                } else {
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
                            SpinningCover(track: track, cacheKey: track.albumKey,
                                          radius: appearance.vinylRecords ? 999 : 30,
                                          palette: palette,
                                          fallback: track.hasArtwork ? nil : DefaultCover.image,
                                          isPlaying: player.isPlaying)
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
                    .transition(.scale(scale: 1.03).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.36), value: sizeClass)

            // Popups live in this ZStack, exactly like the floating player
            // bar: a system sheet's presenting view is isolated by UIKit, so a
            // blur inside the sheet sees only a flat backdrop and none of the
            // artwork behind it. In the same hierarchy the frost really has
            // the cover to reveal.
            if showQueue || showEQ || showAudioChain {
                popupLayer
                    .zIndex(5)
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
                    guard !showQueue, !showEQ, !showAudioChain else { return }
                    let height = value.translation.height
                    let width = value.translation.width
                    guard height > 0, height > abs(width) * 1.2 else { return }
                    dismissDrag = height
                }
                .onEnded { value in
                    guard !showQueue, !showEQ, !showAudioChain else {
                        dismissDrag = 0
                        return
                    }
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
    }

    /// The landscape stage mirrors the desktop player: cover column on the
    /// left, lyrics on the right, and every control floating over them instead
    /// of taking a slice of a screen that is only ~390pt tall. Five idle
    /// seconds and the chrome fades out; touching the page brings it back.
    @ViewBuilder
    private func landscapeStage(in size: CGSize) -> some View {
        let side = min(size.height * 0.46, 205)

        ZStack {
            HStack(alignment: .center, spacing: 22) {
                VStack(spacing: 7) {
                    SpinningCover(track: player.current,
                                  cacheKey: player.current?.albumKey ?? "",
                                  radius: appearance.vinylRecords ? 999 : 16,
                                  palette: palette,
                                  fallback: player.current?.hasArtwork == true ? nil : DefaultCover.image,
                                  isPlaying: player.isPlaying)
                        .frame(width: side, height: side)
                        .shadow(color: .black.opacity(0.35), radius: 16, y: 7)

                    VStack(spacing: 3) {
                        Text(player.current?.title ?? "")
                            .font(.display(18, .semibold))
                            .foregroundStyle(titleColor)
                            .lineLimit(1)
                        Text(player.current?.artist ?? "")
                            .font(.body(14.5, .medium))
                            .foregroundStyle(secondaryColor)
                            .lineLimit(1)
                    }
                    .frame(width: side + 44)
                }

                if let track = player.current {
                    LyricsPane(track: track, currentTime: player.currentTime,
                               palette: palette, onTap: {},
                               showsPanel: false,
                               primaryColor: titleColor,
                               secondaryColor: secondaryColor,
                               accentColor: coverAccent,
                               fontSize: 23)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 10)
            // No reserved band for the floating card: it covers the bottom
            // while it is up and gets out of the way when it fades, so the
            // page uses the full height instead of leaving a dead strip.
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            chrome
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if chromeVisible {
                chromeTask?.cancel()
                withAnimation(.easeInOut(duration: 0.45)) { chromeVisible = false }
            } else {
                revealChrome()
            }
        }
        .onAppear { restartIdleHide() }
        .onDisappear { chromeTask?.cancel() }
        .onChange(of: popupOpen) { _, open in
            if open {
                chromeTask?.cancel()
                withAnimation(.easeInOut(duration: 0.25)) { chromeVisible = false }
            } else {
                revealChrome()
            }
        }
    }

    /// Floating close/icons at the top and transport card at the bottom.
    private var chrome: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                IconButton(system: "chevron.down", size: 38, glyph: 14,
                           fill: buttonFill,
                           foreground: onStage ? Color.white.opacity(0.9) : palette.onSurface,
                           action: onDismiss)

                Spacer(minLength: 8)

                IconButton(system: "music.note.list", size: 38, glyph: 14,
                           fill: showQueue ? coverAccent : buttonFill,
                           foreground: showQueue ? coverAccentOn
                                                 : (onStage ? Color.white.opacity(0.9) : palette.onSurface)) {
                    withAnimation(.easeOut(duration: 0.24)) { showQueue = true }
                }

                IconButton(system: "slider.vertical.3", size: 38, glyph: 14,
                           fill: player.eqEnabled ? coverAccent : buttonFill,
                           foreground: player.eqEnabled
                               ? coverAccentOn
                               : (onStage ? Color.white.opacity(0.9) : palette.onSurface)) {
                    showEQ = true
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)

            Spacer(minLength: 0)

            landscapeControlCard
                .frame(maxWidth: 560)
                .padding(.horizontal, 30)
                .padding(.bottom, 8)
        }
        // The queue takes the left half; leaving the transport floating over
        // the lyrics as well made the stage feel crowded, so the chrome steps
        // aside while it is open.
        .opacity(chromeVisible && !popupOpen ? 1 : 0)
        .allowsHitTesting(chromeVisible && !popupOpen)
        .animation(.easeInOut(duration: 0.35), value: chromeVisible)
        .animation(.easeInOut(duration: 0.25), value: popupOpen)
    }

    /// Progress and transport in one floating card, sized for a short screen.
    private var landscapeControlCard: some View {
        VStack(spacing: 4) {
            scrubber

            HStack(spacing: 16) {
                chip(system: "shuffle", isOn: player.isShuffled) {
                    player.isShuffled.toggle()
                    revealChrome()
                }

                Button { player.previous() } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(stageOnAccentSoft)
                        .frame(width: 58, height: 40)
                        .background(Capsule().fill(stageAccentSoft))
                }
                .buttonStyle(.plain)

                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(coverAccentOn)
                        .frame(width: 64, height: 44)
                        .background(RoundedRectangle(cornerRadius: player.isPlaying ? 16 : 22,
                                                     style: .continuous)
                            .fill(coverAccent))
                }
                .buttonStyle(.plain)
                .animation(.spring(response: 0.32, dampingFraction: 0.7), value: player.isPlaying)

                Button { player.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(stageOnAccentSoft)
                        .frame(width: 58, height: 40)
                        .background(Capsule().fill(stageAccentSoft))
                }
                .buttonStyle(.plain)

                chip(system: player.repeatMode.symbol, isOn: player.repeatMode != .off) {
                    switch player.repeatMode {
                    case .off: player.repeatMode = .all
                    case .all: player.repeatMode = .one
                    case .one: player.repeatMode = .off
                    }
                    revealChrome()
                }
            }
            .padding(.bottom, 4)
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(palette.surfaceContainer.opacity(onStage ? 0.42 : 0.86))
                .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.white.opacity(onStage ? 0.16 : 0.0), lineWidth: 0.8))
                .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
        }
        .simultaneousGesture(TapGesture().onEnded { revealChrome() })
    }

    private func revealChrome() {
        if !chromeVisible {
            withAnimation(.easeInOut(duration: 0.25)) { chromeVisible = true }
        }
        restartIdleHide()
    }

    private func restartIdleHide() {
        chromeTask?.cancel()
        chromeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            guard !showQueue, !showEQ, !showAudioChain else { return }
            withAnimation(.easeInOut(duration: 0.45)) { chromeVisible = false }
        }
    }

    /// Vertical offset while a popup is being pulled down to dismiss it.
    /// The gesture lives only on a top grabber, so the lists and faders below
    /// keep their own scrolling.
    @State private var popupDrag: CGFloat = 0

    /// Any of the floating panels — queue, equalizer, audio chain.
    private var popupOpen: Bool { showQueue || showEQ || showAudioChain }

    private func closePopup() {
        popupDrag = 0
        showQueue = false
        showEQ = false
        showAudioChain = false
    }

    @ViewBuilder
    private var popupCard: some View {
        if showEQ {
            EqualizerView(palette: playerOverlayPalette(palette)) { closePopup() }
                .environmentObject(player)
        } else if showQueue {
            QueueList(palette: playerOverlayPalette(palette), background: .fullBleedGlass)
                .environmentObject(player)
        } else if showAudioChain {
            AudioChainView(palette: playerOverlayPalette(palette)) { closePopup() }
                .environmentObject(player)
        }
    }

    /// An in-window floating card. Each content view paints its own
    /// `SurfaceRole.panel` / `strong` glass, so this layer only supplies the
    /// scrim, the rounded silhouette, the shadow and the tap-to-dismiss.
    private var popupLayer: some View {
        GeometryReader { geo in
            if geo.size.width > geo.size.height, popupOpen {
                // Landscape: the queue becomes a left-hand panel so the lyrics
                // stay visible next to it, instead of a sheet that covers the
                // whole short screen.
                ZStack(alignment: .leading) {
                    Color.black.opacity(0.12)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { closePopup() }

                    popupCard
                        // The equalizer carries ten sliders plus a preset grid
                        // and needs real width; the queue is just rows.
                        .frame(width: showEQ
                               ? min(geo.size.width * 0.55, 480)
                               : min(geo.size.width * 0.38, 340))
                        .frame(maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                        .shadow(color: .black.opacity(0.38), radius: 30, x: 10)
                        // Flush to the safe-area edge: the only gap left is
                        // the sensor housing, which a panel may not cover.
                        .padding(.leading, 0)
                        .padding(.vertical, 8)
                }
                // Without this the home-indicator inset counts only at the
                // bottom, so the panel sat 8pt from the top and ~29pt from the
                // bottom. Ignoring it makes both margins 8.
                .ignoresSafeArea(edges: .bottom)
                .transition(.move(edge: .leading).combined(with: .opacity))
            } else {
            ZStack(alignment: .bottom) {
                Color.black.opacity(0.12)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { closePopup() }

                popupCard
                    .frame(maxWidth: .infinity)
                    .frame(height: min(geo.size.height * 0.74, 640))
                    .overlay(alignment: .top) { popupDragHandle }
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .shadow(color: .black.opacity(0.38), radius: 30, y: 14)
                    .offset(y: max(0, popupDrag))
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
            .ignoresSafeArea(edges: .bottom)
            }
        }
        .transition(vSizeClass == .compact
                    ? .move(edge: .leading).combined(with: .opacity)
                    : .move(edge: .bottom).combined(with: .opacity))
    }

    /// The sheet-like grabber. Only this strip owns the dismiss drag. It is
    /// deliberately wide (300pt) so a thumb landing off-centre still catches
    /// it, while leaving the outer ~40pt clear for the close button / toggle.
    private var popupDragHandle: some View {
        HStack {
            Spacer(minLength: 0)
            Capsule()
                .fill(Color.primary.opacity(0.28))
                .frame(width: 46, height: 5)
            Spacer(minLength: 0)
        }
        .frame(width: 300, height: 32)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { value in
                    guard value.translation.height > 0 else { return }
                    popupDrag = value.translation.height
                }
                .onEnded { value in
                    let height = value.translation.height
                    let predicted = value.predictedEndTranslation.height
                    if height > 120 || predicted > 220 {
                        closePopup()
                    } else {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                            popupDrag = 0
                        }
                    }
                }
        )
    }

    private var header: some View {
        HStack {
            IconButton(system: "chevron.down", size: 40, glyph: 15,
                       fill: buttonFill,
                       foreground: onStage ? Color.white.opacity(0.9) : palette.onSurface,
                       action: onDismiss)
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
