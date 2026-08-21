import Foundation
import SwiftUI

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var isScanning = false
    @Published var rootPath: String {
        didSet {
            UserDefaults.standard.set(rootPath, forKey: Self.rootKey)
        }
    }

    /// When the library last finished a scan — shown next to the rescan button.
    @Published private(set) var lastScan: Date?

    private static let rootKey = "libraryRoot"
    private static let lastScanKey = "lastScanDate"

    private static var defaultRoot: String {
        #if os(iOS)
        // Where iOS File Sharing drops anything dragged in from Finder.
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        #else
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music").path
        #endif
    }

    init() {
        rootPath = UserDefaults.standard.string(forKey: Self.rootKey) ?? Self.defaultRoot
        lastScan = UserDefaults.standard.object(forKey: Self.lastScanKey) as? Date
        tracks = Self.loadCache()
    }

    // MARK: - Derived collections

    var albums: [Album] {
        let grouped = Dictionary(grouping: tracks, by: \.albumKey)
        return grouped.map { key, group in
            let sorted = group.sorted {
                ($0.discNumber, $0.trackNumber, $0.title) < ($1.discNumber, $1.trackNumber, $1.title)
            }
            let head = sorted[0]
            return Album(id: key, title: head.album, artist: head.albumArtist, year: head.year, tracks: sorted)
        }
        .sorted { ($0.artist.lowercased(), $0.title.lowercased()) < ($1.artist.lowercased(), $1.title.lowercased()) }
    }

    var artists: [Artist] {
        let grouped = Dictionary(grouping: albums, by: { $0.artist })
        return grouped.map { Artist(name: $0.key, albums: $0.value) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    var totalDuration: Double { tracks.reduce(0) { $0 + $1.duration } }

    // MARK: - Scanning

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        let root = rootPath
        let urls = await Task.detached(priority: .userInitiated) { Self.flacURLs(under: root) }.value
        let found = Self.deduplicate(await Self.parseHeaders(of: urls))
        // Preserve the original dateAdded for files already known, so a rescan
        // doesn't reshuffle "Recently Added".
        let known = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0.dateAdded) })
        tracks = found.map { track in
            var t = track
            if let existing = known[t.id] { t.dateAdded = existing }
            return t
        }
        isScanning = false
        lastScan = Date()
        UserDefaults.standard.set(lastScan, forKey: Self.lastScanKey)
        Self.saveCache(tracks)
    }

    /// Walks the tree collecting .flac files.
    nonisolated private static func flacURLs(under path: String) -> [URL] {
        let root = URL(fileURLWithPath: path)
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var urls: [URL] = []
        for case let url as URL in walker {
            // The Apple Music library is a package of database files, not music.
            if url.pathExtension == "musiclibrary" || url.pathExtension == "itlp" {
                walker.skipDescendants()
                continue
            }
            if url.pathExtension.lowercased() == "flac" { urls.append(url) }
        }
        return urls
    }

    /// Parsing headers is I/O bound, so fan it out. A task group keeps this
    /// concurrency-safe; the previous `concurrentPerform` over an
    /// `UnsafeMutableBufferPointer` captured non-Sendable state.
    nonisolated private static func parseHeaders(of urls: [URL]) async -> [Track] {
        await withTaskGroup(of: (Int, Track?).self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask(priority: .userInitiated) { (index, Track.load(from: url)) }
            }
            var results = [Track?](repeating: nil, count: urls.count)
            for await (index, track) in group { results[index] = track }
            return results.compactMap { $0 }
        }
    }

    /// Drops repeat copies of the same recording.
    ///
    /// Downloaders often leave a second copy beside the first — same tags, same
    /// length, a "_01" suffix on the name. Matching on title, artist, album and
    /// duration keeps genuinely different songs that happen to share a title,
    /// and the copy with the tidier filename wins.
    nonisolated static func deduplicate(_ tracks: [Track]) -> [Track] {
        var best: [String: Track] = [:]
        var order: [String] = []

        for track in tracks {
            let key = [track.title.lowercased(), track.artist.lowercased(),
                       track.album.lowercased(), String(Int(track.duration.rounded()))]
                .joined(separator: "\u{1}")
            guard let existing = best[key] else {
                best[key] = track
                order.append(key)
                continue
            }
            if preferred(track, over: existing) { best[key] = track }
        }
        return order.compactMap { best[$0] }
    }

    /// A name ending in "_01", "_02" and so on marks the later duplicate.
    nonisolated private static func preferred(_ lhs: Track, over rhs: Track) -> Bool {
        func isCopy(_ t: Track) -> Bool {
            let stem = t.url.deletingPathExtension().lastPathComponent
            guard let underscore = stem.lastIndex(of: "_") else { return false }
            let suffix = stem[stem.index(after: underscore)...]
            return suffix.count == 2 && suffix.allSatisfy(\.isNumber)
        }
        if isCopy(lhs) != isCopy(rhs) { return !isCopy(lhs) }
        return lhs.url.path < rhs.url.path
    }

    // MARK: - Cache

    private static var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aria", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("library.json")
    }

    private static func loadCache() -> [Track] {
        guard let data = try? Data(contentsOf: cacheURL),
              let tracks = try? JSONDecoder().decode([Track].self, from: data) else { return [] }
        // Drop entries whose files have since disappeared.
        return tracks.filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    private static func saveCache(_ tracks: [Track]) {
        guard let data = try? JSONEncoder().encode(tracks) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}
