import Foundation
import SwiftUI

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var isScanning = false

    /// Every folder the library reads from, in the order they were added.
    @Published private(set) var sources: [LibrarySource] {
        didSet { Self.saveSources(sources) }
    }

    /// The first folder. Kept for the places that still speak of a single
    /// path — the macOS panel, the window title. Setting it replaces that
    /// first source rather than adding another.
    var rootPath: String {
        get { sources.first?.path ?? Self.defaultRoot }
        set {
            let url = URL(fileURLWithPath: newValue)
            let bookmark = LibrarySource.bookmark(for: url)
            if let first = sources.first {
                sources[0] = LibrarySource(id: first.id, path: newValue, bookmark: bookmark)
            } else {
                sources = [LibrarySource(path: newValue, bookmark: bookmark)]
            }
            retainScope(url, for: sources[0].id)
        }
    }

    /// Where the folder picker should open. The last folder the user added is
    /// the best guess for the next one, and it spares them the Browse tab.
    var pickerStartDirectory: URL? {
        guard let last = sources.last else { return nil }
        return openScopes[last.id] ?? URL(fileURLWithPath: last.path)
    }

    /// How many tracks a folder actually contributed. Shown beside it, so a
    /// folder that was added but held no playable files is visible rather than
    /// silent.
    func trackCount(in source: LibrarySource) -> Int {
        let root = Self.samePathForm(source.path)
        let folder = root.hasSuffix("/") ? root : root + "/"
        return tracks.filter {
            let path = Self.samePathForm($0.url.path)
            return path == root || path.hasPrefix(folder)
        }.count
    }

    /// `/var/mobile/…` and `/private/var/mobile/…` are the same folder, and the
    /// two get mixed freely: the document picker hands out the `/private` form
    /// while the file system reports the short one. Comparing the raw strings
    /// made a folder that had just scanned 263 tracks report "no music here".
    nonisolated static func samePathForm(_ path: String) -> String {
        path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }

    /// Security scopes held open for the life of the app: playback and artwork
    /// read from these folders long after the scan that found them finished.
    private var openScopes: [UUID: URL] = [:]

    /// When the library last finished a scan — shown next to the rescan button.
    @Published private(set) var lastScan: Date?

    private static let sourcesKey = "librarySources"
    private static let legacyRootKey = "libraryRoot"
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
        sources = Self.loadSources()
        lastScan = UserDefaults.standard.object(forKey: Self.lastScanKey) as? Date
        tracks = Self.loadCache().filter { !$0.isMediaLibraryItem }
        // Take the scopes before anything tries to read artwork or audio.
        for source in sources { retainScope(Self.resolve(source), for: source.id) }
    }

    // MARK: - Sources

    /// Adds a folder the user picked. The URL comes from the document picker,
    /// so its security scope is still open — it is turned into a bookmark here
    /// and held for as long as the app runs.
    /// Adds a folder the user picked.
    ///
    /// Taking the security scope and writing the bookmark both talk to the file
    /// provider. On a folder holding hundreds of files that takes long enough
    /// to stall the main thread — which is exactly where the document picker is
    /// still finishing its dismissal, so the sheet freezes on its Open button
    /// and never comes back. Hence the detached task: the picker closes first
    /// and the folder is registered right after.
    @discardableResult
    func addSource(_ url: URL) async -> Bool {
        let standardized = url.standardizedFileURL
        let path = standardized.path
        let canonical = Self.samePathForm(path)
        guard !sources.contains(where: { Self.samePathForm($0.path) == canonical }) else { return false }
        let prepared = await Task.detached(priority: .userInitiated) { () -> LibrarySource in
            var source = LibrarySource(path: path)
            // False for a folder already inside the container, which needs none.
            guard standardized.startAccessingSecurityScopedResource() else { return source }
            source.bookmark = LibrarySource.bookmark(for: standardized)
            return source
        }.value
        openScopes[prepared.id] = standardized
        sources.append(prepared)
        return true
    }

    /// Moves a folder the picker copied into the app into Documents.
    ///
    /// Import mode hands back a URL inside the container, often in `tmp`, which
    /// the system is free to purge. Documents is the folder Aria shows in Files
    /// (UIFileSharingEnabled), so a copy parked there is both durable and
    /// visible if the user wants the space back.
    nonisolated static func adoptCopy(_ url: URL) -> URL? {
        let fm = FileManager.default
        let docs = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
        let normalised = url.standardizedFileURL
        // Import mode hands back something inside the app container. If it did
        // not, the system quietly fell back to in-place access — and "moving"
        // that would move the user's own folder out of On My iPhone. Refuse.
        guard normalised.path.hasPrefix(NSHomeDirectory() + "/") else { return nil }
        if normalised.path.hasPrefix(docs.standardizedFileURL.path + "/") { return normalised }

        try? fm.createDirectory(at: docs, withIntermediateDirectories: true)
        let name = normalised.lastPathComponent.isEmpty ? "Imported" : normalised.lastPathComponent
        var destination = docs.appendingPathComponent(name)
        var counter = 2
        while fm.fileExists(atPath: destination.path) {
            destination = docs.appendingPathComponent("\(name) \(counter)")
            counter += 1
        }
        do {
            try fm.moveItem(at: normalised, to: destination)
        } catch {
            guard (try? fm.copyItem(at: normalised, to: destination)) != nil else { return nil }
            try? fm.removeItem(at: normalised)
        }
        return destination
    }

    /// Registers a folder the picker already prepared. The security scope is
    /// taken in the picker's callback, so there is nothing left to wait for
    /// here — the source becomes readable the moment it is added.
    @discardableResult
    func addPrepared(_ folder: PickedFolder) -> Bool {
        let path = folder.path
        let canonical = Self.samePathForm(path)
        guard !sources.contains(where: { Self.samePathForm($0.path) == canonical }) else { return false }
        let source = LibrarySource(path: path, name: folder.name, bookmark: folder.bookmark)
        if folder.holdsScope { openScopes[source.id] = folder.url }
        sources.append(source)
        return true
    }

    /// Removes a folder and forgets the tracks that came from it, so the list
    /// matches the folders without waiting for a rescan.
    func removeSource(id: UUID) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        let removed = sources.remove(at: index)
        if let url = openScopes.removeValue(forKey: id) {
            url.stopAccessingSecurityScopedResource()
        }
        let root = Self.samePathForm(removed.path)
        let folder = root.hasSuffix("/") ? root : root + "/"
        tracks.removeAll {
            let path = Self.samePathForm($0.url.path)
            return path == root || path.hasPrefix(folder)
        }
    }

    /// Turns a source back into a URL. A bookmark survives the folder being
    /// moved, and on iOS it is the only way back into a folder outside the
    /// app's own container.
    private static func resolve(_ source: LibrarySource) -> URL {
        if let bookmark = source.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [],
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                return url
            }
        }
        return URL(fileURLWithPath: source.path)
    }

    private func retainScope(_ url: URL, for id: UUID) {
        guard openScopes[id] == nil else { return }
        // Returns false for folders inside the container, which need no scope.
        _ = url.startAccessingSecurityScopedResource()
        openScopes[id] = url
    }

    private static func loadSources() -> [LibrarySource] {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: sourcesKey),
           let decoded = try? JSONDecoder().decode([LibrarySource].self, from: data) {
            return decoded.map(rebasedOntoCurrentContainer)
        }
        // Builds before this stored a single path.
        if let legacy = defaults.string(forKey: legacyRootKey), !legacy.isEmpty {
            return [rebasedOntoCurrentContainer(LibrarySource(path: legacy))]
        }
        return [LibrarySource(path: defaultRoot, name: "On My iPhone")]
    }

    /// A folder inside the app container is stored as an absolute path, and
    /// that path carries the container's UUID — which iOS changes when the app
    /// is reinstalled. The saved source then points at a container that no
    /// longer exists, so the library looks empty until the folder is added
    /// again. Anything under *an* app container is re-anchored onto this one.
    private static func rebasedOntoCurrentContainer(_ source: LibrarySource) -> LibrarySource {
        let home = NSHomeDirectory()
        guard !source.path.hasPrefix(home),
              let anchor = source.path.range(of: "/Containers/Data/Application/") else { return source }
        let rest = source.path[anchor.upperBound...]        // <UUID>/Documents/…
        var fixed = source
        if let slash = rest.firstIndex(of: "/") {
            fixed.path = home + rest[slash...]
        } else {
            // The source *is* the container root — there is nothing after the
            // UUID to keep, and the bookmark points into the old container too.
            fixed.path = home
        }
        fixed.bookmark = nil
        return fixed
    }

    private static func saveSources(_ sources: [LibrarySource]) {
        guard let data = try? JSONEncoder().encode(sources) else { return }
        UserDefaults.standard.set(data, forKey: sourcesKey)
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
        // Folders whose scope is held are read through the resolved URL; the
        // rest (the app's own container) are plain paths. A folder added before
        // the scope could be taken — or one whose bookmark was made while a
        // provider was offline — gets another attempt here, because enumerating
        // a bare path into an unopened provider quietly yields nothing.
        var roots: [String] = []
        var refused: [String] = []
        for source in sources {
            if let held = openScopes[source.id] {
                roots.append(held.path)
                continue
            }
            let url = Self.resolve(source)
            if url.startAccessingSecurityScopedResource() {
                openScopes[source.id] = url
            } else if !source.path.hasPrefix(NSHomeDirectory()) {
                // Outside the container and the system said no: enumerating the
                // bare path would just return nothing, with no clue why.
                refused.append(source.path)
            }
            roots.append(url.path)
        }
        let scans = await Task.detached(priority: .userInitiated) {
            roots.map { path -> (String, [URL], String?) in
                let result = Self.audioScan(under: path)
                return (path, result.urls, result.failure)
            }
        }.value

        var urls: [URL] = []
        for (path, found, failure) in scans {
            urls.append(contentsOf: found)
            #if os(iOS)
            if let failure = failure { PickerLog.shared.note("cannot read \(path): \(failure)") }
            #endif
        }
        #if os(iOS)
        PickerLog.shared.note("scan: \(roots.count) folder\(roots.count == 1 ? "" : "s") → \(urls.count) playable")
        for path in refused.prefix(2) {
            PickerLog.shared.note("no permission for \(path)")
        }
        #endif
        let parsed = Self.deduplicate(await Self.parseHeaders(of: urls))
        #if os(iOS)
        // Music app songs are re-queried on each scan (their URLs are not
        // stable across launches), but never written into the file cache.
        MediaLibraryAccess.shared.refresh()
        let combined = parsed + MediaLibraryAccess.shared.tracks
        #else
        let combined = parsed
        #endif
        // Preserve the original dateAdded for files already known, so a rescan
        // doesn't reshuffle "Recently Added".
        let known = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0.dateAdded) })
        tracks = combined.map { track in
            var t = track
            if let existing = known[t.id] { t.dateAdded = existing }
            return t
        }
        isScanning = false
        lastScan = Date()
        UserDefaults.standard.set(lastScan, forKey: Self.lastScanKey)
        Self.saveCache(parsed)
    }

    /// Walks the tree collecting every playable file, and says why when it can't.
    ///
    /// A folder the app has no permission for (no security scope, provider
    /// offline) enumerates as empty rather than throwing, which reads as "this
    /// folder has no music". Reading the directory first turns that into a
    /// concrete error message.
    nonisolated private static func audioScan(under path: String) -> (urls: [URL], failure: String?) {
        let root = URL(fileURLWithPath: path)
        let fm = FileManager.default
        do {
            _ = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                           options: [.skipsHiddenFiles])
        } catch {
            return ([], (error as NSError).localizedDescription)
        }
        guard let walker = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return ([], "cannot enumerate this folder") }

        var urls: [URL] = []
        for case let url as URL in walker {
            // The Apple Music library is a package of database files, not music.
            if url.pathExtension == "musiclibrary" || url.pathExtension == "itlp" {
                walker.skipDescendants()
                continue
            }
            if AudioFormat.isSupported(url) { urls.append(url) }
        }
        return (urls, nil)
    }

    /// Parsing headers is I/O bound, so fan it out. A task group keeps this
    /// concurrency-safe; the previous `concurrentPerform` over an
    /// `UnsafeMutableBufferPointer` captured non-Sendable state.
    nonisolated private static func parseHeaders(of urls: [URL]) async -> [Track] {
        await withTaskGroup(of: (Int, Track?).self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask(priority: .userInitiated) {
                    let track = await Track.load(from: url)
                    return (index, track)
                }
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
        // Same recording in two formats: the lossless copy is the keeper.
        if lhs.format.isLossless != rhs.format.isLossless { return lhs.format.isLossless }
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
