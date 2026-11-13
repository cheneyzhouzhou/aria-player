import SwiftUI

// MARK: - Theme selection

/// The presentation themes Aria offers.
///
/// - `solid`   — the original Material-style flat colour, tinted from the
///               library hue.
/// - `morandi` — the same flat surfaces, but painted from one fixed, dusty
///               palette instead of the artwork/library hue.
/// - `glass`   — raised panels become frosted, themed glass that blurs whatever
///               sits behind them. The whole window shares one soft gradient
///               field so the result reads as a single cohesive surface, rather
///               than the many separate floating cards some players use.
enum AppearanceTheme: String, CaseIterable, Identifiable {
    case solid, morandi, glass
    var id: String { rawValue }

    var title: String {
        switch self {
        case .solid: return L("Solid")
        case .morandi: return L("Morandi")
        case .glass: return L("Frosted glass")
        }
    }
    /// Lets the settings picker draw a representative mock for each option.
    var isGlass: Bool { self == .glass }
    /// Flat surfaces painted from a fixed palette rather than a seed.
    var isMorandi: Bool { self == .morandi }
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
    /// The Morandi theme's accent hue (the dusty presets in Settings pick from
    /// these); persisted so the palette survives relaunches.
    @Published var morandiHue: Double {
        didSet { UserDefaults.standard.set(morandiHue, forKey: "ariaMorandiHue") }
    }
    /// How see-through the frosted theme's panels are: 0 = densest frost,
    /// 0.5 = the original look, 1 = most transparent. Persisted in didSet —
    /// the settings Slider binds straight to this property (v102 lesson).
    @Published var glassTransparency: Double {
        didSet {
            UserDefaults.standard.set(glassTransparency, forKey: "ariaGlassTransparency")
        }
    }

    init() {
        let raw = UserDefaults.standard.string(forKey: "ariaAppearanceTheme")
        theme = AppearanceTheme(rawValue: raw ?? "") ?? .solid
        // Fresh installs ship with Light (打包默认); an explicit choice always
        // wins over the default.
        let rawMode = UserDefaults.standard.string(forKey: "ariaAppearanceMode")
        if rawMode == nil {
            mode = .light
            UserDefaults.standard.set("light", forKey: "ariaAppearanceMode")
        } else {
            mode = AppearanceMode(rawValue: rawMode ?? "") ?? .light
        }
        morandiHue = UserDefaults.standard.object(forKey: "ariaMorandiHue") as? Double ?? 0.28
        let savedGlass = UserDefaults.standard.object(forKey: "ariaGlassTransparency") as? Double
        glassTransparency = min(max(savedGlass ?? 0.5, 0), 1)
        #if os(macOS)
        systemIsDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in self?.syncSystemDark() }
        #endif
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
    var usesMorandi: Bool { theme == .morandi }

    /// What the **system** appearance is right now — read from the global
    /// `AppleInterfaceStyle` default rather than the app's own resolved
    /// appearance, which `preferredColorScheme` overrides and would make the
    /// answer circular. Updated whenever macOS broadcasts a theme change.
    #if os(macOS)
    @Published private(set) var systemIsDark: Bool {
        didSet { }
    }
    #endif

    #if os(macOS)
    private func syncSystemDark() {
        let dark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        if dark != systemIsDark { systemIsDark = dark }
    }
    #endif
}

/// Applies the chosen appearance to a whole subtree while still being able to
/// *see* the system scheme.
///
/// The usual way to express "follow system" is `preferredColorScheme(nil)`, and
/// SwiftUI has a quirk there: *removing* an override does not re-resolve the
/// effective scheme, so the window keeps the old look until the next unrelated
/// update — the "have to tap twice" bug. Instead, this wrapper reads the system
/// scheme from its own environment (nothing above it overrides it) and always
/// applies an **explicit** resolved scheme below, which updates immediately and
/// keeps following the system afterwards.
struct AppearanceGate<Content: View>: View {
    @ObservedObject private var appearance = AppearanceSettings.shared
    @Environment(\.colorScheme) private var systemScheme
    @ViewBuilder var content: () -> Content

