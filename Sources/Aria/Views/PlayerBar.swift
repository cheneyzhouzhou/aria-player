import SwiftUI

// MARK: - Mini player

/// The floating pill that sits above the content, tinted by the current track.
struct MiniPlayer: View {
    let palette: M3Palette
    let onExpand: () -> Void

    @EnvironmentObject var player: AudioPlayer
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            if let track = player.current {
                CoverArt(track: track, cacheKey: track.albumKey,
                         radius: Radius.thumb, palette: palette)
                    .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .font(.body(13.5, .semibold))
                        .foregroundStyle(palette.onSurface)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.body(11.5))
                        .foregroundStyle(palette.onSurfaceVariant)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                // A slim progress read-out so the pill still conveys position.
                MascotScrubber(
                    progress: player.duration > 0 ? player.currentTime / player.duration : 0,
                    isAnimating: player.isPlaying,
                    height: 40, mascotSize: 30, trackWidth: 3.5,
                    activeColor: palette.primary,
                    inactiveColor: palette.onSurfaceVariant.opacity(0.3),
                    inkColor: palette.onPrimary,
                    onCommit: { player.seek(to: $0 * player.duration) }
                )
                .frame(width: 190)

                Text(formatTime(player.currentTime))
                    .font(.ticker(11))
                    .foregroundStyle(palette.onSurfaceVariant)
                    .frame(width: 40, alignment: .trailing)

                IconButton(system: player.isPlaying ? "pause.fill" : "play.fill",
                           size: 40, glyph: 15,
                           fill: palette.primary, foreground: palette.onPrimary) {
                    player.togglePlayPause()
                }

                IconButton(system: "forward.fill", size: 40, glyph: 14,
                           fill: palette.surfaceContainerHigh, foreground: palette.onSurface) {
                    player.next()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            Capsule().fill(palette.surfaceContainer)
                .shadow(color: .black.opacity(0.28), radius: 18, y: 6)
        }
        .overlay {
            Capsule().strokeBorder(palette.outline.opacity(0.25), lineWidth: 1)
        }
        .scaleEffect(isHovering ? 1.006 : 1)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.16), value: isHovering)
        // The artwork opens the full player; the controls keep their own taps.
        .onTapGesture(perform: onExpand)
    }
}

// MARK: - Now playing

/// Full-window player, tinted end to end by the current cover.
struct NowPlayingView: View {
    let palette: M3Palette
    let onDismiss: () -> Void

    @EnvironmentObject var player: AudioPlayer
    @State private var scrubFraction: Double?
    @State private var showQueue = false
    @State private var showEQ = false

    private var track: Track? { player.current }

    private var shownTime: Double {
        if let scrubFraction { return scrubFraction * player.duration }
        return player.currentTime
    }

