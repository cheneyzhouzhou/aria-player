import SwiftUI

// MARK: - Theme selection

/// The two presentation themes Aria offers.
///
/// - `solid`  — the original Material-style flat colour (current app look).
/// - `glass`  — raised panels become frosted, themed glass that blurs whatever
///              sits behind them. The whole window shares one soft gradient
///              field so the result reads as a single cohesive surface, rather
///              than the many separate floating cards some players use.
enum AppearanceTheme: String, CaseIterable, Identifiable {
    case solid, glass
    var id: String { rawValue }

    var title: String { self == .solid ? L("Solid") : L("Frosted glass") }
    /// Lets the settings picker draw a representative mock for each option.
    var isGlass: Bool { self == .glass }
}

/// Light / dark appearance, independent of the system setting.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L("System")
        case .light: return L("Light")
        case .dark: return L("Dark")
        }
    }

    /// `nil` follows the system; otherwise it forces that scheme app-wide.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Single source of truth for the chosen theme, persisted across launches.
///
/// A singleton so every window (the main window and the ⌘, settings window)
/// observes the same value and re-renders together the instant it changes.
/// Kept off the main actor (like `LanguageSettings`) since it only touches
/// `UserDefaults` and `@Published` state on the main thread.
final class AppearanceSettings: ObservableObject {
    static let shared = AppearanceSettings()

    @Published var theme: AppearanceTheme
    /// Light / dark / follow-system, applied app-wide via `preferredColorScheme`.
    @Published var mode: AppearanceMode

    init() {
        let raw = UserDefaults.standard.string(forKey: "ariaAppearanceTheme")
        theme = AppearanceTheme(rawValue: raw ?? "") ?? .solid
        let rawMode = UserDefaults.standard.string(forKey: "ariaAppearanceMode")
        mode = AppearanceMode(rawValue: rawMode ?? "") ?? .system
    }

    /// Persist and publish in one step.
    func set(_ next: AppearanceTheme) {
        theme = next
        UserDefaults.standard.set(next.rawValue, forKey: "ariaAppearanceTheme")
    }

    func setMode(_ next: AppearanceMode) {
        mode = next
        UserDefaults.standard.set(next.rawValue, forKey: "ariaAppearanceMode")
    }

    var usesGlass: Bool { theme == .glass }
}

// MARK: - Frosted blur

#if os(iOS)
import UIKit
/// iOS backdrop blur: a `UIVisualEffectView` with a material blur. The corner
/// radius is applied to the layer so the frosted region itself is rounded.
private struct PlatformBlur: UIViewRepresentable {
    var cornerRadius: CGFloat
    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        view.layer.cornerRadius = cornerRadius
        view.clipsToBounds = true
        return view
    }
    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.layer.cornerRadius = cornerRadius
    }
}
#else
import AppKit
/// macOS backdrop blur: an `NSVisualEffectView`, blurred against the content
/// within the same window so the gradient field behind each panel shows through.
private struct PlatformBlur: NSViewRepresentable {
    var cornerRadius: CGFloat
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .withinWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.layer?.cornerRadius = cornerRadius
    }
}
#endif

/// Cross-platform wrapper around the platform blur view.
struct BlurEffectView: View {
    var cornerRadius: CGFloat = Radius.card
    var body: some View { PlatformBlur(cornerRadius: cornerRadius) }
}

// MARK: - Glass surface

/// A frosted, themed panel: a real backdrop blur, a translucent tint of the
/// Material role's colour, and a hairline border. Replacing a flat
/// `surfaceContainer` fill with this is what turns a screen into the glass theme.
struct GlassSurface<S: Shape>: View {
    let shape: S
    let tint: Color
    let border: Color
    var radius: CGFloat = Radius.card
    var showBorder: Bool = true
    /// A denser frost for the big containers that float over the background
    /// (the rail, the page, the mini player, the phone nav bar).
    var strong: Bool = false
    /// The player's popups: translucent enough to see the artwork, dark enough
    /// to keep their light text legible.
    var popup: Bool = false

    @Environment(\.colorScheme) private var scheme

    /// White-frost fill following the reference's glass tokens — white at low
    /// alpha in light mode, a dark navy at higher alpha in dark mode. The colour
    /// comes from the aurora behind the panel, not from the fill itself, which
    /// is what makes it read as real glass.
    private var fill: Color {
        if popup {
            return scheme == .dark
                ? Color(red: 0.04, green: 0.04, blue: 0.08).opacity(0.72)
                : Color(red: 0.10, green: 0.10, blue: 0.16).opacity(0.55)
        }
        if strong {
            return scheme == .dark
                ? Color(red: 0.05, green: 0.05, blue: 0.09).opacity(0.55)
                : .white.opacity(0.34)
        }
        return scheme == .dark ? .white.opacity(0.05) : .white.opacity(0.16)
    }

    private var hairline: Color {
        .white.opacity(scheme == .dark ? 0.10 : 0.24)
    }

    var body: some View {
        ZStack {
            BlurEffectView(cornerRadius: radius)
            fill
            // The lit top rim that sells the "glass" read.
            shape.fill(
                LinearGradient(
                    colors: [.white.opacity(scheme == .dark ? 0.10 : 0.26), .clear],
                    startPoint: .top, endPoint: .center)
            )
            .allowsHitTesting(false)
        }
        .clipShape(shape)
        .overlay {
            if showBorder {
                shape.stroke(hairline, lineWidth: 1)
            }
        }
        .shadow(color: .black.opacity(scheme == .dark ? 0.30 : 0.10),
                radius: strong ? 22 : 12,
                y: strong ? 10 : 6)
    }
}

