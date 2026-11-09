#if os(macOS)
import SwiftUI
import AppKit

// MARK: - Idle chrome

/// Shows the playback controls while the pointer is being used and tucks them
/// away after a few quiet seconds. A local event monitor is needed because
/// SwiftUI's `onHover` only fires on enter/exit — holding the pointer still
/// over a button would otherwise let the bar vanish under the cursor.
@MainActor
final class ChromeVisibility: ObservableObject {
    @Published var visible = true

    private var hovering = false
    private var hideTask: Task<Void, Never>?
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .scrollWheel, .keyDown
        ]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor in self?.noteActivity() }
            return event
        }
        noteActivity()
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        hideTask?.cancel()
        hideTask = nil
    }

    func setHovering(_ value: Bool) {
        hovering = value
        if value { noteActivity() }
    }

    func noteActivity() {
        if !visible {
            withAnimation(.easeInOut(duration: 0.22)) { visible = true }
        }
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled, !self.hovering else { return }
            withAnimation(.easeInOut(duration: 0.45)) { self.visible = false }
        }
    }
}

// MARK: - Static backdrop

/// Renders the blurred cover **once** into a small bitmap instead of asking
/// SwiftUI to composite a live `blur(radius: 72)` over a full-window layer on
/// every frame. A 128px source scaled up to fill the window is already soft,
/// so the look is the same but the layer is a plain texture: moving the whole
/// stage off screen (dismiss) then costs one transform per frame rather than
/// re-rasterising a full-screen Gaussian blur.
@MainActor
final class StageBackdrop: ObservableObject {
    @Published private(set) var image: PlatformImage?

    private let cache = NSCache<NSString, PlatformImage>()
    private var task: Task<Void, Never>?
    /// Guards against a slow decode for an earlier track landing after a
    /// newer one when the user changes tracks quickly.
    private var request = 0

    func load(for track: Track?) {
        request += 1
        let ticket = request
        task?.cancel()
        guard let track else {
            image = nil
            return
        }
        let key = track.albumKey
        if !track.hasArtwork {
            // No sleeve of its own: derive the texture from the bundled default
            // cover instead, exactly like the phone stage, so the player reads
            // identically whether or not the track carries artwork — and the
            // white track details keep a dark, scrimmed backdrop.
            guard let def = DefaultCover.image, let made = makeStageBackdrop(def) else {
                image = nil
                return
            }
            image = made
            return
        }
        if let hit = cache.object(forKey: key as NSString) {
            image = hit
            return
        }
        // Keep the previous texture until the new one is ready: clearing it
        // here exposes the light surface underneath for a frame, which reads
        // as a bright flash when changing tracks.
        task = Task.detached(priority: .utility) { [weak self] in
            let art = await loadStageArtwork(for: track, key: key)
            guard let art, let made = makeStageBackdrop(art), !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.request == ticket else { return }
                self.cache.setObject(made, forKey: key as NSString)
                self.image = made
            }
        }
    }
}

/// These live outside the @MainActor class so the render can run off the main
/// thread without an actor hop (and without blocking a dismissal animation).
private func loadStageArtwork(for track: Track, key: String) async -> PlatformImage? {
    await withCheckedContinuation { continuation in
        ArtworkCache.shared.artwork(for: track, key: key) { image in
            continuation.resume(returning: image)
        }
    }
}

private func makeStageBackdrop(_ source: PlatformImage) -> PlatformImage? {
    guard let tiff = source.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let input = CIImage(bitmapImageRep: rep) else { return nil }
    let side = StageBackdropFilter.side
    let rect = CGRect(x: 0, y: 0, width: side, height: side)
    let texture = StageBackdropFilter.texture(from: input)
    guard let cg = CIContext().createCGImage(texture, from: rect) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: side, height: side))
}

// MARK: - Stage

/// Full-window desktop player: blurred cover behind, cover and track details on
/// the left, synchronously scrolling lyrics on the right, and a control bar that
/// appears on pointer activity and fades out when idle.
struct MacPlaybackStage: View {
    let palette: M3Palette
    let onDismiss: () -> Void

    @EnvironmentObject var player: AudioPlayer
    @StateObject private var chrome = ChromeVisibility()
    @StateObject private var backdrop = StageBackdrop()
    @State private var showQueue = false
    @ObservedObject private var appearance = AppearanceSettings.shared
    @State private var showEQ = false
    @State private var showAudioChain = false
    @State private var showLyrics = true
    @State private var scrub: Double = 0
    @State private var scrubbing = false