    /// The scheme applied below the gate. macOS always gets an explicit value
    /// (never `nil`): removing the override is what made 跟随系统 need a second
    /// click. iOS follows the system natively.
    private var resolvedScheme: ColorScheme? {
        #if os(macOS)
        appearance.mode == .system
            ? (appearance.systemIsDark ? .dark : .light)
            : appearance.mode.colorScheme
        #else
        appearance.mode == .system ? nil : appearance.mode.colorScheme
        #endif
    }

    var body: some View {
        content()
            .preferredColorScheme(resolvedScheme)
    }
}

/// The palette a window paints with, given the chosen theme.
///
/// Only the Morandi theme overrides the seed — everything else keeps taking its
/// colour from the library hue (or the artwork, on the player). The full-screen
/// player deliberately does not go through here: it always keeps its
/// artwork-derived palette, and only its popups follow the theme.
func themePalette(seed: PaletteSeed, isDark: Bool, vivid: Bool = false) -> M3Palette {
    AppearanceSettings.shared.usesMorandi
        ? .morandi(hue: AppearanceSettings.shared.morandiHue, isDark: isDark, vivid: vivid)
        : M3Palette(seed: seed, isDark: isDark, vivid: vivid)
}

// MARK: - Frosted blur

#if os(iOS)
import UIKit
/// iOS backdrop blur: a `UIVisualEffectView` with a material blur. The corner
/// radius is applied to the layer so the frosted region itself is rounded.
/// Player popups use the ultra-thin material: the regular one tints towards
/// opaque white and hides the artwork they are meant to reveal.
private struct PlatformBlur: UIViewRepresentable {
    var cornerRadius: CGFloat
    var thin: Bool = false
    var dark: Bool = false
    /// The glass group's presence (0...1): reaches 0 at 100% transparency so
    /// the blur layer contributes nothing at all.
    var opacity: CGFloat = 1
    private var style: UIBlurEffect.Style {
        if !thin { return .systemMaterial }
        return dark ? .systemUltraThinMaterialDark : .systemUltraThinMaterialLight
    }
    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: style))
        view.layer.cornerRadius = cornerRadius
        view.clipsToBounds = true
        view.alpha = opacity
        return view
    }
    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: style)
        uiView.alpha = opacity
        uiView.layer.cornerRadius = cornerRadius
    }
}
#else
import AppKit
/// macOS backdrop blur: an `NSVisualEffectView`, blurred against the content
/// within the same window so the gradient field behind each panel shows through.
private struct PlatformBlur: NSViewRepresentable {
    var cornerRadius: CGFloat
    var thin: Bool = false
    var dark: Bool = false
    /// The glass group's presence (0...1): reaches 0 at 100% transparency so
    /// the material contributes nothing at all.
    var opacity: CGFloat = 1
    private var material: NSVisualEffectView.Material {
        thin ? .menu : .hudWindow
    }
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .withinWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        view.alphaValue = opacity
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.alphaValue = opacity
        nsView.layer?.cornerRadius = cornerRadius
    }
}
#endif

/// Cross-platform wrapper around the platform blur view.
struct BlurEffectView: View {
    var cornerRadius: CGFloat = Radius.card
    var thin: Bool = false
    var dark: Bool = false
    var opacity: CGFloat = 1
    var body: some View {
        PlatformBlur(cornerRadius: cornerRadius, thin: thin,
                     dark: dark, opacity: opacity)
    }
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
    /// The player's popups (EQ, audio chain, queue) use the *same* glass as the
    /// floating player bar. `popup` is an alias for `strong` so there is no
    /// second look that can drift away from the bar's material.
    var popup: Bool = false

    @Environment(\.colorScheme) private var scheme
    /// Every glass surface observes the slider so dragging it repaints the
    /// whole window immediately, including the settings page itself.
    @ObservedObject private var appearance = AppearanceSettings.shared

