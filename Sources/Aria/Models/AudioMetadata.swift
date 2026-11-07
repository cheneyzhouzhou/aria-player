import AVFoundation
import AudioToolbox
import Foundation

/// One reading of a file's format and tags, whichever container it lives in.
/// FLAC fills this from its own metadata blocks; every other container fills it
/// from AVFoundation, which is the only public decoder that also exposes ID3 and
/// iTunes tags.
struct AudioInfo {
    var format: AudioFormat = .flac
    var sampleRate: Int = 0
    var channels: Int = 0
    /// Zero for lossy codecs, which have no meaningful sample word length.
    var bitDepth: Int = 0
    var duration: Double = 0
    /// Keys are the Vorbis-comment spelling (`TITLE`, `ARTIST`, …) so `Track`
    /// needs no per-container branching. Repeated keys are joined with ", ".
    var tags: [String: String] = [:]
    /// Only the first value of each repeated key — grouping wants the lead credit.
    var primaryTags: [String: String] = [:]
    /// Byte range of an embedded picture, when the container let us locate one
    /// without reading the image (FLAC). Other containers load it on demand.
    var pictureRange: Range<UInt64>?
    var hasPicture: Bool = false
}

/// Reads tags and stream format for every container Aria accepts.
enum AudioMetadata {

    /// FLAC keeps its hand-written parser: it is the only way to reach Vorbis
    /// comments, and it also reports the real bit depth, which AVFoundation
    /// returns as 0 for compressed streams.
    static func read(at url: URL) async -> AudioInfo? {
        if url.pathExtension.lowercased() == "flac",
           let info = FLACMetadata.read(at: url) {
            return info
        }
        return await readWithAVFoundation(at: url)
    }