    var body: some View {
        #if os(macOS)
        MacPlaybackStage(palette: palette, onDismiss: onDismiss)
            .environmentObject(player)
        #else
        ZStack {
            palette.surface.ignoresSafeArea()

            HStack(spacing: 0) {
                playerColumn
                if showQueue {
                    QueueList(palette: palette)
                        .frame(width: 330)
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .sheet(isPresented: $showEQ) {
            EqualizerView(palette: palette) { showEQ = false }
                .environmentObject(player)
                .frame(width: 560, height: 640)
        }
        #endif
    }

    private var playerColumn: some View {
        VStack(spacing: 0) {
                topBar

                Spacer(minLength: 10)

                if let track {
                    CoverArt(track: track, cacheKey: track.albumKey,
                             radius: 34, palette: palette)
                        .frame(width: 300, height: 300)
                        .shadow(color: .black.opacity(0.35), radius: 34, y: 16)

                    VStack(spacing: 6) {
                        Text(track.title)
                            .font(.display(28, .semibold))
                            .foregroundStyle(palette.onSurface)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                        Text(track.artist)
                            .font(.body(15, .medium))
                            .foregroundStyle(palette.onSurfaceVariant)
                            .lineLimit(1)
                    }
                    .padding(.top, 26)
                    .padding(.horizontal, 40)
                }

                scrubber
                    .padding(.top, 28)
                    .frame(maxWidth: 460)

                transport
                    .padding(.top, 26)

                secondaryRow
                    .padding(.top, 20)

                Spacer(minLength: 16)
        }
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
    }

    private var topBar: some View {
        HStack {
            IconButton(system: "chevron.down", size: 40, glyph: 15,
                       fill: palette.surfaceContainer, foreground: palette.onSurface,
                       action: onDismiss)
            Spacer()
            Text(L("Now Playing"))
                .font(.label(13, .semibold))
                .foregroundStyle(palette.onSurfaceVariant)
            Spacer()
            IconButton(system: "list.bullet", size: 40, glyph: 15,
                       fill: showQueue ? palette.primary : palette.surfaceContainer,
                       foreground: showQueue ? palette.onPrimary : palette.onSurface) {
                withAnimation(.snappy(duration: 0.28)) { showQueue.toggle() }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 34)
    }

    private var scrubber: some View {
        VStack(spacing: 6) {
            MascotScrubber(
                progress: player.duration > 0 ? shownTime / player.duration : 0,
                isAnimating: player.isPlaying,
                height: 56, mascotSize: 40, trackWidth: 5,
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
            .font(.ticker(12))
            .foregroundStyle(palette.onSurfaceVariant)
        }
        .padding(.horizontal, 30)
    }

    /// Wide pill side-buttons flanking a large squircle play/pause.
    private var transport: some View {
        HStack(spacing: 12) {
            Button { player.previous() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(palette.onPrimaryContainer)
                    .frame(width: 96, height: 66)
                    .background(RoundedRectangle(cornerRadius: 33, style: .continuous)
                        .fill(palette.primaryContainer.opacity(0.6)))
            }
            .buttonStyle(.plain)

            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(palette.onPrimary)
                    .frame(width: 108, height: 78)
                    .background(RoundedRectangle(cornerRadius: player.isPlaying ? 26 : 39,
                                                 style: .continuous)
                        .fill(palette.primary))
            }
            .buttonStyle(.plain)
            .animation(.spring(response: 0.32, dampingFraction: 0.7), value: player.isPlaying)

            Button { player.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(palette.onPrimaryContainer)
                    .frame(width: 96, height: 66)
                    .background(RoundedRectangle(cornerRadius: 33, style: .continuous)
                        .fill(palette.primaryContainer.opacity(0.6)))
            }
            .buttonStyle(.plain)
        }
    }

    private var secondaryRow: some View {
        HStack(spacing: 10) {
            toggleChip(system: "shuffle", isOn: player.isShuffled) {
                player.isShuffled.toggle()
            }
            toggleChip(system: player.repeatMode.symbol, isOn: player.repeatMode != .off) {
                cycleRepeat()
            }
            toggleChip(system: "slider.vertical.3", isOn: player.eqEnabled) { showEQ = true }
            volumeChip
        }
    }

    private func toggleChip(system: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isOn ? palette.onPrimary : palette.onSurfaceVariant)
                .frame(width: 62, height: 42)
                .background(Capsule().fill(isOn ? palette.primary : palette.surfaceContainerHigh))
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.2), value: isOn)
    }

    private var volumeChip: some View {
        HStack(spacing: 8) {
            Image(systemName: volumeIcon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.onSurfaceVariant)
            Slider(value: $player.volume, in: 0...1)
                .controlSize(.small)
                .tint(palette.primary)
                .frame(width: 92)
        }
        .padding(.horizontal, 16)
        .frame(height: 42)
        .background(Capsule().fill(palette.surfaceContainerHigh))
    }

    private var volumeIcon: String {
        switch player.volume {
        case ..<0.01: return "speaker.slash.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    private func cycleRepeat() {
        switch player.repeatMode {
        case .off: player.repeatMode = .all
        case .all: player.repeatMode = .one
        case .one: player.repeatMode = .off
        }
    }
}

// MARK: - Queue

/// Up-next list, shown beside the player.
struct QueueList: View {
    let palette: M3Palette

    @EnvironmentObject var player: AudioPlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(L("Up next"))
                    .font(.display(19, .semibold))
                    .foregroundStyle(palette.onSurface)
                if player.isShuffled {
                    Image(systemName: "shuffle")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(palette.primary)
                }
                Spacer()
                Text("\(player.upNext.count)")
                    .font(.ticker(12))
                    .foregroundStyle(palette.onSurfaceVariant)
            }
            .padding(.horizontal, 20)
            .padding(.top, 36)
            .padding(.bottom, 14)

            if player.upNext.isEmpty {
                Spacer()
                Text(L("Nothing queued"))
                    .font(.body(13))
                    .foregroundStyle(palette.onSurfaceVariant)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(player.upNext.enumerated()), id: \.offset) { _, track in
                            QueueRow(track: track, palette: palette)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 24)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(palette.surfaceContainer)
    }
}

private struct QueueRow: View {
    let track: Track
    let palette: M3Palette

    @EnvironmentObject var player: AudioPlayer
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 11) {
            CoverArt(track: track, cacheKey: track.albumKey,
                     radius: 8, palette: palette)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(.body(12.5, .medium))
                    .foregroundStyle(palette.onSurface)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.body(10.5))
                    .foregroundStyle(palette.onSurfaceVariant)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Text(formatTime(track.duration))
                .font(.ticker(10.5))
                .foregroundStyle(palette.onSurfaceVariant)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isHovering ? palette.surfaceContainerHigh : .clear)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        #if os(iOS)
        .onTapGesture { player.play(track, in: player.queue) }
        #else
        .onTapGesture(count: 2) { player.play(track, in: player.queue) }
        #endif
        .animation(.easeOut(duration: 0.14), value: isHovering)
    }
}
