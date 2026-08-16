import Foundation
import SwiftUI

/// Decodes embedded FLAC cover art on demand and keeps the results in memory.
///
/// Art is keyed by album rather than track, so a 12-track album decodes one image.
final class ArtworkCache {
    static let shared = ArtworkCache()

    private let cache = NSCache<NSString, PlatformImage>()
    private let queue = DispatchQueue(label: "aria.artwork", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    private var inFlight = Set<String>()

    private init() {
        cache.countLimit = 400
    }

    func cached(for key: String) -> PlatformImage? {
        cache.object(forKey: key as NSString)
    }

    /// Returns art for `track`, decoding off the main thread if needed.
    func artwork(for track: Track, key: String, completion: @escaping (PlatformImage?) -> Void) {
        if let hit = cached(for: key) {
            completion(hit)
            return
        }
        guard let range = track.artRange else {
            completion(nil)
            return
        }

        lock.lock()
        let alreadyLoading = inFlight.contains(key)
        if !alreadyLoading { inFlight.insert(key) }
        lock.unlock()

        // A duplicate request for art already being decoded resolves on the next
        // cache hit rather than decoding the same JPEG twice.
        if alreadyLoading {
            queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                let image = self?.cached(for: key)
                DispatchQueue.main.async { completion(image) }
            }
            return
        }

        let url = track.url
        queue.async { [weak self] in
            var image: PlatformImage?
            if let data = FLACMetadata.pictureData(at: url, range: range) {
                image = PlatformImage.decode(data)
            }
            if let image { self?.cache.setObject(image, forKey: key as NSString) }
            self?.lock.lock()
            self?.inFlight.remove(key)
            self?.lock.unlock()
            DispatchQueue.main.async { completion(image) }
        }
    }
}
