#if os(iOS)
import SwiftUI
import UIKit

/// Renders the current cover once into a small blurred bitmap for the phone's
/// now-playing backdrop — the same treatment the macOS stage uses (a 128px
/// source scaled up, Gaussian blur, slightly desaturated and darkened), so the
/// full-screen player is one static texture rather than a live full-window blur
/// that SwiftUI would have to re-rasterise on every frame.
@MainActor
final class PhoneStageBackdrop: ObservableObject {
    @Published private(set) var image: PlatformImage?

    private let cache = NSCache<NSString, PlatformImage>()
    private var task: Task<Void, Never>?
    /// Guards against a slow decode for an earlier track landing after a
    /// newer one when the user taps next/previous quickly.
    private var request = 0

    func load(for track: Track?) {
        request += 1
        let ticket = request
        task?.cancel()
        guard let track else {
            image = nil
            return
        }
        let key = track.albumKey
        if !track.hasArtwork {
            // No sleeve of its own: derive the texture from the bundled
            // default cover instead, so the stage reads identically whether or
            // not the track carries artwork. This is a real state, not a gap.
            guard let def = DefaultCover.image else { image = nil; return }
            guard let made = makePhoneStageBackdrop(def) else { return }
            image = made
            return
        }
        if let hit = cache.object(forKey: key as NSString) {
            image = hit
            return
        }
        // Keep the previous texture on screen until the new one is ready.
        // Clearing it here exposes the light `palette.surface` underneath for
        // one frame — reads as a bright flash on every track change.
        task = Task.detached(priority: .utility) { [weak self] in
            let art = await loadPhoneStageArtwork(for: track, key: key)
            guard let art, let made = makePhoneStageBackdrop(art), !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.request == ticket else { return }
                self.cache.setObject(made, forKey: key as NSString)
                self.image = made
            }
        }
    }
}

/// These live outside the @MainActor class so the render can run off the main
/// thread without an actor hop.
private func loadPhoneStageArtwork(for track: Track, key: String) async -> PlatformImage? {
    await withCheckedContinuation { continuation in
        ArtworkCache.shared.artwork(for: track, key: key) { image in
            continuation.resume(returning: image)
        }
    }
}

private func makePhoneStageBackdrop(_ source: PlatformImage) -> PlatformImage? {
    guard let cg = source.cgImageRef else { return nil }
    let side = StageBackdropFilter.side
    let rect = CGRect(x: 0, y: 0, width: side, height: side)
    let texture = StageBackdropFilter.texture(from: CIImage(cgImage: cg))
    guard let out = CIContext().createCGImage(texture, from: rect) else { return nil }
    return UIImage(cgImage: out)
}
#endif
