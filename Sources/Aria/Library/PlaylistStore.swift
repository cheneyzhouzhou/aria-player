import Foundation
import SwiftUI

@MainActor
final class PlaylistStore: ObservableObject {
    @Published private(set) var playlists: [Playlist] = []

    init() {
        playlists = Self.load()
    }

    // MARK: - Editing

    @discardableResult
    func create(named name: String, tracks: [Track] = [], root: String) -> Playlist {
        var list = Playlist(name: name)
        list.entries = tracks.map { $0.playlistEntry(root: root) }
        playlists.append(list)
        save()
        return list
    }

    func rename(_ list: Playlist, to name: String) {
        guard let index = playlists.firstIndex(where: { $0.id == list.id }) else { return }
        playlists[index].name = name
        save()
    }

    func delete(_ list: Playlist) {
        playlists.removeAll { $0.id == list.id }
        save()
    }

    func add(_ track: Track, to list: Playlist, root: String) {
        guard let index = playlists.firstIndex(where: { $0.id == list.id }) else { return }
        let entry = track.playlistEntry(root: root)
        guard !playlists[index].entries.contains(where: { $0.path == entry.path }) else { return }
        playlists[index].entries.append(entry)
        save()
    }

    func remove(at offsets: IndexSet, from list: Playlist) {
        guard let index = playlists.firstIndex(where: { $0.id == list.id }) else { return }
        playlists[index].entries.remove(atOffsets: offsets)
        save()
    }

    func remove(_ track: Track, from list: Playlist, root: String) {
        guard let index = playlists.firstIndex(where: { $0.id == list.id }) else { return }
        let entry = track.playlistEntry(root: root)
        playlists[index].entries.removeAll {
            $0.path == entry.path || ($0.tagKey == entry.tagKey && !entry.title.isEmpty)
        }
        save()
    }

    /// Refreshes a stored playlist so callers always see current membership.
    func current(_ list: Playlist) -> Playlist {
        playlists.first { $0.id == list.id } ?? list
    }

    // MARK: - Resolution

    /// Turns stored entries back into tracks, preserving playlist order.
    ///
    /// Three passes, most reliable first: the relative path, then title+album
    /// from the file's own tags, then the bare filename. Tags are what rescue a
    /// playlist moved to a device where paths differ or filenames were rewritten
    /// in transit.
    func tracks(in list: Playlist, library: [Track], root: String) -> [Track] {
        var byPath: [String: Track] = [:]
        var byTag: [String: Track] = [:]
        var byName: [String: Track] = [:]
        for track in library {
            byPath[track.playlistPath(root: root)] = track
            byTag[track.tagKey] = track
            byName[track.fileName] = track
        }
        return current(list).entries.compactMap { entry in
            byPath[entry.path]
                ?? (entry.title.isEmpty ? nil : byTag[entry.tagKey])
                ?? byName[entry.fileName.lowercased()]
        }
    }

    /// Builds one playlist per top-level folder of the library — the quickest
    /// way to turn an existing folder layout into something playable.
    func importFolders(from library: [Track], root: String) -> Int {
        let rootPath = standardizedLibraryPath(root)
        let base = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        var grouped: [String: [Track]] = [:]
        for track in library {
            let path = standardizedLibraryPath(track.url.path)
            guard path.hasPrefix(base) else { continue }
            let relative = String(path.dropFirst(base.count))
            guard let folder = relative.split(separator: "/").first, relative.contains("/") else { continue }
            grouped[String(folder), default: []].append(track)
        }

        var added = 0
        for (folder, tracks) in grouped.sorted(by: { $0.key < $1.key }) {
            guard !playlists.contains(where: { $0.name == folder }) else { continue }
            let ordered = tracks.sorted {
                ($0.albumKey, $0.discNumber, $0.trackNumber, $0.title)
                    < ($1.albumKey, $1.discNumber, $1.trackNumber, $1.title)
            }
            create(named: folder, tracks: ordered, root: root)
            added += 1
        }
        return added
    }

    // MARK: - Persistence

    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aria", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("playlists.json")
    }

    private static func load() -> [Playlist] {
        guard let data = try? Data(contentsOf: url),
              let lists = try? JSONDecoder().decode([Playlist].self, from: data) else { return [] }
        return lists
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(playlists) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }
}
