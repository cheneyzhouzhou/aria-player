import Foundation

/// One track's membership in a playlist.
///
/// Three identifiers are stored because none is reliable alone. The relative
/// path breaks when a library is laid out differently on another device, and
/// filenames get mangled in transit — copying to iOS rewrites any non-ASCII
/// character. Title and album come from tags inside the file, so they survive
/// both.
struct PlaylistEntry: Codable, Hashable {
    var path: String        // relative to the library root, lower-cased
    var title: String
    var album: String

    var tagKey: String { (title + "\u{1}" + album).lowercased() }
    var fileName: String { (path as NSString).lastPathComponent }
}

/// A user-ordered set of tracks.
struct Playlist: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var entries: [PlaylistEntry] = []
    var created: Date = Date()

    var count: Int { entries.count }

    private enum CodingKeys: String, CodingKey {
        case id, name, entries, created, keys
    }

    init(name: String, entries: [PlaylistEntry] = []) {
        self.name = name
        self.entries = entries
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        if let entries = try c.decodeIfPresent([PlaylistEntry].self, forKey: .entries) {
            self.entries = entries
        } else if let legacy = try c.decodeIfPresent([String].self, forKey: .keys) {
            // Playlists written before tags were stored: keep the paths.
            self.entries = legacy.map { PlaylistEntry(path: $0, title: "", album: "") }
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(entries, forKey: .entries)
        try c.encode(created, forKey: .created)
    }
}

/// Strips the `/private` that macOS and iOS prepend when resolving symlinks.
///
/// `/tmp` and `/var` are both symlinks, so a root recorded as `/var/mobile/…`
/// and a scanned file reported as `/private/var/mobile/…` describe the same
/// place while sharing no common prefix. Without this the relative path is lost
/// and playlists fall back to matching on filename alone.
func standardizedLibraryPath(_ path: String) -> String {
    path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
}

extension Track {
    /// Path below the library root, lower-cased. `id` is absolute and differs
    /// between machines, so it can't be used for playlist membership.
    func playlistPath(root: String) -> String {
        let rootPath = standardizedLibraryPath(root)
        let base = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let path = standardizedLibraryPath(url.path)
        let relative = path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent
        return relative.lowercased()
    }

    func playlistEntry(root: String) -> PlaylistEntry {
        PlaylistEntry(path: playlistPath(root: root), title: title, album: album)
    }

    var tagKey: String { (title + "\u{1}" + album).lowercased() }
    var fileName: String { url.lastPathComponent.lowercased() }
}
