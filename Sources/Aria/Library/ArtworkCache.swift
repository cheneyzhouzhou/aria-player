import Foundation
import SwiftUI

/// Decodes embedded cover art on demand and keeps the results in memory.
///
/// Art is keyed by album rather than track, so a 12-track album decodes one image.
final class ArtworkCache {
    static let shared = ArtworkCache()

    private let cache = NSCache<NSString, PlatformImage>()
    private let queue = DispatchQueue(label: "aria.artwork", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    private var inFlight = Set<String>()
    /// Callbacks waiting on a decode that is already running. They are served
    /// with the real image when it lands — the old code looked in the cache
    /// 0.15s later and usually found nothing, so a second caller (the lock
    /// screen, for one) never got any art at all.
    private var waiters: [String: [(PlatformImage?) -> Void]] = [:]

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
        guard track.hasArtwork else {
            completion(nil)
            return
        }

        let startsDecode = lock.withLock { () -> Bool in
            waiters[key, default: []].append(completion)
            return inFlight.insert(key).inserted
        }
        // Somebody else is already decoding this album: our completion is
        // queued with theirs and will be called with the same image.
        guard startsDecode else { return }

        let url = track.url
        let range = track.artRange
        Task.detached(priority: .userInitiated) { [weak self] in
            var image: PlatformImage?
            if let range {
                // FLAC records where the picture lives, so only those bytes move.
                if let data = FLACMetadata.pictureData(at: url, range: range) {
                    image = PlatformImage.decode(data)
                }
            } else if let data = await AudioMetadata.artworkData(at: url) {
                // MP3, M4A, WAV and AIFF hand the picture to AVFoundation; it is
                // read here, once per album, rather than during the scan.
                image = PlatformImage.decode(data)
            }
            if let image { self?.cache.setObject(image, forKey: key as NSString) }
            let pending = self?.lock.withLock { () -> [(PlatformImage?) -> Void] in
                self?.inFlight.remove(key)
                return self?.waiters.removeValue(forKey: key) ?? []
            } ?? []
            for waiter in pending {
                DispatchQueue.main.async { waiter(image) }
            }
        }
    }
}
