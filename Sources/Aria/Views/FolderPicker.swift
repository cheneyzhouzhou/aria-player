#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A short, ordered record of what the folder picker actually did.
///
/// The picker hands its answer back from a separate system process, so when it
/// fails there is nothing in this process to inspect — no error, no callback,
/// just a modal that sits there. These few lines are what turns "nothing
/// happens" into a report: whether the picker was presented at all, from which
/// controller, and whether the answer came back.
@MainActor
final class PickerLog: ObservableObject {
    static let shared = PickerLog()

    @Published private(set) var lines: [String] = []

    private let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    func note(_ text: String) {
        let line = "\(clock.string(from: Date()))  \(text)"
        lines.append(line)
        // Enough to see the sequence of one attempt, short enough to read on a
        // phone and to paste in a message.
        if lines.count > 14 { lines.removeFirst(lines.count - 14) }
        // The on-screen list is easier to read but impossible to scroll to on a
        // small phone, and it disappears with the process. The file is what can
        // be pulled off the device afterwards.
        append(line + "\n")
    }

    /// `Library/Application Support/Aria/picker.log`, best effort.
    private static let logURL: URL? = {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask).first else { return nil }
        let folder = base.appendingPathComponent("Aria", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("picker.log")
    }()

    private func append(_ text: String) {
        guard let url = Self.logURL else { return }
        let data = Data(text.utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// What the user can copy out of Settings.
    var report: String {
        let host = GuestEnvironment.isLiveContainer ? "LiveContainer" : "standard install"
        return (["host: \(host)", "home: \(NSHomeDirectory())"] + lines).joined(separator: "\n")
    }
}

enum GuestEnvironment {
    /// True when the app is a guest inside LiveContainer.
    ///
    /// LiveContainer runs a guest as a dylib inside its own process and mirrors
    /// the guest's bundle, so the app's own container lives under LiveContainer's.
    /// That is also why the document picker can fail here: the helper process
    /// resolves the requesting app through LaunchServices, which only knows
    /// LiveContainer, so the reply has nowhere to go and "Open" looks dead even
    /// though the button is live.
    static var isLiveContainer: Bool {
        let home = NSHomeDirectory()
        return home.contains("/LiveContainer/") || Bundle.main.bundlePath.contains("/LiveContainer/")
    }
}

/// The system folder picker, presented as a real modal.
///
/// This is how Cog, foobar2000 mobile and FiFlac all do it, and the reason is
/// the failure below. A `UIDocumentPickerViewController` used as a SwiftUI
/// sheet's *content* is only a child view controller: it inherits no
/// navigation controller, so it never builds its own bar. The sheet comes up as
/// a blank white panel — no Cancel, no Open, no locations — and the only thing
/// the user can do is swipe it away. That is exactly what "Add folder…" did.
///
/// Presented modally instead, the picker owns its presentation: it grows the
/// usual Cancel/Open bar, the browser and the location list all work, and the
/// delegate callback fires while the grant is still live.
///
/// `asCopy: false` matters just as much. Import mode copies every file of the
/// folder into the app container before returning, so a large library looks
/// like a spinner that never ends.
///
/// `LocalFolderBrowser` exists because this class of picker cannot work
/// everywhere: inside LiveContainer the round trip back never completes.
@MainActor
enum FolderPicker {
    /// UIKit does not retain a presented controller's delegate, and the
    /// picker has to outlive both the call that started it and its own
    /// dismissal. One pick at a time is held here.
    private static var active: (picker: UIDocumentPickerViewController, delegate: Delegate)?

    static func present(startingAt directory: URL?,
                        onPick: @escaping (PickedFolder) -> Void) {
        present(copying: false, startingAt: directory, onPick: onPick)
    }

    /// The same picker, in import mode.
    ///
    /// Import mode copies the folder into Aria's own container before handing
    /// it back, so the result needs no security scope at all. That makes it the
    /// one path that works even when a re-signed build is refused the grant for
    /// a folder in On My iPhone — the price is disk space and a wait.
    static func presentCopying(startingAt directory: URL?,
                               onPick: @escaping (PickedFolder) -> Void) {
        present(copying: true, startingAt: directory, onPick: onPick)
    }

    private static func present(copying: Bool,
                                startingAt directory: URL?,
                                onPick: @escaping (PickedFolder) -> Void) {
        // A picker that was swiped away can leave its delegate registered
        // without ever calling back. Without this, one failed attempt would
        // silently swallow every later tap on "Add folder".
        if let stale = active, stale.picker.presentingViewController == nil {
            active = nil
            PickerLog.shared.note("cleared a picker that never answered")
        }
        guard active == nil else {
            PickerLog.shared.note("picker already on screen")
            return
        }
        guard let host = topViewController() else {
            PickerLog.shared.note("no view controller to present from")
            return
        }

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder],
                                                    asCopy: copying)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        // Open where the last folder was added rather than at an empty
        // "Recents" list. Adding a second folder then takes two taps, and it
        // saves hunting for the Browse tab.
        if let directory { picker.directoryURL = directory }

        let delegate = Delegate(
            onPick: { controller, url in
                // The whole path, not the name: "IPA" says nothing about where
                // it came from, and picking the wrong folder is the most common
                // way this ends with an empty library.
                PickerLog.shared.note("picked \(url.path)")
                // Take the scope and write the bookmark before the grant is
                // torn down with the picker.
                let folder = PickedFolder(url: url)
                if folder.holdsScope {
                    PickerLog.shared.note(folder.url.path == folder.path
                                          ? "scope opened"
                                          : "scope opened, reading via \(folder.url.path)")
                } else if !folder.isOutsideContainer {
                    PickerLog.shared.note("inside Aria's own container — no scope needed")
                } else {
                    PickerLog.shared.note("scope refused, and no bookmark grant either")
                }
                PickerLog.shared.note(folder.bookmark == nil ? "bookmark: none" : "bookmark: written")
                controller.dismiss(animated: true) {
                    FolderPicker.active = nil
                    onPick(folder)
                }
            },
            onCancel: { controller in
                PickerLog.shared.note("cancelled")
                controller.dismiss(animated: true) {
                    FolderPicker.active = nil
                }
            },
            onDismiss: {
                // Swiped down without any delegate call: the system never
                // delivered an answer.
                if FolderPicker.active != nil {
                    PickerLog.shared.note("dismissed with no callback")
                }
                FolderPicker.active = nil
            })

        picker.delegate = delegate
        picker.presentationController?.delegate = delegate
        active = (picker, delegate)
        PickerLog.shared.note("presented\(copying ? " (copy mode)" : "") from \(type(of: host))")
        host.present(picker, animated: true)
    }

    /// The view controller a modal can actually be presented from: the top of
    /// whatever is already showing, so this works from a sheet as well as from
    /// the root.
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    final class Delegate: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
        private let picked: (UIDocumentPickerViewController, URL) -> Void
        private let cancelled: (UIDocumentPickerViewController) -> Void
        private let dismissed: () -> Void

        init(onPick: @escaping (UIDocumentPickerViewController, URL) -> Void,
             onCancel: @escaping (UIDocumentPickerViewController) -> Void,
             onDismiss: @escaping () -> Void) {
            picked = onPick
            cancelled = onCancel
            dismissed = onDismiss
        }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            picked(controller, url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            cancelled(controller)
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            dismissed()
        }
    }
}
#endif