    /// The slider is an *exact* two-ended control:
    /// - `0`   — a genuinely opaque card (a solid fill at alpha 1, no blur
    ///           contribution at all);
    /// - `0.5` — byte-for-byte the original v105 frosted glass (every scale
    ///           below is 1, nothing is added or faded);
    /// - `1`   — genuinely 100% transparent: no blur, no frost, no rim, no
    ///           border and no shadow — only the panel's own content remains.
    ///
    /// Below 50% a solid backing cross-fades in over the glass; above 50% the
    /// whole glass group fades out on top of the v107 thinning. Scaling every
    /// layer (rather than applying SwiftUI `.opacity` to the group) keeps the
    /// native blur view functional on both platforms.
    private var slider: Double {
        appearance.usesGlass ? appearance.glassTransparency : 0.5
    }
    /// Presence of the frosted-glass group. Exactly 0 at 100% transparency.
    private var glassPresence: CGFloat {
        let t = slider
        if t <= 0.5 { return CGFloat(t / 0.5) }              // 0 ... 1
        let u = (t - 0.5) / 0.5                               // 0 ... 1
        return CGFloat(max(0, 1 - u * u))                     // 1 ... 0
    }
    /// Presence of the solid backing that makes 0% genuinely opaque.
    private var opaquePresence: CGFloat {
        let t = slider
        return t < 0.5 ? CGFloat(1 - t / 0.5) : 0             // 1 ... 0
    }
    /// Outline and shadow follow whichever layer is present, so they are full
    /// strength at 0% and 50%, and completely gone at 100%.
    private var surfacePresence: CGFloat {
        max(glassPresence, opaquePresence)
    }
    private var frostScale: Double {
        let t = slider
        if t <= 0.5 { return 1 + (0.5 - t) * 3.0 }        // 1 ... 2.5
        return max(0.10, 1 - (t - 0.5) * 1.8)             // 1 ... 0.10
    }
    private var blurScale: CGFloat {
        let t = slider
        if t <= 0.5 { return 1 }
        return CGFloat(max(0.28, 1 - (t - 0.5) * 1.44))   // 1 ... 0.28
    }
    private func scaledFrost(_ base: Double, floor: Double = 0.01) -> Double {
        // Multiplying *after* the clamp is what makes 100% leave no milk film
        // at all — even the popup's 0.05 legibility floor has to disappear.
        min(0.95, max(floor, base * frostScale)) * Double(glassPresence)
    }

    /// White-frost fill following the reference's glass tokens — white at low
    /// alpha in light mode, a dark navy at higher alpha in dark mode. The colour
    /// comes from the aurora behind the panel, not from the fill itself, which
    /// is what makes it read as real glass.
    private var fill: Color {
        // Popups are now in-window cards with the real artwork behind them,
        // so they can carry a much thinner frost than the floating player bar
        // (0.34) and still keep their dark labels readable. The bar, nav bar
        // and page panels are untouched.
        if popup {
            // Fading the UIVisualEffectView to the shared 0.55 also weakens
            // its blur on iOS, so a touch more milk frost keeps the playback
            // controls behind the pane from punching through too sharply.
            // macOS's `.menu` material keeps its blur and stays at 0.10.
            #if os(iOS)
            let base: Double = popupsUseDarkPalette ? 0.10 : 0.20
            #else
            let base: Double = 0.10
            #endif
            // `scaledFrost` multiplies by glassPresence, so at 100% this film
            // reaches exactly zero and the panel is truly clear.
            return popupsUseDarkPalette
                ? Color(red: 0.05, green: 0.05, blue: 0.09).opacity(scaledFrost(base, floor: 0.05))
                : .white.opacity(scaledFrost(base, floor: 0.05))
        }
        if strong {
            return scheme == .dark
                ? Color(red: 0.05, green: 0.05, blue: 0.09).opacity(scaledFrost(0.55))
                : .white.opacity(scaledFrost(0.34))
        }
        return scheme == .dark
            ? .white.opacity(scaledFrost(0.05))
            : .white.opacity(scaledFrost(0.16))
    }

    /// The native blur view is faded by both the v107 thinning and the glass
    /// group's presence. Popups are no longer pinned to a floor: at 100% every
    /// glass surface — EQ, audio chain, queue included — must be fully clear,
    /// and at 0% the solid backing hides the blur entirely. At the 50% anchor
    /// popups stay at the shared 0.55, matching v108.
    private var blurOpacity: CGFloat {
        let base: CGFloat = popup ? 0.55 : 1
        return base * blurScale * glassPresence
    }

