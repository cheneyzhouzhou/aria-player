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

    @State private var lyrics: Lyrics?
    @State private var loaded = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(palette.surfaceContainerHigh.opacity(0.55))

            content
        }
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
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
                                                 ? palette.onSurface
                                                 : palette.onSurfaceVariant.opacity(0.7))
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .animation(.easeOut(duration: 0.2), value: active)
                                .id(line.id)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 34)
                }
                .onAppear { scroll(proxy, to: active, in: lyrics) }
                .onChange(of: active) { _, new in
                    scroll(proxy, to: new, in: lyrics)
                }
            }
        } else if loaded {
            VStack(spacing: 10) {
                Image(systemName: "text.quote")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(palette.onSurfaceVariant)
                Text(L("No lyrics"))
                    .font(.display(18, .semibold))
                    .foregroundStyle(palette.onSurface)
                Text(L("Add a .lrc file with the same name beside the audio file, or embed lyrics in the file's tags."))
                    .font(.body(11.5))
                    .foregroundStyle(palette.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 26)
            }
        } else {
            ProgressView().tint(palette.primary)
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