    var body: some View {
        ZStack {
            // A plain VStack, not overlays: the bars take real space at the
            // edges and keep their slots when hidden, so the cover and lyrics
            // never shift as the controls fade in and out.
            VStack(spacing: 0) {
                topBar
                    .frame(height: 54)
                    .opacity(chrome.visible ? 1 : 0)
                    .allowsHitTesting(chrome.visible)

                stage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                bottomBar
                    .frame(height: 104)
                    .opacity(chrome.visible ? 1 : 0)
                    .allowsHitTesting(chrome.visible)
            }
            .background { background }
            .onAppear {
                chrome.start()
                backdrop.load(for: player.current)
            }
            .onDisappear { chrome.stop() }
            .onChange(of: player.current?.albumKey) { _, _ in
                backdrop.load(for: player.current)
            }
            .onChange(of: player.currentTime) { _, time in
                if !scrubbing, player.duration > 0 { scrub = time / player.duration }
            }
            .animation(.easeInOut(duration: 0.35), value: chrome.visible)

            if showEQ {
                overlayPanel(isShown: $showEQ, width: 560, height: 640) {
                    EqualizerView(palette: playerOverlayPalette(palette)) { showEQ = false }
                }
            }

            if showAudioChain {
                // Tall enough that the pinned output chips don't squeeze the
                // signal-path read-out.
                overlayPanel(isShown: $showAudioChain, width: 500, height: 624) {
                    AudioChainView(palette: playerOverlayPalette(palette)) { showAudioChain = false }
                }
            }
        }
        .animation(.easeOut(duration: 0.18), value: showEQ)
        .animation(.easeOut(duration: 0.18), value: showAudioChain)
    }

    // MARK: - Floating panels

    /// A sheet-shaped card that closes when the user clicks anywhere outside
    /// it. A real `.sheet` is document-modal on macOS: the host window stays
    /// unclickable behind it, so the corner button was the only way out. Drawn
    /// in-window instead, the scrim takes the click and the card keeps its
    /// taps — including a fader drag that runs past its own edge.
    private func overlayPanel<Content: View>(
        isShown: Binding<Bool>,
        width: CGFloat,
        height: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack {
            Color.black.opacity(0.38)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { isShown.wrappedValue = false }

            content()
                .environmentObject(player)
                .frame(width: width, height: height)
                // The panel content paints its own themed backdrop (glass or
                // solid) so it matches the player; nothing is layered behind it.
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(palette.outline.opacity(0.25), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.45), radius: 40, y: 18)
                // Clicks that land on the card belong to the card, never to
                // the scrim underneath it.
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .onTapGesture { }
        }
        .transition(.opacity)
        .zIndex(5)
        // A sheet answers Escape by default; the in-window card has to be told.
        .background {
            Button("") { isShown.wrappedValue = false }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.plain)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    // MARK: Background

    @ViewBuilder
    private var background: some View {
        ZStack {
            // Neutral dark base so the frame before the texture arrives never
            // shows the light surface as a bright flash.
            ((player.current?.hasArtwork == true || DefaultCover.isAvailable)
                ? Color(white: 0.12) : palette.surface)
            if let image = backdrop.image {
                Image(platformImage: image)
                    .resizable(resizingMode: .stretch)
                    .interpolation(.high)
                    .overlay(Color.black.opacity(StageBackdropFilter.scrim))
            }
        }
        .ignoresSafeArea()
    }

    // MARK: Stage