    /// Loads the picture bytes of a file whose cover was not located as a byte
    /// range during the scan. Called once per album, off the main thread.
    static func artworkData(at url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.metadata),
              let item = items.first(where: isArtwork) else { return nil }
        return await data(of: item)
    }

    // MARK: - AVFoundation

    private static func readWithAVFoundation(at url: URL) async -> AudioInfo? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let descriptions = try? await track.load(.formatDescriptions),
              let description = descriptions.first,
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              basic.mSampleRate > 0 else { return nil }

        let subtype = CMFormatDescriptionGetMediaSubType(description)
        var info = AudioInfo()
        info.format = AudioFormat.from(mediaSubType: subtype, url: url)
        info.sampleRate = Int(basic.mSampleRate.rounded())
        info.channels = Int(basic.mChannelsPerFrame)
        info.bitDepth = bitDepth(for: subtype, description: description, basic: basic)
        info.duration = await duration(of: asset, url: url)

        let items = (try? await asset.load(.metadata)) ?? []
        info.hasPicture = items.contains(where: isArtwork)
        let (tags, primary) = await tagDictionary(from: items)
        info.tags = tags
        info.primaryTags = primary
        return info
    }

    /// ALAC compresses integer PCM, so the word length survives in the magic
    /// cookie even though the stream description reports 0.
    private static func bitDepth(for subtype: AudioFormatID,
                                description: CMFormatDescription,
                                basic: AudioStreamBasicDescription) -> Int {
        if subtype == kAudioFormatAppleLossless, let depth = alacBitDepth(description) {
            return depth
        }
        return Int(basic.mBitsPerChannel)
    }

    private static func alacBitDepth(_ description: CMFormatDescription) -> Int? {
        var size = 0
        guard let cookie = CMAudioFormatDescriptionGetMagicCookie(description, sizeOut: &size),
              size >= 24 else { return nil }
        let bytes = [UInt8](UnsafeBufferPointer(
            start: UnsafeRawPointer(cookie).assumingMemoryBound(to: UInt8.self), count: size))
        // AVFoundation hands back `frma` + `alac` boxes (56 bytes) where the bit
        // depth sits 13 bytes past the `alac` type; older systems hand back the
        // bare ALACSpecificConfig, where it is the sixth byte.
        let depth = size >= 30 && bytes[16..<20].elementsEqual(Array("alac".utf8))
            ? Int(bytes[29])
            : Int(bytes[5])
        // Anything else means the layout was not what we expected; reporting 0
        // is better than printing a garbage depth in the chain panel.
        return [16, 20, 24, 32].contains(depth) ? depth : nil
    }

    private static func duration(of asset: AVAsset, url: URL) async -> Double {
        if let time = try? await asset.load(.duration) {
            let seconds = time.seconds
            if seconds.isFinite, seconds > 0 { return seconds }
        }
        // A malformed or still-being-written header: fall back to the decoder.
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        let rate = file.fileFormat.sampleRate
        return rate > 0 ? Double(file.length) / rate : 0
    }

    // MARK: - Tags

    private static func isArtwork(_ item: AVMetadataItem) -> Bool {
        if item.commonKey == .commonKeyArtwork { return true }
        let suffix = identifierSuffix(item)
        return suffix == "APIC" || suffix == "COVR" || suffix.contains("PICTURE")
    }

    /// `id3/TIT2` → `TIT2`, `itsk/%A9nam` → `%A9NAM`, `caaf/info-title` → `INFO-TITLE`.
    private static func identifierSuffix(_ item: AVMetadataItem) -> String {
        let raw = (item.identifier?.rawValue ?? "").uppercased()
        return raw.split(separator: "/").last.map(String.init) ?? raw
    }

    /// AIFF pads its text chunks with NULs, which would otherwise show up as a
    /// trailing space in every title.
    private static let trimmable = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "\u{0}"))

    private static func text(of item: AVMetadataItem) async -> String {
        guard let value = try? await item.load(.stringValue) else { return "" }
        return value.trimmingCharacters(in: trimmable)
    }

    private static func data(of item: AVMetadataItem) async -> Data? {
        (try? await item.load(.dataValue)) ?? nil
    }

    private static func tagDictionary(from items: [AVMetadataItem]) async
        -> (tags: [String: String], primary: [String: String]) {
        var tags: [String: String] = [:]
        var primary: [String: String] = [:]
        var date: String?

        func store(_ key: String, _ value: String) {
            let trimmed = value.trimmingCharacters(in: trimmable)
            guard !trimmed.isEmpty else { return }
            if let existing = tags[key] {
                tags[key] = existing + ", " + trimmed
            } else {
                tags[key] = trimmed
                primary[key] = trimmed
            }
        }

        func storeNumeric(_ key: String, _ item: AVMetadataItem) async {
            let string = await text(of: item)
            if !string.isEmpty {
                store(key, string)
            } else if let payload = await data(of: item), let pair = numberPair(payload) {
                store(key, String(pair))
            }
        }

        for item in items {
            if isArtwork(item) { continue }
            switch identifierSuffix(item) {
            case "TIT2", "%A9NAM", "TITLE", "INFO-TITLE":
                store("TITLE", await text(of: item))
            case "TPE1", "%A9ART", "ARTIST", "INFO-ARTIST":
                store("ARTIST", await text(of: item))
            case "TPE2", "AART", "ALBUMARTIST", "ALBUM ARTIST":
                store("ALBUMARTIST", await text(of: item))
            case "TALB", "%A9ALB", "ALBUM", "INFO-ALBUM":
                store("ALBUM", await text(of: item))
            case "TCON", "%A9GEN", "GENRE", "INFO-GENRE":
                store("GENRE", await text(of: item))
            case "TDRC", "TYER", "%A9DAY", "DATE", "YEAR", "INFO-DATE":
                let value = await text(of: item)
                if year(from: value) != nil { date = value }
            case "TRCK", "TRKN", "TRACKNUMBER":
                await storeNumeric("TRACKNUMBER", item)
            case "TPOS", "DISK", "DISCNUMBER":
                await storeNumeric("DISCNUMBER", item)
            case "USLT", "%A9LYR", "LYRICS", "UNSYNCEDLYRICS":
                store("LYRICS", await text(of: item))
            default:
                break
            }
        }

        // Containers without an identifier mapping still expose the shared keys.
        for item in items {
            guard let common = item.commonKey else { continue }
            switch common {
            case .commonKeyTitle where tags["TITLE"] == nil:
                store("TITLE", await text(of: item))
            case .commonKeyArtist where tags["ARTIST"] == nil:
                store("ARTIST", await text(of: item))
            case .commonKeyAlbumName where tags["ALBUM"] == nil:
                store("ALBUM", await text(of: item))
            case .commonKeyType where tags["GENRE"] == nil:
                store("GENRE", await text(of: item))
            case .commonKeyCreationDate where date == nil:
                // ID3's TDAT (day/month) also maps here and would read as a year.
                let value = await text(of: item)
                if year(from: value) != nil { date = value }
            default:
                break
            }
        }

        if let date { store("DATE", date) }
        return (tags, primary)
    }

    /// Plausible four-digit year, so a day/month tag can't be mistaken for one.
    private static func year(from value: String) -> String? {
        let digits = value.prefix(4)
        guard digits.count == 4, digits.allSatisfy(\.isNumber),
              let year = Int(digits), (1900...2100).contains(year) else { return nil }
        return String(digits)
    }

    /// `trkn` and `disk` are 8-byte big-endian pairs: two padding bytes, the
    /// number, the total, two more padding bytes.
    private static func numberPair(_ data: Data) -> Int? {
        guard data.count >= 4 else { return nil }
        let bytes = [UInt8](data.prefix(4))
        let value = Int(bytes[2]) << 8 | Int(bytes[3])
        return value > 0 ? value : nil
    }
}
