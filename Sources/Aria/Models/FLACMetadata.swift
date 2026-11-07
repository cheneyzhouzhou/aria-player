import Foundation

/// Minimal, dependency-free reader for the FLAC metadata blocks that sit between
/// the `fLaC` magic and the first audio frame.
///
/// Only the header region is read — the embedded picture is located but not
/// loaded, so scanning a library never pulls megabytes of JPEG off disk.
enum FLACMetadata {

    private enum BlockType: UInt8 {
        case streamInfo = 0, vorbisComment = 4, picture = 6
    }

    /// Reads the metadata blocks of `url`. Returns nil if the file is not FLAC.
    static func read(at url: URL) -> AudioInfo? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let magic = try? handle.read(upToCount: 4), magic == Data("fLaC".utf8) else {
            return nil
        }

        var info = AudioInfo()
        info.format = .flac
        var offset: UInt64 = 4
        var isLast = false

        // Metadata blocks are capped so a corrupt file can't spin here forever.
        var blocksRead = 0
        while !isLast && blocksRead < 128 {
            blocksRead += 1
            guard let header = try? handle.read(upToCount: 4), header.count == 4 else { break }
            isLast = (header[0] & 0x80) != 0
            let type = header[0] & 0x7F
            let length = UInt64(header[1]) << 16 | UInt64(header[2]) << 8 | UInt64(header[3])
            offset += 4

            switch BlockType(rawValue: type) {
            case .streamInfo:
                if let body = try? handle.read(upToCount: Int(length)), body.count >= 18 {
                    parseStreamInfo(body, into: &info)
                }
            case .vorbisComment:
                if let body = try? handle.read(upToCount: Int(length)) {
                    parseVorbisComment(body, into: &info)
                }
            case .picture:
                if let body = try? handle.read(upToCount: Int(length)) {
                    // Record where the image bytes live rather than keeping them.
                    if let local = pictureDataRange(in: body) {
                        info.pictureRange = (offset + UInt64(local.lowerBound)) ..< (offset + UInt64(local.upperBound))
                        info.hasPicture = true
                    }
                }
            default:
                // Padding, seek table, cue sheet — skip without reading.
                try? handle.seek(toOffset: offset + length)
            }

            offset += length
            try? handle.seek(toOffset: offset)
        }

        return info.sampleRate > 0 ? info : nil
    }

    /// Loads the embedded cover art bytes previously located by `read(at:)`.
    static func pictureData(at url: URL, range: Range<UInt64>) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: range.lowerBound)
        return try? handle.read(upToCount: Int(range.upperBound - range.lowerBound))
    }

    // MARK: - Block parsers

    /// STREAMINFO packs sample rate, channels, bit depth and total samples into
    /// 64 big-endian bits starting at byte 10.
    private static func parseStreamInfo(_ body: Data, into info: inout AudioInfo) {
        let b = [UInt8](body)
        var packed: UInt64 = 0
        for i in 10..<18 { packed = packed << 8 | UInt64(b[i]) }
        info.sampleRate = Int((packed >> 44) & 0xF_FFFF)
        info.channels = Int((packed >> 41) & 0x7) + 1
        info.bitDepth = Int((packed >> 36) & 0x1F) + 1
        let totalSamples = packed & 0xF_FFFF_FFFF
        // STREAMINFO carries the exact length, so no decoding is needed.
        if info.sampleRate > 0 {
            info.duration = Double(totalSamples) / Double(info.sampleRate)
        }
    }

    /// Vorbis comments are the one FLAC block that uses *little*-endian lengths.
    private static func parseVorbisComment(_ body: Data, into info: inout AudioInfo) {
        let b = [UInt8](body)
        var p = 0

        func u32() -> Int? {
            guard p + 4 <= b.count else { return nil }
            let v = Int(b[p]) | Int(b[p + 1]) << 8 | Int(b[p + 2]) << 16 | Int(b[p + 3]) << 24
            p += 4
            return v >= 0 ? v : nil
        }

        guard let vendorLength = u32() else { return }
        p += vendorLength
        guard let count = u32(), count < 4096 else { return }

        for _ in 0..<count {
            guard let length = u32(), p + length <= b.count else { return }
            let raw = String(decoding: b[p..<(p + length)], as: UTF8.self)
            p += length
            guard let eq = raw.firstIndex(of: "=") else { continue }
            let key = raw[..<eq].uppercased()
            let value = String(raw[raw.index(after: eq)...])
            guard !value.isEmpty else { continue }
            if let existing = info.tags[key] {
                info.tags[key] = existing + ", " + value
            } else {
                info.tags[key] = value
                info.primaryTags[key] = value
            }
        }
    }

    /// Walks the PICTURE block's variable-length header to find the image payload.
    private static func pictureDataRange(in body: Data) -> Range<Int>? {
        let b = [UInt8](body)
        var p = 0

        func u32be() -> Int? {
            guard p + 4 <= b.count else { return nil }
            let v = Int(b[p]) << 24 | Int(b[p + 1]) << 16 | Int(b[p + 2]) << 8 | Int(b[p + 3])
            p += 4
            return v >= 0 ? v : nil
        }

        guard u32be() != nil else { return nil }                 // picture type
        guard let mimeLength = u32be() else { return nil }
        p += mimeLength
        guard let descLength = u32be() else { return nil }
        p += descLength
        // width, height, colour depth, indexed colours
        for _ in 0..<4 { guard u32be() != nil else { return nil } }
        guard let dataLength = u32be(), p + dataLength <= b.count, dataLength > 0 else { return nil }
        return p..<(p + dataLength)
    }
}
