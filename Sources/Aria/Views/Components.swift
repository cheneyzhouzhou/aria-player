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
            // Plain buttons only answer clicks on their drawn pixels, so the
            // label under the icon — thin glyphs plus the gap around them —
            // was nearly unhittable. One rectangular content shape over the
            // whole item makes the icon, the gap and the title one target.
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
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
    var focus: Binding<Bool>? = nil

    @State private var ownFocused = false
    private var activeFocus: Binding<Bool> { focus ?? $ownFocused }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.onSurfaceVariant)

            #if os(iOS)
            NativeSearchField(text: $text, prompt: L(prompt),
                              focused: activeFocus, doneTitle: L("Done"))
                // Match the old SwiftUI field's intrinsic height; 40 padded
                // the capsule out to 60pt tall and looked inflated.
                .frame(height: 24)
            #else
            TextField(L(prompt), text: $text)
                .textFieldStyle(.plain)
                .font(.body(13))
                .foregroundStyle(palette.onSurface)
            #endif

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
        // Fixed height rather than padding: the native field has no intrinsic
        // height, so padding alone let the capsule grow well past its old size.
        .frame(height: 37)
        .frame(width: width)
        .background(Capsule().fill(palette.surfaceContainer))
    }
}

#if os(iOS)
/// A real UIKit text field. SwiftUI's FocusState binding proved unreliable
/// here: a tap could leave the field unfocused with no keyboard at all.
/// UIKit's first-responder call is explicit and cannot be lost in a body
/// recompute.
struct NativeSearchField: UIViewRepresentable {
    @Binding var text: String
    let prompt: String
    @Binding var focused: Bool
    let doneTitle: String

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.borderStyle = .none
        field.font = .systemFont(ofSize: 13)
        field.textColor = UIColor.label
        field.placeholder = prompt
        field.text = text
        field.returnKeyType = .done
        field.autocorrectionType = .no
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed),
                        for: .editingChanged)

        let toolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
        toolbar.items = [
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            UIBarButtonItem(title: doneTitle, style: .done,
                            target: context.coordinator,
                            action: #selector(Coordinator.done))
        ]
        toolbar.sizeToFit()
        field.inputAccessoryView = toolbar

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.tapped))
        field.addGestureRecognizer(tap)
        context.coordinator.field = field
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        if field.text != text { field.text = text }
        // Only ever *raise* the keyboard here. A tap makes UIKit focus the
        // field on its own; resigning from this update ran with a still-false
        // binding and killed the keyboard in the same run loop, which read as
        // "tapping does nothing". Dismissal is handled explicitly by the page.
        if focused, !field.isFirstResponder {
            DispatchQueue.main.async { field.becomeFirstResponder() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: NativeSearchField
        weak var field: UITextField?

        init(_ parent: NativeSearchField) { self.parent = parent }

        @objc func changed(_ field: UITextField) { parent.text = field.text ?? "" }
        @objc func done() { parent.focused = false }
        @objc func tapped() {
            field?.becomeFirstResponder()
            parent.focused = true
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            parent.focused = false
            return true
        }
        func textFieldDidBeginEditing(_ field: UITextField) { parent.focused = true }
        func textFieldDidEndEditing(_ field: UITextField) { parent.focused = false }
    }
}
#endif

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

/// Time-based spin state. Pausing captures the exact angle at that instant
/// and freezes it, so no animation-cancellation trick is needed and thedisc
/// cannot jump back to an older position on a real device.
private final class SpinClock: ObservableObject {
    @Published private(set) var baseAngle: Double = 0
    private(set) var startedAt = Date()
    @Published private(set) var frozen = true
    /// 18 seconds per revolution.
    private let rate: Double = 20

    func angle(at date: Date) -> Double {
        guard !frozen else { return baseAngle }
        return (baseAngle + date.timeIntervalSince(startedAt) * rate)
            .truncatingRemainder(dividingBy: 360)
    }

    func pause(at date: Date) {
        baseAngle = angle(at: date)
        startedAt = date
        frozen = true
    }

    func resume(at date: Date) {
        startedAt = date
        frozen = false
    }
}

private struct SpinAngle: Animatable, ViewModifier {
    var angle: Double
    var onAngle: (Double) -> Void

    var animatableData: Double {
        get { angle }
        set { angle = newValue; onAngle(newValue) }
    }

    func body(content: Content) -> some View {
        content.rotationEffect(.degrees(angle))
    }
}

