#if os(iOS)
import SwiftUI
import UIKit

/// Picks a music folder without ever leaving this process.
///
/// The system document picker browses in a separate process and returns the
/// answer over XPC. That round trip is what breaks under LiveContainer: the
/// helper resolves the requesting app through LaunchServices, a guest app is
/// not registered there, and the reply is dropped — the sheet stays open and
/// "Open" looks dead even though the button is live. `Fix File Picker` in
/// LiveContainer patches around it by forcing copy mode, which for a folder of
/// several hundred tracks means copying gigabytes before anything appears.
///
/// Everything here is plain `FileManager` on paths this process can already
/// read, so it works in a real install, under AltStore, and under LiveContainer
/// alike. The trade-off is reach: only folders the app can already open show up
/// — its own container, plus the container above it where LiveContainer keeps
/// the files a user copies in through the Files app.
struct LocalFolderBrowser: View {
    let palette: M3Palette
    var onPick: (PickedFolder) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var trail: [URL] = []
    @State private var entries: [FolderEntry] = []
    @State private var audioCount = 0
    @State private var isLoading = false
    @State private var problem: String?

    private var here: URL? { trail.last }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(palette.outline.opacity(0.22))
                .frame(height: 1)
            content
            footer
        }
        .background(palette.surface.ignoresSafeArea())
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                if trail.isEmpty { dismiss() } else { trail.removeLast(); reload() }
            } label: {
                Image(systemName: trail.isEmpty ? "xmark" : "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.onSurface)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(palette.surfaceContainerHigh))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.display(19, .semibold))
                    .foregroundStyle(palette.onSurface)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.body(10.5))
                    .foregroundStyle(palette.onSurfaceVariant)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var title: String {
        guard let here else { return L("Add a folder") }
        let name = here.lastPathComponent
        return name.isEmpty ? here.path : name
    }

    private var subtitle: String {
        guard let here else { return L("Folders Aria can read on this phone") }
        return FolderScan.shortPath(here)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .tint(palette.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if trail.isEmpty {
            list(Place.discover().map { ($0.title, $0.detail, $0.url) })
        } else if entries.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(palette.onSurfaceVariant)
                Text(problem ?? L("No folders inside this one."))
                    .font(.body(12))
                    .foregroundStyle(palette.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            list(entries.map { ($0.name, $0.detail, $0.url) })
        }
    }

    private func list(_ items: [(String, String, URL)]) -> some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(items, id: \.2.path) { item in
                    row(item.0, item.1) {
                        trail.append(item.2)
                        reload()
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
    }

    private func row(_ name: String, _ detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(palette.primary)
                    .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.body(13, .medium))
                        .foregroundStyle(palette.onSurface)
                        .lineLimit(1)
                    Text(detail)
                        .font(.body(10.5))
                        .foregroundStyle(palette.onSurfaceVariant)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.onSurfaceVariant)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 16).fill(palette.surfaceContainerHigh))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var placesHint: String {
        GuestEnvironment.isLiveContainer
            ? L("The folder Files shows for LiveContainer is listed here — copy music into it and Aria can read it without the system picker.")
            : L("These are the folders this build can already open. Copy music into Aria's Documents from the Files app and it shows up here.")
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if trail.isEmpty {
                Text(placesHint)
                    .font(.body(10.5))
                    .foregroundStyle(palette.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 22)
            } else {
                Text(audioCount == 0
                     ? L("No music files here or below.")
                     : (LanguageSettings.shared.isChinese
                        ? "此处及子文件夹中共有 \(Lplural(audioCount, "track"))。"
                        : "\(audioCount) track\(audioCount == 1 ? "" : "s") here and in subfolders."))
                    .font(.body(11))
                    .foregroundStyle(audioCount == 0 ? palette.onSurfaceVariant : palette.primary)
                Button(L("Use this folder")) { pick() }
                    .buttonStyle(PillButtonStyle(kind: .filled, palette: palette))
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 22)
    }

    // MARK: - Work

    private func pick() {
        guard let here else { return }
        PickerLog.shared.note("browser picked \(here.lastPathComponent)")
        onPick(PickedFolder(url: here, name: displayName(for: here)))
        dismiss()
    }

    /// An app container's own name is a UUID, so the two folders that are worth
    /// naming get a name and everything else keeps its own.
    private func displayName(for url: URL) -> String? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        if url.path == home.path { return L("Aria's folder") }
        if url.path == home.appendingPathComponent("Documents").path { return L("Aria's Documents") }
        return nil
    }

    private func reload() {
        guard let here else {
            entries = []
            audioCount = 0
            isLoading = false
            return
        }
        isLoading = true
        problem = nil
        Task {
            let scan = await Task.detached(priority: .userInitiated) {
                FolderScan.read(here)
            }.value
            entries = scan.entries
            audioCount = scan.audio
            problem = scan.problem
            isLoading = false
        }
    }
}

// MARK: - One readable place

private struct Place: Identifiable {
    var id: String { url.path }
    let url: URL
    let title: String
    let detail: String

