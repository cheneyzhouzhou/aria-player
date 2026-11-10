import SwiftUI

// MARK: - Buttons

/// Material's filled / tonal / text button, as one style.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case filled, tonal, text }

    var kind: Kind = .filled
    var palette: M3Palette
    var size: CGFloat = 15
    var padding: EdgeInsets = EdgeInsets(top: 11, leading: 22, bottom: 11, trailing: 22)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.label(size, .semibold))
            // A pill is sized by its own text; letting the label compress turns
            // "Shuffle" into one letter per line when the row runs out of
            // room. Keeping it at its ideal width makes the enclosing
            // `ViewThatFits` notice and pick a layout that actually fits.
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(foreground)
            .padding(padding)
            .background(background)
            .clipShape(Capsule())
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch kind {
        case .filled: return palette.onPrimary
        case .tonal: return palette.onPrimaryContainer
        case .text: return palette.primary
        }
    }

    @ViewBuilder
    private var background: some View {
        switch kind {
        case .filled: palette.primary
        case .tonal: palette.primaryContainer
        case .text: Color.clear
        }
    }
}

/// Circular or squircle icon button used across the chrome and transport.
struct IconButton: View {
    let system: String
    var size: CGFloat = 40
    var glyph: CGFloat = 16
    var fill: Color
    var foreground: Color
    var radius: CGFloat? = nil          // nil → fully round
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: glyph, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .background(fill)
                .clipShape(RoundedRectangle(cornerRadius: radius ?? size / 2, style: .continuous))
        }
        .buttonStyle(.plain)
        .brightness(isHovering ? 0.06 : 0)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovering)
    }
}

// MARK: - Chips

/// Material filter chip — the SONGS / ALBUMS / ARTISTS row.
struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let palette: M3Palette
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.label(13, .semibold))
                .foregroundStyle(isSelected ? palette.onPrimaryContainer : palette.onSurfaceVariant)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background {
                    Capsule()
                        .fill(isSelected ? palette.primaryContainer
                                         : (isHovering ? palette.surfaceContainerHigh : palette.surfaceContainer))
                }
                .overlay {
                    if !isSelected {
                        Capsule().strokeBorder(palette.outline.opacity(0.35), lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.snappy(duration: 0.18), value: isSelected)
        .animation(.easeOut(duration: 0.14), value: isHovering)
    }
}

// MARK: - Navigation rail

/// Material navigation rail item: a pill grows behind the icon when active.
struct RailItem: View {
    let system: String
    let title: String
    let isSelected: Bool
    let palette: M3Palette
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: system)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(isSelected ? palette.onPrimaryContainer : palette.onSurfaceVariant)
                    .frame(width: 54, height: 32)
                    .background {
                        Capsule()
                            .fill(isSelected ? palette.primaryContainer
                                             : (isHovering ? palette.surfaceContainerHigh : .clear))
                    }
                Text(title)
                    .font(.label(10.5, isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? palette.onSurface : palette.onSurfaceVariant)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.snappy(duration: 0.2), value: isSelected)
        .animation(.easeOut(duration: 0.14), value: isHovering)
    }
}

// MARK: - Search

struct SearchPill: View {
    @Binding var text: String
    var palette: M3Palette
    var prompt: String = "Songs, albums, artists"
    var width: CGFloat? = 300

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.onSurfaceVariant)

            TextField(L(prompt), text: $text)
                .textFieldStyle(.plain)
                .font(.body(13))
                .foregroundStyle(palette.onSurface)

            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.onSurfaceVariant)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(width: width)
        .background(Capsule().fill(palette.surfaceContainer))
    }
}

// MARK: - Cards

/// Rounded container used for list rows and grouped content.
struct SurfaceCard<Content: View>: View {
    var fill: Color
    var radius: CGFloat = Radius.card
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
    }
}

/// Album art with the standard squircle and a tinted placeholder.
struct CoverArt: View {
    let track: Track?
    let cacheKey: String
    var radius: CGFloat = Radius.art
    var palette: M3Palette
    /// Shown in place of the empty-state music note when a track has no
    /// artwork of its own (e.g. a bundled default sleeve). Keeps the player
    /// from branching on "no artwork" — the cover is always a cover.
    var fallback: PlatformImage? = nil

    @State private var image: PlatformImage?

    var body: some View {
        ZStack {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else if let fallback {
                Image(platformImage: fallback)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                palette.surfaceContainerHigh
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 17, weight: .light))
                            .foregroundStyle(palette.onSurfaceVariant.opacity(0.7))
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .task(id: cacheKey) { load() }
    }

    private func load() {
        guard let track else { image = nil; return }
        if let hit = ArtworkCache.shared.cached(for: cacheKey) {
            image = hit
            return
        }
        #if os(iOS)
        // Music app items have no file to read art bytes from; the artwork is
        // decoded lazily from the media item and cached under the album key.
        if let mediaArt = MediaLibraryAccess.shared.artwork(for: cacheKey) {
            ArtworkCache.shared.store(mediaArt, for: cacheKey)
            image = mediaArt
            return
        }
        #endif
        // Nothing cached yet. Keep whatever is on screen while the new art
        // decodes: clearing it here is what made the floating bar "light up"
        // on every track change — the tinted placeholder is far brighter than
        // most sleeves and only showed for a couple of frames.
        guard track.hasArtwork else { image = nil; return }
        ArtworkCache.shared.artwork(for: track, key: cacheKey) { loaded in
            guard let loaded else { return }
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
    }
}
