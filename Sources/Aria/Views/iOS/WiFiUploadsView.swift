#if os(iOS)
import SwiftUI

/// What a Wi-Fi transfer left behind: one row per file, with a delete button —
/// a track dropped in by mistake has nowhere else to be removed from, since the
/// library itself never deletes files.
///
/// Lyric files land here too (they have to sit next to their song), so the list
/// marks them and the search looks at names, not just audio.
struct WiFiUploadsView: View {
    let palette: M3Palette

    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var player: AudioPlayer
    @Environment(\.dismiss) private var dismiss

    @State private var files: [UploadedFile] = []
    @State private var pending: UploadedFile?
    @State private var query = ""

    private var visible: [UploadedFile] {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return files }
        return files.filter { $0.name.localizedCaseInsensitiveContains(term) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(L("Received files"))
                    .font(.display(26, .semibold))
                    .foregroundStyle(palette.onSurface)
                Spacer(minLength: 8)
                Button { dismiss() } label: { Text(L("Done")) }
                    .buttonStyle(PillButtonStyle(
                        kind: .tonal, palette: palette,
                        padding: EdgeInsets(top: 8, leading: 18, bottom: 8, trailing: 18)))
            }
            .padding(.horizontal, 22)
            .padding(.top, 24)
            .padding(.bottom, 14)

            if !files.isEmpty {
                SearchPill(text: $query, palette: palette,
                           prompt: L("Search"), width: nil)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 12)
            }

            if files.isEmpty {
                emptyState(title: L("No files yet"),
                           detail: L("Drop music files onto the Wi-Fi transfer page and they show up here."))
            } else if visible.isEmpty {
                emptyState(title: "", detail: Lmatch(query))
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(visible) { file in
                            row(file)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                }
                .scrollDismissesKeyboard(.immediately)
            }

            Text(L("These files also live in Files › Aria › Wi-Fi Uploads, where they can be deleted the same way."))
                .font(.body(11))
                .foregroundStyle(palette.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 22)
                .padding(.top, 6)
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface)
        .onAppear { reload() }
        // An alert, not a confirmation dialog: inside a sheet the dialog's
        // cancel row can be dropped, leaving only "Delete" — which is the one
        // button you do not want to be the only way out.
        .alert(dialogTitle, isPresented: dialogShown) {
            Button(L("Delete"), role: .destructive) { deletePending() }
            Button(L("Cancel"), role: .cancel) { pending = nil }
        } message: {
            Text(L("The file is deleted from this iPhone. This can’t be undone."))
        }
    }

    // MARK: Pieces

    private func emptyState(title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            if !title.isEmpty {
                Text(title)
                    .font(.body(14, .medium))
                    .foregroundStyle(palette.onSurface)
            }
            Text(detail)
                .font(.body(12))
                .foregroundStyle(palette.onSurfaceVariant)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 34)
    }

    private func row(_ file: UploadedFile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: file.isLyric ? "text.alignleft" : "music.note")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.onSurfaceVariant)
                .frame(width: 34, height: 34)
                .background(Circle().fill(palette.surfaceContainerHigh))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(file.name)
                        .font(.body(13, .medium))
                        .foregroundStyle(palette.onSurface)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if file.isLyric {
                        Text(L("Lyrics"))
                            .font(.label(9.5, .semibold))
                            .foregroundStyle(palette.onPrimaryContainer)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(palette.primaryContainer))
                    }
                }
                Text(meta(file))
                    .font(.body(11))
                    .foregroundStyle(palette.onSurfaceVariant)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                pending = file
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Delete"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func meta(_ file: UploadedFile) -> String {
        let size = ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)
        let date = file.added.formatted(date: .abbreviated, time: .shortened)
        return "\(size) · \(date)"
    }

    // MARK: Actions

    private var dialogTitle: String {
        String(format: L("Delete “%@”?"), pending?.name ?? "")
    }

    private var dialogShown: Binding<Bool> {
        Binding(get: { pending != nil },
                set: { if !$0 { pending = nil } })
    }

    private func reload() {
        files = WiFiTransferServer.shared.uploadedFiles()
        WiFiTransferServer.shared.refreshStored()
    }

    private func deletePending() {
        guard let file = pending else { return }
        pending = nil

        // Let go of it before the file disappears, so the player bar cannot keep
        // offering a track that will never play again.
        player.forgetFile(at: file.url)
        try? FileManager.default.removeItem(at: file.url)
        reload()

        // The library was reading this folder, so it has to drop the track too.
        Task { await library.scan() }
    }
}
#endif
