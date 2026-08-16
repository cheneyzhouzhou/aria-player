import SwiftUI

struct SettingsView: View {
    /// Supplied when hosted inside the main window; computed for the ⌘, window.
    var palette: M3Palette? = nil

    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var palettes: PaletteStore
    @EnvironmentObject var player: AudioPlayer
    @Environment(\.colorScheme) private var scheme

    private var p: M3Palette {
        palette ?? M3Palette(seed: palettes.librarySeed, isDark: scheme == .dark)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Settings")
                    .font(.display(40, .semibold))
                    .foregroundStyle(p.onSurface)
                    .padding(.top, 40)

                section("Appearance") {
                    VStack(alignment: .leading, spacing: 14) {
                        row("Theme colour", "Tints the library. The player takes its colour from the artwork instead.")
                        HueBar(hue: $palettes.libraryHue, palette: p)
                            .frame(height: 30)
                        swatches
                    }
                }

                section("Music folder") {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(displayPath)
                            .font(.body(12.5))
                            .foregroundStyle(p.onSurface)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .help(library.rootPath)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                            .background(Capsule().fill(p.surfaceContainerHigh))

                        if Platform.supportsFolderPicker {
                            Button("Choose folder…") { chooseFolder() }
                                .buttonStyle(PillButtonStyle(kind: .tonal, palette: p))
                                .disabled(library.isScanning)
                        } else {
                            Text("Drag FLAC files into Aria in Finder while your iPhone is connected.")
                                .font(.body(11.5))
                                .foregroundStyle(p.onSurfaceVariant)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                #if os(iOS)
                section("Output") {
                    VStack(alignment: .leading, spacing: 10) {
                        row("Playing through", player.outputDescription)
                        if player.outputIsLossy {
                            Text("Bluetooth re-encodes audio before it reaches your headphones, so lossless files stop being lossless at that point. Wired headphones or a USB-C DAC keep the full quality.")
                                .font(.body(11))
                                .foregroundStyle(p.onSurfaceVariant)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("Aria asks the hardware to run at the file's own sample rate, so nothing is resampled on the way out.")
                                .font(.body(11))
                                .foregroundStyle(p.onSurfaceVariant)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                #endif

                section("Library") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 22) {
                            stat(plural(library.tracks.count, "song"))
                            stat(plural(library.albums.count, "album"))
                            stat(formatDurationLong(library.totalDuration))
                        }

                        row("Last scanned", lastScanText)

                        HStack(spacing: 12) {
                            Button {
                                Task { await library.scan() }
                            } label: {
                                Label("Rescan library", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(PillButtonStyle(kind: .filled, palette: p))
                            .disabled(library.isScanning)

                            if library.isScanning {
                                ProgressView().controlSize(.small).scaleEffect(0.75)
                                Text("Scanning…")
                                    .font(.body(12))
                                    .foregroundStyle(p.onSurfaceVariant)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, screenInset)
            .padding(.bottom, playerClearance)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(p.surface)
    }

    // MARK: Pieces

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.label(11, .semibold))
                .tracking(0.9)
                .foregroundStyle(p.primary)
            content()
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(p.surfaceContainer))
        }
    }

    private func row(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.body(13.5, .medium))
                .foregroundStyle(p.onSurface)
            Text(detail)
                .font(.body(11.5))
                .foregroundStyle(p.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stat(_ text: String) -> some View {
        Text(text)
            .font(.label(12, .semibold))
            .foregroundStyle(p.onPrimaryContainer)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(p.primaryContainer))
    }

    /// Quick jumps to a few pleasant hues.
    private var swatches: some View {
        HStack(spacing: 10) {
            ForEach([0.62, 0.75, 0.88, 0.02, 0.10, 0.33, 0.48], id: \.self) { hue in
                Button {
                    withAnimation(.easeInOut(duration: 0.4)) { palettes.libraryHue = hue }
                } label: {
                    Circle()
                        .fill(Color(hue: hue, saturation: 0.62, brightness: 0.85))
                        .frame(width: 26, height: 26)
                        .overlay {
                            Circle().strokeBorder(
                                p.onSurface.opacity(abs(palettes.libraryHue - hue) < 0.01 ? 0.9 : 0),
                                lineWidth: 2.5)
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var displayPath: String {
        // homeDirectoryForCurrentUser is macOS-only; NSHomeDirectory works on
        // both, returning the app container on iOS.
        let home = NSHomeDirectory()
        return library.rootPath.hasPrefix(home)
            ? "~" + library.rootPath.dropFirst(home.count)
            : library.rootPath
    }

    private var lastScanText: String {
        guard let date = library.lastScan else { return "Never" }
        // The relative formatter renders a fresh scan as "in 0 seconds".
        guard Date().timeIntervalSince(date) > 10 else { return "Just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func chooseFolder() {
        Platform.chooseFolder(startingAt: library.rootPath) { path in
            library.rootPath = path
            Task { await library.scan() }
        }
    }
}

/// Full-spectrum hue picker drawn as a Material track with a pill handle.
struct HueBar: View {
    @Binding var hue: Double
    let palette: M3Palette

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(
                        colors: stride(from: 0.0, through: 1.0, by: 0.05)
                            .map { Color(hue: $0, saturation: 0.62, brightness: 0.85) },
                        startPoint: .leading, endPoint: .trailing))
                    .frame(height: 14)

                Capsule()
                    .fill(palette.onSurface)
                    .frame(width: 5, height: 26)
                    .offset(x: min(max(width * hue - 2.5, 0), width - 5))
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { hue = min(max($0.location.x / width, 0), 1) }
            )
        }
    }
}
