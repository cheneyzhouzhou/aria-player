import SwiftUI

/// The lyric sheet that replaces the album cover in Now Playing.
///
/// Lines scroll themselves: the clock comes from the player, so a line lights
/// up when the song reaches it, and the list follows unless the user is the one
/// scrolling.
struct LyricsPane: View {
    let track: Track
    let currentTime: Double
    let palette: M3Palette
    let onTap: () -> Void

    /// Draw the translucent panel behind the lines. The iOS player turns this
    /// off so the lyrics sit directly on the blurred-cover backdrop instead of
    /// appearing as a separate solid card.
    var showsPanel: Bool = true
    /// Foreground overrides for a dark, artwork-derived background.
    var primaryColor: Color? = nil
    var secondaryColor: Color? = nil
    var accentColor: Color? = nil

    @State private var lyrics: Lyrics?
    @State private var loaded = false

    private var primary: Color { primaryColor ?? palette.onSurface }
    private var secondary: Color { secondaryColor ?? palette.onSurfaceVariant }

    /// Lines dissolve into the background at the top and bottom edges instead
    /// of being cut off by the pane — the same treatment the macOS stage
    /// lyrics use, scaled down for the phone's square lyric sheet.
    private var edgeFade: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .white, location: 0.20),
                .init(color: .white, location: 0.80),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top, endPoint: .bottom
        )
    }

    var body: some View {
        ZStack {
            if showsPanel {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(palette.surfaceContainerHigh.opacity(0.55))
            }

            content
        }
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .task(id: track.id) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let lyrics, !lyrics.isEmpty {
            let active = lyrics.index(at: currentTime)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .center, spacing: 16) {
                        ForEach(Array(lyrics.lines.enumerated()), id: \.element.id) { index, line in
                            lyricLine(index: index, line: line, active: active, in: lyrics)
                                .id(line.id)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 34)
                }
                // Fade the scrolling sheet at both edges, so a line that is
                // only half in view melts away rather than ending in a hard
                // cut across the glyphs.
                .mask(edgeFade)
                .onAppear { scroll(proxy, to: active, in: lyrics) }
                .onChange(of: active) { _, new in
                    scroll(proxy, to: new, in: lyrics)
                }
            }
        } else if loaded {
            VStack(spacing: 10) {
                Image(systemName: "text.quote")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(secondary)
                Text(L("No lyrics"))
                    .font(.display(18, .semibold))
                    .foregroundStyle(primary)
                Text(L("Add a .lrc file with the same name beside the audio file, or embed lyrics in the file's tags."))
                    .font(.body(11.5))
                    .foregroundStyle(secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 26)
            }
        } else {
            ProgressView().tint(accentColor ?? palette.primary)
        }
    }

    /// One line, drawn the way the reference player draws it: the current line
    /// grows with a springy overshoot and is filled left-to-right behind a soft
    /// masked edge as it is sung. Every other line stays crisp — the reference
    /// separates rows by weight and opacity, not by blurring them.
    @ViewBuilder
    private func lyricLine(index: Int, line: LyricLine, active: Int?, in lyrics: Lyrics) -> some View {
        let isActive = index == active
        let text = line.text.isEmpty ? "♪" : line.text
        let wipe = fillProgress(index: index, active: active, in: lyrics)

        // Font on each Text: the mask measures its own view, so a font applied
        // outside would size the mask by the default type instead.
        let font = Font.body(18, isActive ? .semibold : .regular)

        ZStack {
            // Every row shares one size and a low base alpha; the sweep is what
            // marks the current line, exactly as the reference renderer does.
            Text(text)
                .font(font)
                .foregroundStyle(isActive ? primary.opacity(0.24) : secondary.opacity(0.5))
            if isActive {
                Text(text)
                    .font(font)
                    .foregroundStyle(primary)
                    .mask {
                        LinearGradient(stops: [
                            .init(color: .white, location: max(0, wipe - 0.10)),
                            .init(color: .white.opacity(0), location: min(1, wipe))
                        ], startPoint: .leading, endPoint: .trailing)
                    }
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, alignment: .center)
        .scaleEffect(isActive ? 1.085 : 1)
        // The playhead arrives every 0.15 s; easing each step over that same
        // interval keeps the fill sliding instead of jumping.
        .animation(.linear(duration: 0.15), value: wipe)
        // Overshoot on purpose: the line should land with a small bounce.
        .animation(.spring(response: 0.42, dampingFraction: 0.62), value: active)
    }

    /// How much of the line has been sung, 0...1. LRC only carries line times,
    /// so the run up to the next line is spread evenly across the text.
    private func fillProgress(index: Int, active: Int?, in lyrics: Lyrics) -> Double {
        guard let active else { return 0 }
        if index < active { return 1 }
        guard index == active else { return 0 }
        let start = lyrics.lines[index].time
        let end = index + 1 < lyrics.lines.count
            ? lyrics.lines[index + 1].time
            : start + 4
        guard end > start else { return 1 }
        return min(1, max(0, (currentTime - start) / (end - start)))
    }

    private func scroll(_ proxy: ScrollViewProxy, to index: Int?, in lyrics: Lyrics) {
        guard let index, lyrics.lines.indices.contains(index) else { return }
        // A spring rather than a fixed ease: lines catch up and settle, the way
        // the reference player's scroll does (mass 1 / stiffness 100 / damping 20).
        withAnimation(.interpolatingSpring(mass: 1, stiffness: 100, damping: 20)) {
            proxy.scrollTo(lyrics.lines[index].id, anchor: .center)
        }
    }

    private func load() async {
        loaded = false
        lyrics = nil
        let parsed = await Task.detached(priority: .userInitiated) {
            Lyrics.load(for: track)
        }.value
        lyrics = parsed
        loaded = true
    }
}
