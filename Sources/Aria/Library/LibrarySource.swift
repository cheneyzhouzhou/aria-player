import Foundation

/// A folder Aria reads music from.
///
/// On iOS a folder outside the app container is only reachable through a
/// security-scoped bookmark, so every source carries one. The bookmark is what
/// survives a relaunch, and it keeps working if the folder is moved; `path` is
/// kept for display and for the macOS panel, which hands back a plain path.
struct LibrarySource: Identifiable, Codable, Hashable {
    var id: UUID
    var path: String
    var name: String
    var bookmark: Data?

    init(id: UUID = UUID(), path: String, name: String? = nil, bookmark: Data? = nil) {
        self.id = id
        self.path = path
        self.name = name ?? URL(fileURLWithPath: path).lastPathComponent
        self.bookmark = bookmark
    }

    /// A bookmark for a folder the system just handed us.
    static func bookmark(for url: URL) -> Data? {
        func make(_ options: URL.BookmarkCreationOptions) -> Data? {
            try? url.bookmarkData(options: options,
                                  includingResourceValuesForKeys: nil,
                                  relativeTo: nil)
        }
        #if os(macOS)
        // A security-scoped bookmark is only writable from a sandboxed app;
        // fall back to a plain one when this build isn't sandboxed.
        return make([.withSecurityScope]) ?? make([])
        #else
        // `.withSecurityScope` is macOS-only. On iOS the URL from the document
        // picker already carries the scope, and a plain bookmark resolves back
        // to a URL that `startAccessingSecurityScopedResource()` can open.
        return make([])
        #endif
    }
}

/// A folder the system picker just handed back, together with the access that
/// came with it.
///
/// The security scope has to be taken while the picker's grant is still live —
/// it is the only moment the system will hand it out. Doing that here, inside
/// the picker's own callback, is what makes the folder readable afterwards;
/// deferring it to a later task is how a folder can be picked and then turn
/// out to be unreadable.
struct PickedFolder {
    /// The URL the scope was taken on, used for every read from here on.
    let url: URL
    /// Path to store and display. Normalised, but never used to take the grant.
    let path: String
    let bookmark: Data?
    /// True when a scope was started and must be released when the source is
    /// removed. False for folders inside the app container, which need none.
    let holdsScope: Bool
    /// True when the folder is outside Aria's container, so a false `holdsScope`
    /// really does mean the system refused access.
    let isOutsideContainer: Bool
    /// What to call it in Settings. The in-app browser knows a better name than
    /// the last path component — an app container is a UUID.
    let name: String?

    init(url raw: URL, name: String? = nil) {
        // Take the grant first, on the exact URL the picker handed over.
        //
        // A security scope belongs to that URL object, not to the path: asking
        // for `standardizedFileURL` (or `resolvingSymlinksInPath()`) makes a
        // brand-new URL that no longer carries it, and
        // `startAccessingSecurityScopedResource()` then answers false for a
        // folder that is perfectly reachable. That is why an earlier build
        // logged "scope refused" for a folder in On My iPhone: the picked URL
        // was `/private/var/…` and the normalised one came back as `/var/…`.
        let firstTry = raw.startAccessingSecurityScopedResource()

        let data = LibrarySource.bookmark(for: raw)
        var reader = raw
        var granted = firstTry
        var stale = false
        if !granted, let data,
           let resolved = try? URL(resolvingBookmarkData: data, options: [],
                                   relativeTo: nil, bookmarkDataIsStale: &stale) {
            // Some providers drop the grant while the URL travels back over
            // XPC. The bookmark written a moment ago still holds it, so going
            // through the bookmark restores access.
            granted = resolved.startAccessingSecurityScopedResource()
            if granted { reader = resolved }
        }

        let home = NSHomeDirectory()
        let normalised = raw.standardizedFileURL.path
        self.url = reader
        self.path = normalised
        self.holdsScope = granted
        self.isOutsideContainer = !normalised.hasPrefix(home)
        // Must be written while the grant is live, so it is written above.
        self.bookmark = data
        self.name = name
    }
}