    private var stage: some View {
        // The queue is an overlay, never a third column of the HStack. Adding
        // or removing a 300pt column used to resize the lyrics ScrollView on
        // every animation frame, which re-wrapped every visible lyric line —
        // that reflow was the stutter when opening/closing the queue.
        HStack(alignment: .top, spacing: 62) {
            leftColumn.frame(width: 330)

            if showLyrics {
                StageLyricsView(track: player.current, currentTime: player.currentTime)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // A bare Spacer would let the row collapse to the cover's own
                // height; the outer `maxHeight: .infinity` frame then centres
                // that shorter row, so the cover (and the queue overlay, which
                // is sized by this row) jumped whenever lyrics were hidden.
                // An empty flexible view keeps the slot at full size.
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(true)
            }
        }
        // Pin the row to the top-left of the slot so its height is never
        // re-centred while the lyric column comes and goes.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.leading, 68)
        .padding(.trailing, 46)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .overlay(alignment: .trailing) {
            if showQueue {
                QueueList(palette: playerOverlayPalette(palette))
                    .frame(width: 300)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.trailing, 46)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private var leftColumn: some View {
        if let track = player.current {
            VStack(alignment: .leading, spacing: 0) {
                CoverArt(track: track, cacheKey: track.albumKey, radius: 22, palette: palette,
                         // Tracks without their own sleeve fall back to the
                         // bundled default cover, the same image the phone
                         // uses — so the player shows the same rounded cover
                         // on both platforms instead of a bare music-note tile.
                         fallback: track.hasArtwork ? nil : DefaultCover.image)
                    .frame(width: 300, height: 300)
                    .shadow(color: .black.opacity(0.38), radius: 30, y: 14)

                Text(track.title)
                    .font(.display(24, .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .padding(.top, 26)

                HStack(spacing: 6) {
                    badge(L("LOCAL"))
                    badge(track.format.displayName)
                    badge(track.qualityLabel)
                }
                .padding(.top, 10)

                VStack(alignment: .leading, spacing: 6) {
                    Label(track.artist, systemImage: "music.mic")
                    Label(track.album, systemImage: "opticaldisc")
                }
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.62))
                .padding(.top, 16)
            }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 4)
                .stroke(.white.opacity(0.42), lineWidth: 0.8))
    }

    // MARK: Top bar

    private var topBar: some View {
        // The title sits between two equally sized icon buttons, so the row
        // still balances it in the middle.
        HStack {
            stageIcon("chevron.down", help: L("Back to library"), hitSize: 40) {
                // Kill the idle monitor before the stage starts moving. A mouse
                // event arriving mid-dismiss would otherwise fire a nested
                // withAnimation for the bars on top of the slide-out animation.
                chrome.stop()
                onDismiss()
            }
            Spacer()
            Text(L("Now Playing"))
                .font(.label(12.5, .semibold))
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
            // The single lyrics switch: the bottom bar's copy is gone.
            stageIcon("text.quote", active: showLyrics,
                      help: showLyrics ? L("Hide lyrics") : L("Show lyrics"), hitSize: 40) {
                withAnimation(.easeInOut(duration: 0.25)) { showLyrics.toggle() }
            }
        }
        // The icon row is 40pt tall now (the larger target) while the bar is
        // 54pt. 20 + 40 lands on the same line the old 26pt row used, so the
        // arrow itself has not moved — only its click target grew.
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .onHover { chrome.setHovering($0) }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 0) {
                // The left group is empty now that the like and lyrics buttons
                // are gone. An invisible 230pt placeholder keeps the transport
                // centred instead of drifting towards the left edge.
                Color.clear
                    .frame(width: 230, alignment: .leading)
                    .accessibilityHidden(true)

                Spacer(minLength: 12)

                VStack(spacing: 9) {
                    transport
                    progress
                }
                .frame(maxWidth: 520)

                Spacer(minLength: 12)

                HStack(spacing: 14) {
                    volumeChip
                    stageIcon("slider.vertical.3", active: player.eqEnabled,
                              help: L("Open equalizer")) { showEQ = true }
                    stageIcon("music.note.list", active: showQueue,
                              help: showQueue ? L("Hide queue") : L("Show queue")) {
                        chrome.noteActivity()
                        withAnimation(.easeOut(duration: 0.24)) { showQueue.toggle() }
                    }
                    chainButton
                }
                .frame(width: 230, alignment: .trailing)
            }
            .padding(.horizontal, 26)
        }
        .padding(.top, 26)
        .padding(.bottom, 16)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.32)],
                           startPoint: .top, endPoint: .bottom)
        )
        .onHover { chrome.setHovering($0) }
    }

    private var transport: some View {
        HStack(spacing: 24) {
            stageIcon("shuffle", active: player.isShuffled,
                      help: player.isShuffled ? L("Turn shuffle off") : L("Turn shuffle on")) {
                player.isShuffled.toggle()
            }
            stageIcon("backward.fill", help: L("Previous track")) { player.previous() }

            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Circle().stroke(.white.opacity(0.55), lineWidth: 1.3))
            }
            .buttonStyle(.plain)
            .help(player.isPlaying ? L("Pause") : L("Play"))

            stageIcon("forward.fill", help: L("Next track")) { player.next() }
            stageIcon(player.repeatMode.symbol, active: player.repeatMode != .off,
                      help: repeatHelp) { cycleRepeat() }
        }
    }

    /// Names what the click does next. The icon already shows the current mode,
    /// so "Repeat" alone would leave the cycling order a guess.
    private var repeatHelp: String {
        switch player.repeatMode {
        case .off: return L("Repeat all")
        case .all: return L("Repeat this track")
        case .one: return L("Turn repeat off")
        }
    }

    private var progress: some View {
        HStack(spacing: 10) {
            Text(formatTime(scrubbing ? scrub * player.duration : player.currentTime))
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.72))
                .frame(width: 38, alignment: .trailing)

            Slider(value: $scrub, in: 0...1) { editing in
                scrubbing = editing
                if !editing { player.seek(to: scrub * player.duration) }
            }
            .controlSize(.small)
            .tint(.white.opacity(0.9))

            Text(formatTime(player.duration))
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.72))
                .frame(width: 38, alignment: .leading)
        }
    }

    private var volumeChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.8))
            Slider(value: $player.volume, in: 0...1)
                .controlSize(.small)
                .tint(.white.opacity(0.9))
                .frame(width: 74)
        }
        .help(L("Volume"))
    }

    /// `help` is spelled out per button: the tooltip used to be the SF Symbol
    /// name, which told the user nothing ("ellipsis", "slider.vertical.3") and
    /// was flatly wrong for the ones whose icon is only a metaphor.
    ///
    /// `hitSize` is the size of the label's frame, and with it the click
    /// target: a bare SF Symbol only answers clicks on its drawn pixels — the
    /// chevron is about 12x7 points, which is close to unhittable. The
    /// `contentShape` has to sit on the Image inside the label; without it
    /// the empty part of the frame is not clickable, and a larger frame alone
    /// just moves the glyph.
    private func stageIcon(_ system: String, active: Bool = false,
                           help: String, hitSize: CGFloat = 26,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(active ? 1 : 0.72))
                .frame(width: hitSize, height: hitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Rightmost toolbar button. The coloured dot is the current quality
    /// verdict, so the chain can be checked at a glance without opening it.
    private var chainButton: some View {
        let quality = player.audioChain.quality
        return Button { showAudioChain = true } label: {
            Image(systemName: "waveform")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))
                .frame(width: 26, height: 26)
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(quality.color)
                        .frame(width: 7, height: 7)
                        .offset(x: 2, y: -1)
                }
        }
        .buttonStyle(.plain)
        .help(quality == .idle ? L("Audio chain") : L("Audio chain") + " — " + L(quality.profile))
    }

    private func cycleRepeat() {
        switch player.repeatMode {
        case .off: player.repeatMode = .all
        case .all: player.repeatMode = .one
        case .one: player.repeatMode = .off
        }
    }
}

