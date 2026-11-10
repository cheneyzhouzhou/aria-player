#if os(iOS)
import Foundation
import MediaPlayer
import SwiftUI

/// Read-only access to the songs already in the Music app.
///
/// Deliberately narrow: only items that expose a playable `assetURL` are
/// offered. Apple Music subscription downloads are FairPlay-protected — iOS
/// returns no asset URL for them, so a third-party app cannot obtain their
/// audio data. Aria never copies or exports any audio file; the URL is handed
/// straight to AVPlayer.
@MainActor
final class MediaLibraryAccess: ObservableObject {
    static let shared = MediaLibraryAccess()

    private static let enabledKey = "ariaMediaLibraryEnabled"

    @Published private(set) var isEnabled: Bool
    @Published private(set) var authorization: MPMediaLibraryAuthorizationStatus
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var skippedCount = 0

    /// Album key -> the artwork object, decoded lazily by `CoverArt` so opening
    /// the feature never decodes hundreds of sleeves in one pass.
    private var artworkByAlbum: [String: MPMediaItemArtwork] = [:]

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        authorization = MPMediaLibrary.authorizationStatus()
    }

    var canRead: Bool { isEnabled && authorization == .authorized }

    /// Turns the feature on or off. Turning it on asks for the Media Library
    /// permission; a refusal leaves the switch off rather than showing a dead
    /// toggle. Turning it off drops the tracks without touching the files.
    func setEnabled(_ on: Bool) async {
        if on {
            authorization = await requestAuthorization()
            guard authorization == .authorized else {
                isEnabled = false
                UserDefaults.standard.set(false, forKey: Self.enabledKey)
                tracks = []
                skippedCount = 0
                artworkByAlbum = [:]
                return
            }
        }
        isEnabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on { refresh() } else {
            tracks = []
            skippedCount = 0
            artworkByAlbum = [:]
        }
    }

    private func requestAuthorization() async -> MPMediaLibraryAuthorizationStatus {
        let current = MPMediaLibrary.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            MPMediaLibrary.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    /// Re-reads the Music app library. Cheap: metadata comes straight from
    /// MPMediaItem, artwork is only referenced, not decoded.
    func refresh() {
        authorization = MPMediaLibrary.authorizationStatus()
        guard canRead else {
            tracks = []
            skippedCount = 0
            artworkByAlbum = [:]
            return
        }
        let items = MPMediaQuery.songs().items ?? []
        var found: [Track] = []
        found.reserveCapacity(items.count)
        var skipped = 0
        var art: [String: MPMediaItemArtwork] = [:]
        let calendar = Calendar.current

        for item in items {
            // No assetURL == FairPlay-protected subscription download, or an
            // iCloud item that has not been downloaded. Neither can be played
            // by an engine outside the Music app.
            guard let url = item.assetURL, !item.isCloudItem else {
                skipped += 1
                continue
            }
            let artist = item.artist ?? L("Unknown artist")
            let albumArtist = item.albumArtist ?? artist
            let year = item.releaseDate.map { String(calendar.component(.year, from: $0)) } ?? ""
            let track = Track(
                id: "media:\(item.persistentID)",
                url: url,
                title: item.title ?? L("Unknown title"),
                artist: artist,
                albumArtist: albumArtist,
                album: item.albumTitle ?? L("Unknown album"),
                genre: item.genre ?? "",
                year: year,
                trackNumber: item.albumTrackNumber,
                discNumber: item.discNumber,
                duration: item.playbackDuration,
                sampleRate: 0,
                bitDepth: 0,
                channels: 2,
                fileSize: 0,
                dateAdded: item.dateAdded,
                artOffset: nil,
                artLength: nil,
                codec: nil,
                // Artwork is supplied by `artwork(for:)` below, not by reading
                // the `ipod-library://` URL through AVFoundation.
                hasEmbeddedArt: false,
                lyrics: nil)
            found.append(track)
            if let sleeve = item.artwork, art[track.albumKey] == nil {
                art[track.albumKey] = sleeve
            }
        }
        tracks = found
        skippedCount = skipped
        artworkByAlbum = art
    }

    /// Decodes one album's sleeve on demand for `CoverArt`.
    func artwork(for albumKey: String) -> PlatformImage? {
        guard let sleeve = artworkByAlbum[albumKey] else { return nil }
        return sleeve.image(at: CGSize(width: 600, height: 600))
    }
}
#endif
