import SwiftUI

/// A small floating button that brings the playing song back into view.
///
/// It is deliberately a leaf: the player is observed *here* only, so the 0.15 s
/// playhead never rebuilds the list underneath (and never disturbs a row's ⋯
/// menu). Lists hand it their scroll proxy and their own track order.
struct NowPlayingLocator: View {
    let tracks: [Track]
    let proxy: ScrollViewProxy

    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.palette) private var palette
    /// The glass theme has to look like glass here too, and it must repaint
    /// when the transparency slider moves.
    @ObservedObject private var appearance = AppearanceSettings.shared
    @State private var pressed = false

    private var playingID: String? {
        guard let id = player.current?.id,
              tracks.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    var body: some View {
        if let playingID {
            Button {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                    proxy.scrollTo(playingID, anchor: .center)
                }
                pressed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { pressed = false }
            } label: {
                // Light tonal surface with the theme accent in the glyph: a
                // solid `primary` disc read as a dark blob over the list, and
                // the point of this button is to stay quiet until wanted.
                Image(systemName: "scope")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.primary)
                    .frame(width: 42, height: 42)
                    .background {
                        // Glass theme: the same frosted material as the rest of
                        // the floating chrome, so the button belongs to the
                        // theme instead of sitting on top of it as a solid disc.
                        if appearance.usesGlass {
                            GlassSurface(shape: Circle(), tint: palette.surfaceContainer,
                                         border: palette.outline, radius: 21, strong: true)
                        } else {
                            Circle()
                                .fill(palette.primaryContainer)
                                .overlay(Circle().stroke(palette.primary.opacity(0.22),
                                                         lineWidth: 0.8))
                                .shadow(color: .black.opacity(0.12), radius: 7, y: 3)
                        }
                    }
                    .scaleEffect(pressed ? 0.90 : 1)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Locate now playing"))
            .animation(.spring(response: 0.30, dampingFraction: 0.72), value: playingID)
            .transition(.scale.combined(with: .opacity))
        }
    }
}
