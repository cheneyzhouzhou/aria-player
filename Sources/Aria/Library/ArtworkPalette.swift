import CoreGraphics
import SwiftUI

/// The two numbers a Material-style tonal palette is generated from.
struct PaletteSeed: Equatable, Hashable {
    var hue: Double      // 0...1
    var chroma: Double   // 0...1, how far the palette leans from grey

    static let neutral = PaletteSeed(hue: 0.62, chroma: 0.0)
    /// Deep indigo, the default cast of the library chrome.
    static let indigo = PaletteSeed(hue: 0.62, chroma: 0.85)
}

/// Pulls a dominant, reasonably vivid colour out of cover art.
///
/// Colours are bucketed by hue and weighted by saturation, so a mostly-grey
/// sleeve with one bright element still themes from that element rather than
/// averaging into mud.
enum PaletteExtractor {

    private static let side = 28

    static func seed(from image: PlatformImage) -> PaletteSeed {
        guard let pixels = downsample(image) else { return .neutral }

        let buckets = 36
        var weight = [Double](repeating: 0, count: buckets)
        var hueSum = [Double](repeating: 0, count: buckets)
        var satSum = [Double](repeating: 0, count: buckets)

        // RGBA8, four bytes per pixel.
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Double(pixels[i + 3]) / 255
            guard a > 0.5 else { continue }

            let r = Double(pixels[i]) / 255
            let g = Double(pixels[i + 1]) / 255
            let b = Double(pixels[i + 2]) / 255
            let (h, s, v) = hsb(r, g, b)

            // Ignore near-black and near-white: they carry no usable hue.
            guard v > 0.12, v < 0.97, s > 0.12 else { continue }

            // Favour saturated pixels in the mid-brightness range.
            let midness = 1 - min(abs(v - 0.55) / 0.55, 1)
            let w = pow(s, 1.6) * (0.35 + 0.65 * midness)

            let index = min(Int(h * Double(buckets)), buckets - 1)
            weight[index] += w
            hueSum[index] += h * w
            satSum[index] += s * w
        }

        guard let best = weight.indices.max(by: { weight[$0] < weight[$1] }),
              weight[best] > 0.5 else { return .neutral }

        return PaletteSeed(hue: hueSum[best] / weight[best],
                           chroma: min(satSum[best] / weight[best] * 1.35, 1))
    }

    /// Draws the cover into a small RGBA buffer — small enough that a full
    /// pixel walk is cheap, and identical on both platforms.
    private static func downsample(_ image: PlatformImage) -> [UInt8]? {
        guard let cgImage = image.cgImageRef else { return nil }

        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        return pixels
    }

    /// RGB to hue/saturation/brightness, all 0...1.
    private static func hsb(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let maxC = max(r, g, b), minC = min(r, g, b)
        let delta = maxC - minC
        guard delta > 0.0001, maxC > 0 else { return (0, 0, maxC) }

        var hue: Double
        if maxC == r {
            hue = (g - b) / delta
        } else if maxC == g {
            hue = 2 + (b - r) / delta
        } else {
            hue = 4 + (r - g) / delta
        }
        hue /= 6
        if hue < 0 { hue += 1 }
        return (hue, delta / maxC, maxC)
    }
}

/// Caches one seed per album and extracts missing ones off the main thread.
@MainActor
final class PaletteStore: ObservableObject {
    /// Bumped whenever a new seed lands, so dependent views re-render.
    @Published private(set) var revision = 0

    /// Hue of the library chrome, independent of what's playing.
    @Published var libraryHue: Double {
        didSet { UserDefaults.standard.set(libraryHue, forKey: "libraryHue") }
    }

    private var seeds: [String: PaletteSeed] = [:]
    private var pending: Set<String> = []

    init() {
        let stored = UserDefaults.standard.object(forKey: "libraryHue") as? Double
        libraryHue = stored ?? PaletteSeed.indigo.hue
    }

    var librarySeed: PaletteSeed {
        PaletteSeed(hue: libraryHue, chroma: 0.85)
    }

    /// Cached seed for an album, kicking off extraction on the first miss.
    func seed(for key: String, artwork track: Track?) -> PaletteSeed? {
        if let hit = seeds[key] { return hit }
        guard let track, track.hasArtwork, !pending.contains(key) else { return nil }

        pending.insert(key)
        ArtworkCache.shared.artwork(for: track, key: key) { [weak self] image in
            guard let self else { return }
            guard let image else {
                self.pending.remove(key)
                return
            }
            Task.detached(priority: .utility) {
                let seed = PaletteExtractor.seed(from: image)
                await MainActor.run {
                    self.seeds[key] = seed
                    self.pending.remove(key)
                    self.revision &+= 1
                }
            }
        }
        return nil
    }
}