// MARK: - Surface roles

/// The two elevated surface levels Aria paints. Each resolves to the existing
/// Material colour in the `solid` theme, or to a frosted glass surface in the
/// `glass` theme — so switching is a single decision with no per-screen logic.
enum SurfaceRole {
    /// Sections, panels, sidebars — the largest containers.
    case panel
    /// Cards, list rows, raised chips — sits one step above the panel.
    case raised

    func solid(_ palette: M3Palette) -> Color {
        switch self {
        case .panel: return palette.surfaceContainer
        case .raised: return palette.surfaceContainerHigh
        }
    }
}

extension SurfaceRole {
    /// The background for a surface of this role, as a `View` so it can be
    /// dropped into a `.background { }` closure. `override` takes precedence
    /// (e.g. a selected/highlighted state) and is never glassed.
    @ViewBuilder
    func background(_ palette: M3Palette, shape: AnyShape, radius: CGFloat,
                   override: Color? = nil, strong: Bool = false,
                   popup: Bool = false) -> some View {
        if let override {
            shape.fill(override)
        } else if AppearanceSettings.shared.usesGlass {
            GlassSurface(shape: shape, tint: solid(palette),
                         border: palette.outline, radius: radius,
                         strong: strong, popup: popup)
        } else {
            shape.fill(solid(palette))
        }
    }
}

// MARK: - Window base

/// The app's base background. In the glass theme this is a soft, hue-derived
/// gradient so the frosted panels have something rich to blur; in the solid
/// theme it is the flat Material surface.
func AppBackground(_ palette: M3Palette) -> some View {
    Group {
        if AppearanceSettings.shared.usesGlass {
            glassBackdrop(palette)
        } else {
            palette.surface
        }
    }
}

/// The palette the player's popups (EQ, audio chain, queue) paint with, in
/// **both** themes.
///
/// The player's own backdrop is the artwork blurred and darkened by a scrim;
/// these panels sit on it, so they take a **dark, low-chroma** companion of the
/// now-playing palette (same artwork-derived hue as the stage, just muted and
/// dark) rather than the vivid one. That keeps the popup's colour in the same
/// family as the background behind it — no bright, saturated slab — and the
/// light-on-dark text stays legible. Solid and glass differ only in how the
/// panel is rendered (opaque vs frosted), never in where its colour comes from.
func playerOverlayPalette(_ palette: M3Palette) -> M3Palette {
    let seed = PaletteSeed(hue: palette.seed.hue,
                           chroma: min(palette.seed.chroma, 0.18))
    return M3Palette(seed: seed, isDark: true, vivid: false)
}

/// The colour field behind the glass: a vivid, slowly drifting aurora built from
/// the palette's hue plus a couple of neighbours, with a soft light veil in
/// light mode. White-frost panels only read as *glass* when there is real colour
/// underneath to blur — and the slow motion is what the reference player's
/// animated background gives the glass its life.
private func glassBackdrop(_ palette: M3Palette) -> some View {
    GlassAurora(palette: palette)
}

/// A `TimelineView`-driven aurora. Two large radial "blobs" orbit slowly over a
/// base gradient, so the colour behind the glass keeps shifting without any
/// per-frame layout work in the rest of the UI. Honours Reduce Motion by
/// freezing to the first frame.
struct GlassAurora: View {
    let palette: M3Palette

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            field(at: 0)
        } else {
            // ~18 fps is plenty for a slow ambient drift and keeps the GPU cost
            // low while the window is open.
            TimelineView(.animation(minimumInterval: 1.0 / 18.0)) { context in
                field(at: context.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func field(at time: Double) -> some View {
        let dim = palette.isDark
        let hue = palette.seed.hue
        func wrap(_ v: Double) -> Double { (v + 1).truncatingRemainder(dividingBy: 1) }

        let slow = time * 0.10
        let slower = time * 0.074

        let base1 = Color(hue: wrap(hue - 0.06), saturation: 0.72, brightness: dim ? 0.52 : 0.96)
        let base2 = Color(hue: wrap(hue + 0.08), saturation: 0.74, brightness: dim ? 0.44 : 0.92)
        let base3 = Color(hue: wrap(hue + 0.22), saturation: 0.60, brightness: dim ? 0.34 : 0.88)
        let blobWarm = Color(hue: wrap(hue + 0.62), saturation: 0.60, brightness: dim ? 0.40 : 0.92)
        let blobCool = Color(hue: wrap(hue - 0.42), saturation: 0.55, brightness: dim ? 0.30 : 0.90)

        return ZStack {
            LinearGradient(colors: [base1, base2, base3],
                           startPoint: .topLeading, endPoint: .bottomTrailing)

            RadialGradient(
                colors: [blobWarm.opacity(0.85), .clear],
                center: UnitPoint(x: 0.62 + 0.24 * cos(slow),
                                  y: 0.22 + 0.18 * sin(slow * 0.9)),
                startRadius: 0, endRadius: 860
            )

            RadialGradient(
                colors: [blobCool.opacity(0.70), .clear],
                center: UnitPoint(x: 0.32 + 0.24 * cos(slower + 1.7),
                                  y: 0.80 + 0.16 * sin(slower)),
                startRadius: 0, endRadius: 740
            )

            if !dim {
                // Soften light mode with a white veil so text and glass stay calm
                // over the saturated aurora.
                LinearGradient(colors: [.white.opacity(0.52), .white.opacity(0.30)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
    }
}
