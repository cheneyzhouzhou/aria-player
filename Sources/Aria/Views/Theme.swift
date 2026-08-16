import SwiftUI

/// A Material-style set of colour roles generated from a single seed.
///
/// Real Material 3 derives tones in the HCT colour space; this approximates the
/// same idea in HSB, which is close enough visually and needs no colour-science
/// dependency. Every role scales its saturation by the seed's chroma, so grey
/// artwork yields a grey interface instead of a tinted one.
struct M3Palette: Equatable {
    var seed: PaletteSeed
    var isDark: Bool
    /// Now-playing surfaces lean much harder into the colour than list screens.
    var vivid: Bool = false

    /// Greyscale artwork should yield a greyscale interface, but anything with
    /// real colour gets a floor — otherwise muted covers tint to near-black and
    /// the whole dynamic-colour effect disappears.
    private var chroma: Double {
        guard seed.chroma > 0.03 else { return 0 }
        return min(max(seed.chroma, 0.55) * 1.1, 1)
    }

    private func tone(_ saturation: Double, _ brightness: Double) -> Color {
        Color(hue: seed.hue, saturation: min(saturation * chroma, 1), brightness: brightness)
    }

    // Backgrounds, lowest to highest elevation.
    var surface: Color {
        isDark ? tone(vivid ? 0.80 : 0.62, vivid ? 0.27 : 0.19)
               : tone(vivid ? 0.20 : 0.07, vivid ? 0.96 : 0.99)
    }
    var surfaceContainer: Color {
        isDark ? tone(vivid ? 0.72 : 0.56, vivid ? 0.35 : 0.26)
               : tone(vivid ? 0.26 : 0.11, vivid ? 0.92 : 0.955)
    }
    var surfaceContainerHigh: Color {
        isDark ? tone(vivid ? 0.64 : 0.50, vivid ? 0.43 : 0.33)
               : tone(vivid ? 0.32 : 0.15, vivid ? 0.88 : 0.925)
    }

    // Accents.
    var primary: Color {
        isDark ? tone(0.40, 0.93) : tone(0.78, 0.52)
    }
    var onPrimary: Color {
        isDark ? tone(0.90, 0.24) : Color.white
    }
    var primaryContainer: Color {
        isDark ? tone(0.58, 0.44) : tone(0.30, 0.90)
    }
    var onPrimaryContainer: Color {
        isDark ? tone(0.22, 0.97) : tone(0.95, 0.26)
    }

    // Foregrounds.
    var onSurface: Color {
        isDark ? tone(0.10, 0.97) : tone(0.65, 0.13)
    }
    var onSurfaceVariant: Color {
        isDark ? tone(0.18, 0.78) : tone(0.45, 0.36)
    }
    var outline: Color {
        isDark ? tone(0.24, 0.48) : tone(0.30, 0.62)
    }

    static let fallback = M3Palette(seed: .indigo, isDark: true)
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = M3Palette.fallback
}

extension EnvironmentValues {
    /// The palette the surrounding surface is painted with.
    var palette: M3Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

// MARK: - Type

/// Material's expressive type scale leans on large, light, geometric faces;
/// SF Rounded is the closest thing shipped with macOS.
extension Font {
    static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
    static func label(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    /// Timecodes, so digits don't jitter.
    static func ticker(_ size: CGFloat) -> Font {
        .system(size: size, weight: .medium, design: .rounded).monospacedDigit()
    }
}

// MARK: - Shape

extension View {
    /// Material's "squircle" — a continuous rounded rect, used for everything.
    func squircle(_ radius: CGFloat) -> some View {
        clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Standard corner radii, kept in one place so surfaces stay in family.
enum Radius {
    static let chip: CGFloat = 999
    static let card: CGFloat = 20
    static let art: CGFloat = 16
    static let sheet: CGFloat = 28
    static let thumb: CGFloat = 10
}