    private var hairline: Color {
        .white.opacity((scheme == .dark ? 0.10 : 0.24) * Double(glassPresence))
    }

    var body: some View {
        ZStack {
            // 0% endpoint — a genuinely opaque card. `tint` is the surface
            // role's own solid colour (alpha 1), so the artwork/aurora behind
            // the panel cannot show through at all. Inner cards get a subtle
            // elevation wash so the hierarchy survives once every surface is
            // solid; the hairline alone would be too faint in light mode.
            if opaquePresence > 0 {
                ZStack {
                    shape.fill(tint)
                    if !(strong || popup) {
                        shape.fill((scheme == .dark ? Color.white : Color.black)
                            .opacity(0.05))
                    }
                }
                .opacity(Double(opaquePresence))
            }
            BlurEffectView(cornerRadius: radius,
                           thin: popup && AppearanceSettings.shared.usesGlass,
                           dark: popupsUseDarkPalette,
                           opacity: blurOpacity)
            fill
            // The lit top rim that sells the "glass" read.
            shape.fill(
                LinearGradient(
                    colors: [.white.opacity((scheme == .dark ? 0.10 : 0.26)
                                            * Double(glassPresence)), .clear],
                    startPoint: .top, endPoint: .center)
            )
            .allowsHitTesting(false)
        }
        .clipShape(shape)
        .overlay {
            if showBorder {
                ZStack {
                    shape.stroke(hairline, lineWidth: 1)
                    if opaquePresence > 0 {
                        shape.stroke(border.opacity(0.45 * Double(opaquePresence)),
                                     lineWidth: 1)
                    }
                }
            }
        }
        .shadow(color: .black.opacity((scheme == .dark ? 0.30 : 0.10)
                                      * Double(surfacePresence)),
                radius: strong || popup ? 22 : 12,
                y: strong || popup ? 10 : 6)
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
        } else if popup {
            shape.fill(solid(palette))
                .overlay { shape.fill(palette.primaryContainer.opacity(0.25)) }
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

/// Solid / Morandi popup background: a soft wash of the theme's own container
/// colour over the surface. Without it the panel is a near-fixed white (light)
/// or black (dark) slab that does not read as part of the chosen theme.
func popupPanelFill(_ palette: M3Palette) -> some View {
    ZStack {
        palette.surface
        palette.primaryContainer.opacity(0.25)
    }
}

/// The palette the player's popups (EQ, audio chain, queue) paint with.
///
/// Every theme follows the resolved appearance: light panels with dark labels
/// in light mode, dark panels with light labels in dark mode. Solid / Morandi
/// used to be forced dark, which made a light-themed app show dark green slabs
/// with loud accents. Morandi now uses the same quiet register as the window.
func playerOverlayPalette(_ palette: M3Palette) -> M3Palette {
    let dark = popupsUseDarkPalette
    // Morandi takes the same fixed palette as the rest of the window, in its
    // dark register, so the popups belong to the theme even though the stage
    // behind them keeps its artwork colour.
    if AppearanceSettings.shared.usesMorandi {
        // Same dusty ladder as `themePalette` — no `vivid`, no boosted chroma.
        return .morandi(hue: AppearanceSettings.shared.morandiHue,
                        isDark: dark)
    }
    let seed = PaletteSeed(hue: palette.seed.hue,
                           chroma: min(palette.seed.chroma, 0.18))
    return M3Palette(seed: seed, isDark: dark, vivid: false)
}

/// Whether player popups paint dark. All themes follow the resolved
/// appearance; there is no longer a theme-specific dark stage palette.
private var popupsUseDarkPalette: Bool {
    switch AppearanceSettings.shared.mode {
    case .dark: return true
    case .light: return false
    case .system:
        #if os(macOS)
        return AppearanceSettings.shared.systemIsDark
        #else
        return UITraitCollection.current.userInterfaceStyle == .dark
        #endif
    }
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
