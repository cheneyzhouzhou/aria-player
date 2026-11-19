import SwiftUI

/// "Import folders" with a choice of source.
///
/// Drawn as a card rather than a system sheet: on macOS a `.sheet` sized itself
/// to a bare ScrollView and came up as nothing at all, so the button read as
/// dead. This is the same kind of overlay the confirmations use, which behaves
/// identically on both platforms.
struct PlaylistImportPicker: View {
    let sources: [LibrarySource]
    let trackCount: (LibrarySource) -> Int
    let onPick: (LibrarySource) -> Void
    let onCancel: () -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        ZStack {
            Color.black.opacity(0.30)
                .ignoresSafeArea()
                .onTapGesture(perform: onCancel)

            VStack(spacing: 0) {
                Text(L("Import from"))
                    .font(.body(16, .semibold))
                    .foregroundStyle(palette.onSurface)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
                    .padding(.bottom, 14)

                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(sources) { source in
                            Button {
                                onPick(source)
                            } label: {
                                HStack(spacing: 11) {
                                    Image(systemName: "folder")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(palette.primary)
                                        .frame(width: 22)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(source.name)
                                            .font(.body(14, .medium))
                                            .foregroundStyle(palette.onSurface)
                                            .lineLimit(1)
                                        Text(Lplural(trackCount(source), "song"))
                                            .font(.body(11))
                                            .foregroundStyle(palette.onSurfaceVariant)
                                    }

                                    Spacer(minLength: 6)

                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(palette.onSurfaceVariant.opacity(0.65))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 12)
                                    .fill(palette.surfaceContainerHigh.opacity(0.7)))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                // Fits the rows it has, up to five of them: a fixed tall panel
                // left the one-folder case looking like an empty window.
                .frame(height: min(260, max(64, CGFloat(sources.count) * 62)))

                Rectangle()
                    .fill(palette.outline.opacity(0.28))
                    .frame(height: 0.5)
                    .padding(.top, 14)

                Button(action: onCancel) {
                    Text(L("Cancel"))
                        .font(.body(15, .medium))
                        .foregroundStyle(palette.primary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(height: 46)
            }
            .frame(width: 330)
            // A tinted card rather than the glass surface: as a background the
            // glass kept its own height and the title ended up half outside it.
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(palette.surfaceContainer)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(palette.outline.opacity(0.20), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.26), radius: 26, y: 12)
        }
    }
}
