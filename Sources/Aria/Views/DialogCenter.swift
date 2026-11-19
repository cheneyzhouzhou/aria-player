import SwiftUI

/// Hosts the app's own confirmation dialogs at the top of the view tree.
///
/// Presenting one from inside a page dims only that page — on the phone the
/// sheet ends above the bottom bar, so the overlay stopped mid-screen and the
/// bar stayed tappable behind it. Raised here, the dim and the card cover the
/// whole window, and the bar can't be reached while a question is open.
@MainActor
final class DialogCenter: ObservableObject {
    struct Request: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let confirmTitle: String
        var showsCancel: Bool = true
    }

    @Published private(set) var request: Request?
    /// Set while the "import from" picker is up. It lives here for the same
    /// reason the confirmations do: presented from a page it dims only the page.
    @Published var showsImportPicker = false
    /// A one-line result shown under a page's buttons and cleared on its own.
    @Published private(set) var note: String?
    private var action: (() -> Void)?
    private var noteToken = UUID()

    /// Asks the user to confirm something. `onConfirm` runs only if they agree.
    func confirm(title: String, message: String, confirmTitle: String,
                 action: @escaping () -> Void) {
        self.action = action
        request = Request(title: title, message: message, confirmTitle: confirmTitle)
    }

    /// A single-button card, for "nothing to do" style explanations.
    func message(title: String, message: String, confirmTitle: String) {
        action = nil
        request = Request(title: title, message: message,
                          confirmTitle: confirmTitle, showsCancel: false)
    }

    func showNote(_ text: String, seconds: Double = 3.5) {
        note = text
        let token = UUID()
        noteToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.noteToken == token else { return }
            withAnimation(.easeOut(duration: 0.2)) { self.note = nil }
        }
    }

    func clearNote() { note = nil }

    func cancel() {
        action = nil
        request = nil
    }

    func perform() {
        let work = action
        action = nil
        request = nil
        work?()
    }
}

/// The card itself, drawn above everything else. Drop it at the root.
struct DialogHost: View {
    @ObservedObject var center: DialogCenter
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playlists: PlaylistStore

    var body: some View {
        ZStack {
            if let request = center.request {
                ConfirmDialog(
                    title: request.title,
                    message: request.message,
                    confirmTitle: request.confirmTitle,
                    showsCancel: request.showsCancel,
                    onConfirm: { center.perform() },
                    onCancel: { center.cancel() }
                )
                .transition(.opacity)
            }

            if center.showsImportPicker {
                PlaylistImportPicker(
                    sources: library.sources,
                    trackCount: { library.trackCount(in: $0) },
                    onPick: { source in
                        center.showsImportPicker = false
                        let added = playlists.importSource(source, from: library.tracks, root: library.rootPath)
                        center.showNote(added > 0
                                        ? String(format: L("Imported %d playlists."), added)
                                        : String(format: L("Nothing new in “%@”."), source.name))
                    },
                    onCancel: { center.showsImportPicker = false }
                )
                .transition(.opacity)
            }
        }
        .zIndex(10)
    }
}
