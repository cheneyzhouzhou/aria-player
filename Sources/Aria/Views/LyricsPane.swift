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
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(lyrics.lines.enumerated()), id: \.element.id) { index, line in
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(.body(index == active ? 18 : 15,
                                            index == active ? .semibold : .regular))
                                .foregroundStyle(index == active
                                                 ? primary
                                                 : secondary.opacity(0.7))
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .animation(.easeOut(duration: 0.2), value: active)
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

    private func scroll(_ proxy: ScrollViewProxy, to index: Int?, in lyrics: Lyrics) {
        guard let index, lyrics.lines.indices.contains(index) else { return }
        withAnimation(.easeInOut(duration: 0.35)) {
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
