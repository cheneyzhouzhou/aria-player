import Foundation

struct Track: Identifiable, Hashable, Codable {
    let id: String              // stable across scans: the file path
    var url: URL
    var title: String
    var artist: String
    var albumArtist: String
    var album: String
    var genre: String
    var year: String
    var trackNumber: Int
    var discNumber: Int
    var duration: Double
    var sampleRate: Int
    var bitDepth: Int
    var channels: Int
    var fileSize: Int64
    var dateAdded: Date
    var artOffset: UInt64?
    var artLength: Int?
    /// The codec, when it had to be asked for rather than inferred from the file
    /// name — an `.m4a` may be ALAC or AAC. Persisted so a library cached before
    /// the format existed is labelled correctly without a rescan.
    var codec: String?
    /// The file carries a picture, but the scan did not locate its byte range.
    /// Those covers are decoded on demand through AVFoundation instead.
    var hasEmbeddedArt: Bool?
    /// Lyrics carried in the file's tags, if any. A `.lrc` beside the file wins
    /// over this — see `Lyrics.load(for:)`.
    var lyrics: String?

    /// Albums are keyed by album artist + title so two soundtracks sharing a
    /// name don't collapse into one.
    var albumKey: String { "\(albumArtist.lowercased())::\(album.lowercased())" }

    var artRange: Range<UInt64>? {
        guard let offset = artOffset, let length = artLength else { return nil }
        return offset..<(offset + UInt64(length))
    }

    /// What the file actually is, not what its extension suggests.
    var format: AudioFormat {
        codec.flatMap(AudioFormat.init(rawValue:)) ?? AudioFormat.inferred(from: url)
    }

    var hasArtwork: Bool { artRange != nil || hasEmbeddedArt == true }

    /// Average bitrate in kbps, derived from file size and duration.
    var bitrate: Int {
        duration > 0 ? Int(Double(fileSize) * 8 / duration / 1000) : 0
    }

    var qualityLabel: String {
        let rate = String(format: "%.1f", Double(sampleRate) / 1000)
        // Lossy codecs have no sample word length, so the bitrate is the number
        // worth showing instead of a misleading "0-bit".
        if bitDepth > 0 { return "\(bitDepth)-bit · \(rate) kHz" }
        return bitrate > 0 ? "\(bitrate) kbps · \(rate) kHz" : "\(rate) kHz"
    }

    static func load(from url: URL) async -> Track? {
        guard let info = await AudioMetadata.read(at: url) else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let tags = info.tags

        func tag(_ keys: String...) -> String? {
            for key in keys {
                if let value = tags[key], !value.isEmpty { return value }
            }
            return nil
        }

        /// Lead credit only, ignoring featured artists.
        func leadTag(_ keys: String...) -> String? {
            for key in keys {
                if let value = info.primaryTags[key], !value.isEmpty { return value }
            }
            return nil
        }

        // Tags win; fall back to the Artist/Album/Track folder layout.
        let parent = url.deletingLastPathComponent()
        let folderAlbum = parent.lastPathComponent
        let folderArtist = parent.deletingLastPathComponent().lastPathComponent

        // The track keeps the full credit list; the album is filed under the
        // lead name, so features don't spawn a separate artist each time.
        let artist = tag("ARTIST", "PERFORMER") ?? folderArtist
        let albumArtist = leadTag("ALBUMARTIST", "ALBUM ARTIST", "ARTIST", "PERFORMER") ?? folderArtist

        return Track(
            id: url.path,
            url: url,
            title: tag("TITLE") ?? url.deletingPathExtension().lastPathComponent,
            artist: artist,
            albumArtist: albumArtist,
            album: tag("ALBUM") ?? folderAlbum,
            genre: tag("GENRE") ?? "",
            year: String((tag("DATE", "YEAR") ?? "").prefix(4)),
            trackNumber: Int(tag("TRACKNUMBER")?.split(separator: "/").first.map(String.init) ?? "") ?? 0,
            discNumber: Int(tag("DISCNUMBER")?.split(separator: "/").first.map(String.init) ?? "") ?? 1,
            duration: info.duration,
            sampleRate: info.sampleRate,
            bitDepth: info.bitDepth,
            channels: info.channels,
            fileSize: (attrs?[.size] as? NSNumber)?.int64Value ?? 0,
            dateAdded: (attrs?[.creationDate] as? Date) ?? .distantPast,
            artOffset: info.pictureRange?.lowerBound,
            artLength: info.pictureRange.map { Int($0.upperBound - $0.lowerBound) },
            codec: info.format.rawValue,
            hasEmbeddedArt: info.hasPicture && info.pictureRange == nil ? true : nil,
            lyrics: tag("LYRICS", "UNSYNCEDLYRICS", "UNSYNCED LYRICS", "LYRIC")
        )
    }
}

struct Album: Identifiable, Hashable {
    let id: String
    var title: String
    var artist: String
    var year: String
    var tracks: [Track]

    var duration: Double { tracks.reduce(0) { $0 + $1.duration } }
    /// The track whose embedded picture represents the album.
    var artworkTrack: Track? { tracks.first { $0.hasArtwork } }
}

struct Artist: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var albums: [Album]

    var trackCount: Int { albums.reduce(0) { $0 + $1.tracks.count } }
}

func plural(_ count: Int, _ singular: String, _ many: String? = nil) -> String {
    "\(count) " + (count == 1 ? singular : (many ?? singular + "s"))
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds.rounded())
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0
        ? String(format: "%d:%02d:%02d", h, m, s)
        : String(format: "%d:%02d", m, s)
}

func formatDurationLong(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let h = total / 3600, m = (total % 3600) / 60
    if h > 0 { return "\(h) hr \(m) min" }
    return "\(m) min"
}