    /// The folders that are worth offering, worked out from where this process
    /// is running rather than from a fixed list.
    ///
    /// In a normal install that is the app container and its Documents. Inside
    /// LiveContainer the app's container sits several levels below
    /// LiveContainer's own, and the folder users can drop music into through
    /// the Files app is a `Documents` on one of those levels — hence the walk up.
    static func discover() -> [Place] {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let ownDocuments = home.appendingPathComponent("Documents")

        var places: [Place] = [
            Place(url: home, title: L("Aria's own folder"),
                  detail: L("Where anything you share into Aria lands"))
        ]
        if fm.fileExists(atPath: ownDocuments.path) {
            places.append(Place(url: ownDocuments, title: L("Aria's Documents"),
                                detail: FolderScan.shortPath(ownDocuments)))
        }

        // Only LiveContainer nests the app's container inside its own, and only
        // there is walking up worth anything: the folder users can drop music
        // into through the Files app is a `Documents` a few levels above.
        // On a normal install the levels above hold nothing of theirs.
        guard GuestEnvironment.isLiveContainer else { return places }

        var seen = Set(places.map(\.url.path))
        var cursor = home
        for _ in 1...4 {
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { break }
            cursor = parent
            let docs = cursor.appendingPathComponent("Documents")
            guard fm.fileExists(atPath: docs.path), seen.insert(docs.path).inserted else { continue }
            let owner = cursor.lastPathComponent
            places.append(Place(url: docs,
                                title: owner.isEmpty ? L("Documents above Aria") : "\(owner) · " + L("Documents"),
                                detail: FolderScan.shortPath(docs)))
        }
        return places
    }
}

// MARK: - Reading a directory

struct FolderEntry: Identifiable {
    var id: String { url.path }
    let url: URL
    let name: String
    let detail: String
}

enum FolderScan {
    struct Result {
        var entries: [FolderEntry] = []
        var audio = 0
        var problem: String?
    }

    /// Only folders are listed: this picks a folder, not a file.
    static func read(_ url: URL) -> Result {
        let fm = FileManager.default
        var result = Result()
        do {
            let items = try fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])

            var folders: [FolderEntry] = []
            for item in items {
                let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
                guard isDirectory == true else { continue }
                // A count of what is one tap away is what tells two folders
                // apart; reading the whole tree for every row would not.
                let inner = (try? fm.contentsOfDirectory(
                    at: item,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles])) ?? []
                let audio = inner.filter { AudioFormat.isSupported($0) }.count
                let subs = inner.filter {
                    (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                }.count
                var bits: [String] = []
                if audio > 0 { bits.append(Lplural(audio, "track")) }
                if subs > 0 { bits.append(Lplural(subs, "folder")) }
                folders.append(FolderEntry(url: item,
                                           name: item.lastPathComponent,
                                           detail: bits.isEmpty ? L("Empty") : bits.joined(separator: " · ")))
            }
            folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            result.entries = folders
            result.audio = count(under: url)
        } catch {
            result.problem = L("Can't read this folder") + " — " + error.localizedDescription
        }
        return result
    }

    /// How many playable files the folder holds, subfolders included. Capped so
    /// a huge tree cannot make the sheet feel stuck.
    static func count(under url: URL, cap: Int = 20000) -> Int {
        guard let walk = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return 0 }
        var total = 0
        for case let item as URL in walk {
            guard AudioFormat.isSupported(item) else { continue }
            total += 1
            if total >= cap { break }
        }
        return total
    }

    /// The container path is UUID soup; show the part that identifies it.
    static func shortPath(_ url: URL) -> String {
        let home = NSHomeDirectory()
        if url.path == home { return L("app container") }
        if url.path.hasPrefix(home + "/") {
            return "~/" + url.path.dropFirst(home.count + 1)
        }
        return url.pathComponents.suffix(3).joined(separator: "/")
    }
}

/// What the folder picker did, in order, for when it does nothing.
struct FolderPickerReport: View {
    let palette: M3Palette

    @StateObject private var log = PickerLog.shared
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: GuestEnvironment.isLiveContainer
                      ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(GuestEnvironment.isLiveContainer
                                     ? Color(red: 0.99, green: 0.68, blue: 0.29)
                                     : palette.onSurfaceVariant)
                Text(GuestEnvironment.isLiveContainer
                     ? L("Running inside LiveContainer")
                     : L("Running as a normal install"))
                    .font(.body(11.5, .medium))
                    .foregroundStyle(palette.onSurface)
                Spacer(minLength: 6)
                Button(copied ? L("Copied") : L("Copy")) {
                    UIPasteboard.general.string = log.report
                    copied = true
                }
                .buttonStyle(PillButtonStyle(kind: .tonal, palette: palette, size: 11,
                                             padding: EdgeInsets(top: 6, leading: 12,
                                                                 bottom: 6, trailing: 12)))
            }

            if GuestEnvironment.isLiveContainer {
                Text(L("LiveContainer's system picker cannot always hand a folder back to a guest app. Long-press Aria → Settings → enable Fix File Picker, or use Browse phone…, which stays inside Aria."))
                    .font(.body(10.5))
                    .foregroundStyle(palette.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !log.lines.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(log.lines.suffix(5), id: \.self) { line in
                        Text(line)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(palette.onSurfaceVariant)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
            }
        }
    }
}
#endif
