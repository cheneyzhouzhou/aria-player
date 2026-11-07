import Foundation

/// One line of lyrics, with the moment it should light up.
struct LyricLine: Identifiable, Hashable {
    let id = UUID()
    /// Seconds from the start. Zero for unsynced lyrics.
    let time: Double
    let text: String
}

/// Lyrics for a track, synced or not.
struct Lyrics {
    let lines: [LyricLine]
    /// False when the file had no timestamps — the lines are shown as plain text.
    let synced: Bool

    var isEmpty: Bool { lines.isEmpty }

    /// The index of the line playing at `time`, or nil before the first one.
    func index(at time: Double) -> Int? {
        guard synced, !lines.isEmpty else { return nil }
        // Binary search: the pane asks this four times a second.
        var low = 0, high = lines.count - 1, found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].time <= time + 0.05 {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }

    // MARK: - Loading

    /// A `.lrc` beside the audio file wins; the file's own lyrics tag is the
    /// fallback, shown unsynced because it rarely carries timestamps.
    static func load(for track: Track) -> Lyrics? {
        let base = track.url.deletingPathExtension()
        for ext in ["lrc", "LRC"] {
            let url = base.appendingPathExtension(ext)
            if let text = readText(at: url) {
                let parsed = parse(text)
                if !parsed.isEmpty { return parsed }
            }
        }
        if let embedded = track.lyrics, !embedded.isEmpty {
            let parsed = parse(embedded)
            if !parsed.isEmpty { return parsed }
        }
        return nil
    }

    private static func readText(at url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        // UTF-8 first, then GB18030 — Chinese lyric files are still often
        // saved in it, and a wrong guess shows up as mojibake rather than an
        // error, so the order matters.
        if let text = String(data: data, encoding: .utf8) { return text }
        let gb18030 = String.Encoding(rawValue: 0x80000632)
        if let text = String(data: data, encoding: gb18030) { return text }
        return String(data: data, encoding: .isoLatin1)
    }

    // MARK: - Parsing

    /// Reads LRC. Handles several timestamps on one line, the metadata tags at
    /// the top, and a negative `[offset:]` in milliseconds.
    static func parse(_ text: String) -> Lyrics {
        var entries: [(Double, String)] = []
        var offset: Double = 0
        var sawTimestamp = false

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("[offset:") || line.hasPrefix("[OFFSET:") {
                if let value = number(in: line), value != 0 { offset = value / 1000 }
                continue
            }

            var times: [Double] = []
            var rest = Substring(line)
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let inside = rest[rest.index(after: rest.startIndex)..<close]
                if let seconds = timestamp(inside) {
                    times.append(seconds)
                    sawTimestamp = true
                    rest = rest[rest.index(after: close)...]
                } else {
                    // [ti:], [ar:], [al:] and friends: skip the tag entirely.
                    break
                }
            }

            // A metadata tag with no timestamps leaves `rest` on the tag itself.
            if times.isEmpty {
                if rest == line { continue }
                continue
            }

            let content = rest.trimmingCharacters(in: .whitespaces)
            for time in times { entries.append((time, content)) }
        }

        guard sawTimestamp, !entries.isEmpty else {
            // No timestamps anywhere: keep the text as plain lines, minus the
            // metadata tags that would otherwise show up as lyrics.
            let plain = text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !isMetadata($0) }
            return Lyrics(lines: plain.map { LyricLine(time: 0, text: $0) }, synced: false)
        }

        entries.sort { $0.0 < $1.0 }
        let lines = entries.map { LyricLine(time: max(0, $0.0 + offset), text: $0.1) }
        return Lyrics(lines: lines, synced: true)
    }

    private static func isMetadata(_ line: String) -> Bool {
        guard line.hasPrefix("["), line.hasSuffix("]") else { return false }
        return timestamp(line.dropFirst().dropLast()) == nil
    }

    /// `mm:ss`, `mm:ss.x`, `mm:ss.xx`, `mm:ss.xxx`.
    private static func timestamp(_ s: Substring) -> Double? {
        let parts = s.split(separator: ":")
        guard parts.count == 2,
              let minutes = Double(parts[0]),
              let seconds = Double(parts[1]),
              seconds < 60 else { return nil }
        return minutes * 60 + seconds
    }

    private static func number(in line: String) -> Double? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let digits = line[line.index(after: colon)...]
            .trimmingCharacters(in: CharacterSet(charactersIn: "] "))
        return Double(digits)
    }
}