// MARK: - Desktop lyrics

/// The large, fading lyric column to the right of the cover. The current line
/// is brighter and heavier; the list keeps it centred as the song advances.
struct StageLyricsView: View {
    let track: Track?
    let currentTime: Double

    @State private var lyrics: Lyrics?
    @State private var loaded = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let lyrics, !lyrics.isEmpty {
                let active = lyrics.index(at: currentTime)
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 26) {
                            ForEach(Array(lyrics.lines.enumerated()), id: \.element.id) { index, line in
                                Text(line.text.isEmpty ? "♪" : line.text)
                                    .font(.system(size: index == active ? 27 : 23,
                                                  weight: index == active ? .semibold : .regular))
                                    .foregroundStyle(.white.opacity(index == active ? 0.98 : 0.42))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .id(line.id)
                            }
                            // Room to centre the last line.
                            Spacer().frame(height: 220)
                        }
                        .padding(.vertical, 130)
                    }
                    .mask(
                        LinearGradient(colors: [.clear, .white, .white, .white, .clear],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    .onAppear { scroll(proxy, to: active, in: lyrics) }
                    .onChange(of: active) { _, next in
                        scroll(proxy, to: next, in: lyrics)
                    }
                }
            } else if loaded {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("No lyrics"))
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                    Text(L("Add a .lrc file with the same name beside the audio file, or embed lyrics in the file's tags."))
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: 360, alignment: .leading)
                }
                .padding(.top, 130)
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: track?.id) { await load() }
    }

    private func scroll(_ proxy: ScrollViewProxy, to index: Int?, in lyrics: Lyrics) {
        guard let index, lyrics.lines.indices.contains(index) else { return }
        withAnimation(.easeInOut(duration: 0.55)) {
            proxy.scrollTo(lyrics.lines[index].id, anchor: .center)
        }
    }

    private func load() async {
        guard let track else {
            lyrics = nil
            loaded = true
            return
        }
        loaded = false
        lyrics = nil
        let parsed = await Task.detached(priority: .userInitiated) {
            Lyrics.load(for: track)
        }.value
        lyrics = parsed
        loaded = true
    }
}
#endif
