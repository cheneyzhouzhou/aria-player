import SwiftUI

/// A small confirmation card we draw ourselves.
///
/// The system `.alert` on this OS lays its title and message out flush left,
/// which reads as a caption for the buttons rather than as a question. Here the
/// title sits dead centre, the message follows it, and the two actions share the
/// bottom edge — the familiar shape, minus the alignment surprise.
struct ConfirmDialog: View {
    let title: String
    let message: String
    let confirmTitle: String
    var isDestructive: Bool = true
    /// A message has only one way out; a question keeps both.
    var showsCancel: Bool = true
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        ZStack {
            Color.black.opacity(0.30)
                .ignoresSafeArea()
                .onTapGesture(perform: onCancel)

            VStack(spacing: 0) {
                VStack(spacing: 7) {
                    Text(title)
                        .font(.body(17, .semibold))
                        .foregroundStyle(palette.onSurface)
                        .multilineTextAlignment(.center)

                    Text(message)
                        .font(.body(13))
                        .foregroundStyle(palette.onSurfaceVariant)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 20)

                Rectangle()
                    .fill(palette.outline.opacity(0.28))
                    .frame(height: 0.5)

                HStack(spacing: 0) {
                    if showsCancel {
                    Button(action: onCancel) {
                        Text(L("Cancel"))
                            .font(.body(16, .medium))
                            .foregroundStyle(palette.primary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Rectangle()
                        .fill(palette.outline.opacity(0.28))
                        .frame(width: 0.5)
                    }

                    Button(action: onConfirm) {
                        Text(confirmTitle)
                            .font(.body(16, .semibold))
                            .foregroundStyle(isDestructive ? Color.red : palette.primary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .frame(height: 50)
            }
            .frame(width: 300)
            // Same glass as the player's popups (EQ, queue, audio chain) and
            // the settings sheets, so a question looks like the rest of the app.
            .background {
                GlassSurface(shape: RoundedRectangle(cornerRadius: 22, style: .continuous),
                             tint: palette.surfaceContainer,
                             border: palette.outline,
                             radius: 22, popup: true)
            }
            .shadow(color: .black.opacity(0.28), radius: 26, y: 12)
        }
    }
}