/// Artwork clipped to a circle and spun like a record while audio plays.
/// The rotation is a compositor-driven linear animation (60 fps) rather than
/// a timer: a 30 fps state timer made the disc visibly step. Pausing pins the
/// angle where it stands instead of snapping back to zero.
struct SpinningCover: View {
    let track: Track?
    let cacheKey: String
    var radius: CGFloat = Radius.art
    let palette: M3Palette
    var fallback: PlatformImage? = nil
    let isPlaying: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var appearance = AppearanceSettings.shared
    @StateObject private var clock = SpinClock()

    var body: some View {
        Group {
            if appearance.vinylRecords {
                GeometryReader { geo in
                    let side = min(geo.size.width, geo.size.height)
                    let disc = side * 0.94
                    // At 42pt the frost and groove highlights washed the band
                    // out to mid-grey. Keep the compact record much darker.
                    let compact = side < 90
                    // When the clock is frozen (no playback) the timeline
                    // stops entirely: 60 fps no-op redraws were needless work
                    // and could starve input on a real device.
                    TimelineView(.animation(minimumInterval: nil,
                                            paused: clock.frozen)) { timeline in
                    ZStack {
                        Circle()
                            .stroke(Color.black.opacity(compact ? 0.25 : 0.14),
                                    lineWidth: side * 0.018)
                            .frame(width: disc * 1.035, height: disc * 1.035)

                        ZStack {
                            Circle().fill(Color(white: compact ? 0.02 : 0.10))
                            ForEach(1...26, id: \.self) { ring in
                                let d = disc * (0.72 + CGFloat(ring) * 0.009)
                                Circle()
                                    .stroke(Color.white.opacity(compact ? 0.045 : 0.07),
                                            lineWidth: 0.55)
                                    .frame(width: d, height: d)
                            }
                            CoverArt(track: track, cacheKey: cacheKey, radius: 999,
                                     palette: palette, fallback: fallback)
                                .clipShape(Circle())
                                .frame(width: disc * 0.70, height: disc * 0.70)
                                .overlay(Circle().stroke(Color.black.opacity(0.45),
                                                         lineWidth: side * 0.008))
                            Circle()
                                .fill(Color(white: 0.94).opacity(0.85))
                                .frame(width: max(2, side * 0.016),
                                       height: max(2, side * 0.016))
                        }
                        .frame(width: disc, height: disc)
                        .rotationEffect(.degrees(clock.angle(at: timeline.date)))

                        // Sheen is painted only on the black band, so the
                        // centre label keeps its own light. A bright grazing
                        // arc at upper-left and a dark falloff at lower-right
                        // are what make the edge read as glossy vinyl.
                        let label = disc * 0.70
                        let ringSide = (disc + label) / 2
                        let ringWidth = (disc - label) / 2
                        Circle()
                            .stroke(LinearGradient(
                                stops: [
                                    .init(color: .white.opacity(compact ? 0.60 : 0.32), location: 0),
                                    .init(color: .white.opacity(compact ? 0.22 : 0.10), location: 0.28),
                                    .init(color: .clear, location: 0.55)
                                ],
                                startPoint: .topLeading, endPoint: .bottomTrailing),
                                style: StrokeStyle(lineWidth: ringWidth))
                            .frame(width: ringSide, height: ringSide)
                            .blendMode(.screen)
                            .allowsHitTesting(false)

                        Circle()
                            .stroke(LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0.42),
                                    .init(color: .black.opacity(compact ? 0.30 : 0.18), location: 1)
                                ],
                                startPoint: .topLeading, endPoint: .bottomTrailing),
                                style: StrokeStyle(lineWidth: ringWidth))
                            .frame(width: ringSide, height: ringSide)
                            .allowsHitTesting(false)
                    }
                    .frame(width: side, height: side)
                    }
                }
            } else {
                CoverArt(track: track, cacheKey: cacheKey, radius: radius,
                         palette: palette, fallback: fallback)
            }
        }
        .onChange(of: isPlaying) { _, playing in updateSpin(playing) }
        .onChange(of: appearance.vinylRecords) { _, on in updateSpin(on && isPlaying) }
        .onChange(of: reduceMotion) { _, reduced in updateSpin(!reduced && isPlaying) }
        .onAppear { updateSpin(isPlaying) }
    }

    private func updateSpin(_ playing: Bool) {
        let now = Date()
        if playing, appearance.vinylRecords, !reduceMotion {
            clock.resume(at: now)
        } else {
            clock.pause(at: now)
        }
    }
}
