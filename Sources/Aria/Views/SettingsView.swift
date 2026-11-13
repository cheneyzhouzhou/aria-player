import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

struct SettingsView: View {
    /// Supplied when hosted inside the main window; computed for the ⌘, window.
    var palette: M3Palette? = nil
    /// When the host already paints the shared page frost behind every tab
    /// (library, search, settings), the settings page must not paint a second
    /// one — otherwise it would be denser than its neighbours.
    var drawsBackdrop: Bool = true

    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var palettes: PaletteStore
    @EnvironmentObject var player: AudioPlayer
    @StateObject private var lang = LanguageSettings.shared
    @ObservedObject private var appearance = AppearanceSettings.shared
    #if os(macOS)
    @ObservedObject private var menuBar = MenuBarSettings.shared
    #else
    @ObservedObject private var mediaLibrary = MediaLibraryAccess.shared
    #endif
    @Environment(\.colorScheme) private var scheme

    /// A folder that was picked but holds no playable file. It is held here so the
    /// warning can say which one, instead of the folder quietly joining the
    /// list with "0 tracks" beside it.
    @State private var emptyFolder: PickedFolder?
    /// Set when the folder could not be opened at all. The distinction matters:
    /// "no music here" and "the system won't let me look" need different fixes.
    @State private var readProblem: String?

    /// iOS goes through the document picker; the Mac's own panel already
    /// returns a folder the app may read.
    private func addFolder() {
        #if os(iOS)
        FolderPicker.present(startingAt: library.pickerStartDirectory) { folder in
            add(folder)
        }
        #else
        Platform.chooseFolder(startingAt: library.rootPath) { path in
            addMacFolder(at: path)
        }
        #endif
    }

    #if os(macOS)
    private func addMacFolder(at path: String) {
        Task {
            await library.addSource(URL(fileURLWithPath: path))
            await library.scan()
        }
    }

    /// The Music app keeps its DRM-free local files under `Media.localized`.
    /// Starting the open panel there saves the user a trip through `~/Music` —
    /// and, more importantly, picking a folder through NSOpenPanel is what
    /// grants the TCC permission macOS requires before anything can read
    /// `~/Music`. Reading a hard-coded path instead would prompt (or be denied).
    private var musicAppMediaDirectory: String {
        let home = NSHomeDirectory()
        let fm = FileManager.default
        for suffix in ["/Music/Music/Media.localized", "/Music/Music", "/Music"] {
            let candidate = home + suffix
            if fm.fileExists(atPath: candidate) { return candidate }
        }
        return home
    }

    private func addMusicAppFolder() {
        Platform.chooseFolder(startingAt: musicAppMediaDirectory) { path in
            addMacFolder(at: path)
        }
    }
    #endif

    #if os(iOS)
    /// A folder is only worth adding if it can produce something to play, and
    /// "IPA" is a folder name that says nothing about where it lives. Counting
    /// first turns a silent 0-track row into a question that carries the path.
    private func add(_ folder: PickedFolder) {
        PickerLog.shared.note("adding \(folder.url.path)")
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> (Int, String?) in
                // Reading the directory first: a folder the app has no
                // permission for is not empty, it is unreadable, and only the
                // error says which.
                let problem = FolderScan.read(folder.url).problem
                return (FolderScan.count(under: folder.url), problem)
            }.value
            PickerLog.shared.note("found \(outcome.0) playable in it")
            if let problem = outcome.1 {
                PickerLog.shared.note("read failed: \(problem)")
                readProblem = problem
                emptyFolder = folder
            } else if outcome.0 == 0 {
                emptyFolder = folder
            } else {
                commit(folder)
            }
        }
    }

    private func commit(_ folder: PickedFolder) {
        if library.addPrepared(folder) {
            Task { await library.scan() }
        } else {
            PickerLog.shared.note("already in the list")
        }
    }

    #endif

    /// Horizontal inset of the page content. On iOS every tab already sits
    /// inside the shared glass panel (inset 10pt from the screen edge); the
    /// library and search lists add another `screenInset` (20pt) on top, so
    /// their content rests ~30pt in. The settings section cards must use the
    /// same extra inset, otherwise they hug the panel edge and read as wider
    /// / overflowing next to the other pages.
    private var contentInset: CGFloat {
        #if os(iOS)
        AppearanceSettings.shared.usesGlass ? screenInset + 10 : screenInset
        #else
        screenInset
        #endif
    }

    private var p: M3Palette {
        palette ?? themePalette(seed: palettes.librarySeed, isDark: scheme == .dark)
    }

    var body: some View {
        Group {
            if AppearanceSettings.shared.usesGlass {
                GeometryReader { geo in
                    page(glassWidth: geo.size.width)
                }
            } else {
                page(glassWidth: nil)
            }
        }
        #if os(iOS)
        .alert(readProblem == nil ? L("No music files in that folder") : L("Aria can't open that folder"),
               isPresented: Binding(get: { emptyFolder != nil },
                                    set: { if !$0 { emptyFolder = nil; readProblem = nil } })) {
            Button(L("Choose another")) { emptyFolder = nil; readProblem = nil; addFolder() }
            if readProblem == nil {
                Button(L("Add anyway")) {
                    if let folder = emptyFolder { commit(folder) }
                    emptyFolder = nil
                }
            }
            Button(L("Cancel"), role: .cancel) { emptyFolder = nil; readProblem = nil }
        } message: {
            if let problem = readProblem {
                Text("\(emptyFolder?.path ?? "")\n\n\(problem)\n\n" + L("iOS only lets an app read a folder it was handed permission for, and a SideStore-signed build sometimes never receives that permission. Copying the music into On My iPhone → Aria from the Files app and adding that folder here works around it."))
            } else {
                Text("\(emptyFolder?.path ?? "")\n\n" + L("Aria reads FLAC, ALAC, MP3, AAC, WAV or AIFF, so this folder would show up with nothing in it. The path above is what was picked — if your music lives somewhere else, pick that folder instead."))
            }
        }
        #endif
    }

    /// The page itself. `glassWidth` is the width the page was actually given,
    /// and only the glass theme passes one: a vertical `ScrollView` offers its
    /// content unlimited width, so the greedy section cards report a wider
    /// ideal size than the page — which pushed the frosted panel out to the
    /// screen edge and made the cards read wider than every other tab. Pinning
    /// the content to the available width fixes that. `nil` leaves the width
    /// unconstrained, which is what Solid and Morandi have always used.
    private func page(glassWidth: CGFloat?) -> some View {
        ZStack(alignment: .topLeading) {
            if drawsBackdrop { settingsBackdrop }
            ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(L("Settings"))
                    .font(.display(40, .semibold))
                    .foregroundStyle(p.onSurface)
                    .padding(.top, 40)
                section(L("Language")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("", selection: $lang.language) {
                            ForEach(AppLanguage.allCases) { language in
                                Text(language.displayName).tag(language)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 280)
                    }
                }

                section(L("Appearance")) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(L("Theme"))
                            .font(.body(13.5, .medium))
                            .foregroundStyle(p.onSurface)
                        themePicker

                        row(L("Light / dark"))
                        modePicker

                        if !appearance.usesMorandi {
                            row(L("Theme colour"), L("Tints the library. The player takes its colour from the artwork instead."))
                            HueBar(hue: $palettes.libraryHue, palette: p)
                                .frame(height: 30)
                            // Directly under the colour bar, before the swatch
                            // row: on a phone the bottom nav capsule floats
                            // over the page, and moving this any lower would
                            // leave the slider half hidden on the first screen.
                            if appearance.usesGlass {
                                row(L("Glass transparency"))
                                HStack(spacing: 12) {
                                    Slider(value: $appearance.glassTransparency, in: 0...1)
                                        .tint(p.primary)
                                    Text("\(Int(round(appearance.glassTransparency * 100)))%")
                                        .font(.label(11, .medium))
                                        .foregroundStyle(p.onSurfaceVariant)
                                        .frame(width: 38, alignment: .trailing)
                                }
                            }
                            swatches
                        } else {
                            row(L("Theme colour"), L("Pick one of the muted Morandi accents. The player still takes its colour from the artwork."))
                            morandiSwatches
                        }

                    }
                }

                #if os(macOS)
                section(L("Menu bar")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(isOn: $menuBar.isEnabled) {
                            Text(L("Show the song and controls in the menu bar"))
                                .font(.body(13, .medium))
                                .foregroundStyle(p.onSurface)
                        }
                        .toggleStyle(.switch)
                        .tint(p.primary)

                        Text(L("Aria keeps the current song in the system menu bar, with play, pause and track skipping one click away."))
                            .font(.body(11))
                            .foregroundStyle(p.onSurfaceVariant)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                #endif

                section(L("Music folders")) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(library.sources) { source in
                            HStack(spacing: 10) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(p.onSurfaceVariant)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(source.name)
                                        .font(.body(12.5))
                                        .foregroundStyle(p.onSurface)
                                        .lineLimit(1)
                                    Text(subtitle(for: source))
                                        .font(.body(10.5))
                                        .foregroundStyle(p.onSurfaceVariant)
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                }
                                Spacer(minLength: 8)
                                Button {
                                    library.removeSource(id: source.id)
                                    Task { await library.scan() }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .font(.system(size: 15))
                                        .foregroundStyle(p.onSurfaceVariant)
                                }
                                .buttonStyle(.plain)
                                .disabled(library.isScanning)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                            .background {
                                SurfaceRole.raised.background(p,
                                    shape: AnyShape(Capsule()), radius: 999)
                            }
                        }

                        #if os(iOS)
                        VStack(alignment: .leading, spacing: 7) {
                            Toggle(isOn: Binding(
                                get: { mediaLibrary.isEnabled },
                                set: { on in
                                    Task {
                                        // A song we are about to lose access to
                                        // must not keep playing from a stale URL.
                                        if !on, player.current?.isMediaLibraryItem == true {
                                            player.stop()
                                        }
                                        await mediaLibrary.setEnabled(on)
                                        await library.scan()
                                    }
                                })) {
                                Text(L("Apple Music library"))
                                    .font(.body(13, .medium))
                                    .foregroundStyle(p.onSurface)
                            }
                            .tint(p.primary)

                            Text(L("Add a custom folder or songs from Apple Music. DRM-protected songs will be skipped."))
                                .font(.body(11))
                                .foregroundStyle(p.onSurfaceVariant)
                                .fixedSize(horizontal: false, vertical: true)

                            if mediaLibrary.authorization == .denied
                                || mediaLibrary.authorization == .restricted {
                                Text(L("Media access denied. Enable Music in iOS Settings to use this."))
                                    .font(.body(11))
                                    .foregroundStyle(p.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else if mediaLibrary.isEnabled {
                                Text(String(format: L("%d playable · %d DRM-protected skipped"),
                                            mediaLibrary.tracks.count,
                                            mediaLibrary.skippedCount))
                                    .font(.body(11))
                                    .foregroundStyle(p.onSurfaceVariant)
                            }
                        }
                        .padding(.vertical, 4)
                        #endif

                        HStack(spacing: 10) {
                            Button(L("Add folder…")) { addFolder() }
                                .buttonStyle(PillButtonStyle(kind: .tonal, palette: p))
                                .disabled(library.isScanning)

                            #if os(macOS)
                            Button(L("Add Apple Music Library")) { addMusicAppFolder() }
                                .buttonStyle(PillButtonStyle(kind: .tonal, palette: p))
                                .disabled(library.isScanning)
                            #endif

                            if library.isScanning {
                                HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                    Text(L("Scanning…"))
                                        .font(.body(11))
                                        .foregroundStyle(p.onSurfaceVariant)
                                }
                            }
                        }

                        #if os(macOS)
                        Text(L("Add a custom folder or songs from Apple Music. DRM-protected songs will be skipped."))
                            .font(.body(10.5))
                            .foregroundStyle(p.onSurfaceVariant)
                            .fixedSize(horizontal: false, vertical: true)
                        #endif

                        // Which build is on this device: the file name and the
                        // bundle version are stamped from the same number.
                        Text(footer)
                            .font(.body(10.5))
                            .foregroundStyle(p.onSurfaceVariant)
                    }
                }

                #if os(iOS)
                section(L("Output")) {
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 10) {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(p.onSurfaceVariant)
                                Slider(value: $player.volume, in: 0...1)
                                    .tint(p.primary)
                                Text(volumeText)
                                    .font(.body(11))
                                    .monospacedDigit()
                                    .foregroundStyle(p.onSurfaceVariant)
                                    .frame(width: 50, alignment: .trailing)
                            }
                            Text(L("Volume inside Aria, on top of the system volume — down to −50 dB when iOS's lowest step is still too loud."))
                                .font(.body(11))
                                .foregroundStyle(p.onSurfaceVariant)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        row(L("Playing through"), player.outputDescription)
                        if player.outputIsLossy {
                            Text(L("Bluetooth re-encodes audio before it reaches your headphones, so lossless files stop being lossless at that point. Wired headphones or a USB-C DAC keep the full quality."))
                                .font(.body(11))
                                .foregroundStyle(p.onSurfaceVariant)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(L("Aria tells the hardware to run at the music file's own sample rate."))
                                .font(.body(11))
                                .foregroundStyle(p.onSurfaceVariant)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                #endif

                #if os(macOS)
                section(L("Output")) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Text(L("Capabilities detected on each device"))
                                .font(.body(11.5))
                                .foregroundStyle(p.onSurfaceVariant)
                            Spacer()
                            Button { player.refreshOutputDevices() } label: {
                                Label(L("Refresh"), systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(PillButtonStyle(kind: .tonal, palette: p))
                        }
                        .padding(.bottom, 2)

                        ForEach(player.outputDevices) { device in
                            outputDeviceRow(device)
                        }

                        if player.outputDevices.isEmpty {
                            Text(L("No output devices found."))
                                .font(.body(12))
                                .foregroundStyle(p.onSurfaceVariant)
                        }
                    }
                }

                section(L("Output mode")) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(OutputMode.allCases, id: \.self) { mode in
                                outputModeCard(mode)
                            }
                        }

                        Text(player.exclusiveStatus)
                            .font(.body(11.5, .medium))
                            .foregroundStyle(player.outputMode == .exclusive
                                ? (player.exclusiveHogGranted
                                   ? p.primary
                                   : Color(red: 0.99, green: 0.68, blue: 0.29))
                                : p.onSurfaceVariant)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(L("Exclusive mode changes the device's clock rate for the whole system and mutes other apps using it. Aria releases the device when you switch back to Shared or quit. If the device refuses the rate or exclusive access, playback falls back to Shared automatically."))
                            .font(.body(11))
                            .foregroundStyle(p.onSurfaceVariant)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                #endif

                section(L("Library")) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 12) {
                            stat(Lplural(library.tracks.count, "song"))
                            stat(Lplural(library.albums.count, "album"))
                            stat(Lduration(library.totalDuration))
                        }

                        row(L("Last scanned"), lastScanText)

                        HStack(spacing: 12) {
                            Button {
                                Task { await library.scan() }
                            } label: {
                                Label(L("Rescan library"), systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(PillButtonStyle(kind: .filled, palette: p))
                            .disabled(library.isScanning)

                            if library.isScanning {
                                ProgressView().controlSize(.small).scaleEffect(0.75)
                                Text(L("Scanning…"))
                                    .font(.body(12))
                                    .foregroundStyle(p.onSurfaceVariant)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, contentInset)
            .padding(.bottom, playerClearance)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(width: glassWidth, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        }
    }


    /// Full-bleed page backdrop. In the glass theme this is one continuous
    /// frosted pane reaching the very top and bottom edges — so iOS no longer
    /// shows two differently-coloured bands above and below it, and macOS no
    /// longer leaves a coloured strip under the title bar. In the solid theme
    /// it is the flat surface.
    @ViewBuilder
    private var settingsBackdrop: some View {
        Group {
            if AppearanceSettings.shared.usesGlass {
                GlassSurface(shape: Rectangle(), tint: p.surfaceContainer,
                             border: p.outline, radius: 0, showBorder: false)
            } else {
                p.surface
            }
        }
        .ignoresSafeArea(edges: [.top, .bottom])
    }

    // MARK: Pieces

    #if os(macOS)
    private func outputDeviceRow(_ device: AudioOutputDevice) -> some View {
        // Once the HAL unit has bound to a device we mirror that reality; before
        // playback starts (no unit yet) we fall back to the user's selection so
        // the expected device is still highlighted. Either way the highlight can
        // never claim a device the sound isn't actually leaving through.
        let inUse = player.actualOutputUID == device.uid
            || (player.actualOutputUID == nil
                && (player.selectedOutputUID == device.uid
                    || (player.selectedOutputUID == nil && device.isDefault)))
        return Button {
            player.selectOutputDevice(uid: device.uid)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: inUse ? "smallcircle.filled.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(inUse ? p.primary : p.onSurfaceVariant)
                    .frame(width: 18)

                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(p.surfaceContainerHigh)
                        .frame(width: 32, height: 32)
                    Image(systemName: device.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(p.onSurface)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(device.name)
                            .font(.body(13.5, .semibold))
                            .foregroundStyle(p.onSurface)
                            .lineLimit(1)
                        if inUse {
                            Text(L("In use"))
                                .font(.body(10, .semibold))
                                .foregroundStyle(p.primary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(p.primary.opacity(0.16)))
                        }
                    }
                    HStack(spacing: 6) {
                        capabilityChip(L(device.capability), color: device.capabilityColor)
                        capabilityChip(device.rateText, color: p.onSurfaceVariant)
                        capabilityChip(device.bitText, color: p.onSurfaceVariant)
                        capabilityChip(device.channelText, color: p.onSurfaceVariant)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(11)
            .background {
                SurfaceRole.raised.background(p,
                    shape: AnyShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)),
                    radius: Radius.card,
                    override: inUse ? p.primaryContainer.opacity(0.28) : nil)
            }
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .stroke(inUse ? p.primary.opacity(0.75) : p.outline.opacity(0.25),
                            lineWidth: inUse ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func capabilityChip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.body(10, .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .overlay(Capsule().stroke(color.opacity(0.45), lineWidth: 0.8))
    }

    private func outputModeCard(_ mode: OutputMode) -> some View {
        let selected = player.outputMode == mode
        return Button {
            player.setOutputMode(mode)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(L(mode.title))
                        .font(.display(14.5, .semibold))
                        .foregroundStyle(p.onSurface)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(selected ? p.primary : p.onSurfaceVariant.opacity(0.6))
                }
                Text(L(mode.detail))
                    .font(.body(11.5))
                    .foregroundStyle(p.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(13)
            .frame(maxWidth: .infinity, minHeight: 122, alignment: .topLeading)
            .background {
                SurfaceRole.raised.background(p,
                    shape: AnyShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)),
                    radius: Radius.card)
            }
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .stroke(selected ? p.primary : p.outline.opacity(0.3),
                            lineWidth: selected ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    #endif

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
                .background {
                    // A floating glass card per section, sitting on the page
                    // container — the segmented, elevated look of the reference.
                    SurfaceRole.panel.background(p,
                        shape: AnyShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)),
                        radius: Radius.card)
                }
        }
    }

    /// Title-only row for settings whose behaviour is self-explanatory; the
    /// detail line was deliberately dropped (both languages) to keep the page
    /// compact.
    private func row(_ title: String) -> some View {
        Text(title)
            .font(.body(13.5, .medium))
            .foregroundStyle(p.onSurface)
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
            // Three of these share one row; without a single-line cap the
            // longest one ("260 首歌曲") wraps inside its capsule.
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .foregroundStyle(p.onPrimaryContainer)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            // `minimumScaleFactor` shrinks the glyphs *and* the line height, so
            // the longest capsule ended up ~3pt shorter than its neighbours.
            // A fixed height keeps all three exactly the same pill.
            .frame(height: 28)
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
                        .fill(Color(hue: hue,
                                    saturation: p.isDark ? 0.58 : 0.62,
                                    brightness: p.isDark ? 0.55 : 0.85))
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

    /// Two tap-to-select cards — the appearance module's theme switch.
    private var themePicker: some View {
        HStack(spacing: 12) {
            ForEach(AppearanceTheme.allCases) { theme in
                ThemeOptionCard(theme: theme,
                                isSelected: appearance.theme == theme,
                                palette: p) {
                    withAnimation(.easeInOut(duration: 0.3)) { appearance.set(theme) }
                }
            }
        }
    }

    /// Preset Morandi accents — twelve dusty hues in two rows: clay, rose,
    /// oat, mustard, olive, sage on top; celadon, steel, blue, indigo, mauve
    /// and violet below. The palette desaturates each one further.
    private var morandiSwatches: some View {
        VStack(alignment: .leading, spacing: 10) {
            morandiRow([0.02, 0.05, 0.09, 0.13, 0.20, 0.28])
            morandiRow([0.42, 0.50, 0.58, 0.66, 0.78, 0.87])
        }
    }

    private func morandiRow(_ hues: [Double]) -> some View {
        HStack(spacing: 10) {
            ForEach(hues, id: \.self) { hue in
                Button {
                    withAnimation(.easeInOut(duration: 0.4)) { appearance.morandiHue = hue }
                } label: {
                    Circle()
                        .fill(Color(hue: hue, saturation: 0.30,
                                    brightness: scheme == .dark ? 0.55 : 0.82))
                        .frame(width: 26, height: 26)
                        .overlay {
                            Circle().strokeBorder(
                                p.onSurface.opacity(abs(appearance.morandiHue - hue) < 0.01 ? 0.9 : 0),
                                lineWidth: 2.5)
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Follow-system / light / dark, as a compact segmented control.
    /// Follow-system / light / dark, as three plain buttons. A segmented
    /// `Picker` on macOS is an AppKit bridge, and flipping the whole window's
    /// colour scheme inside its action could swallow the first click — plain
    /// buttons always fire.
    private var modePicker: some View {
        HStack(spacing: 8) {
            ForEach(AppearanceMode.allCases) { mode in
                let selected = appearance.mode == mode
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) { appearance.setMode(mode) }
                } label: {
                    Text(mode.title)
                        .font(.body(12.5, selected ? .semibold : .regular))
                        .foregroundStyle(selected ? p.onSurface : p.onSurfaceVariant)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background {
                            Capsule().fill(selected
                                           ? p.primary.opacity(0.22)
                                           : p.surfaceContainerHigh.opacity(0.65))
                        }
                        .overlay {
                            Capsule().stroke(selected ? p.primary : p.outline.opacity(0.3),
                                             lineWidth: selected ? 1.5 : 1)
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// A selectable preview card for one appearance theme. The glass card renders a
    /// real frosted mock so the choice is self-explanatory; the solid card shows a
    /// flat swatch. The selected card is outlined in the accent colour.
    private struct ThemeOptionCard: View {
    let theme: AppearanceTheme
    let isSelected: Bool
    let palette: M3Palette
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    if theme.isGlass {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(gradient)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(.white.opacity(scheme == .dark ? 0.14 : 0.28))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.white.opacity(0.45), lineWidth: 1)
                            )
                    } else if theme.isMorandi {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(morandiSwatch)
                    } else {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(flat)
                    }

                    // Mock content lines so the two previews read as "a panel".
                    // In the glass theme these are allowed to shorten: three
                    // cards sit side by side, and a hard 56pt line made each
                    // card refuse to shrink below ~104pt, so the row overflowed
                    // the page and pushed it wider than the frosted panel.
                    // Solid and Morandi keep the fixed line, untouched.
                    VStack(alignment: .leading, spacing: 5) {
                        mockLine(opacity: 0.55, width: 56)
                        mockLine(opacity: 0.32, width: 36)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
                .frame(height: 72)
                // The tick sits on the preview instead of beside the name:
                // three cards share ~87pt each, and an inline icon left only
                // ~43pt for the title — enough to break "Frosted glass" into
                // one letter per line. On the artwork it costs no width.
                .overlay(alignment: .topTrailing) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.55))
                        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                        .padding(7)
                }

                Text(theme.title)
                    .font(.body(12.5, .semibold))
                    .foregroundStyle(palette.onSurface)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(isSelected ? palette.primary.opacity(0.14) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .stroke(isSelected ? palette.primary : palette.outline.opacity(0.3),
                            lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func mockLine(opacity: Double, width: CGFloat) -> some View {
        let line = Capsule().fill(Color.white.opacity(opacity))
        return Group {
            if AppearanceSettings.shared.usesGlass {
                line.frame(maxWidth: width, maxHeight: 7)
            } else {
                line.frame(width: width, height: 7)
            }
        }
    }

    private var gradient: LinearGradient {
        LinearGradient(colors: [
            Color(hue: 0.60, saturation: 0.55, brightness: scheme == .dark ? 0.45 : 0.85),
            Color(hue: 0.75, saturation: 0.50, brightness: scheme == .dark ? 0.30 : 0.70)
        ], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var flat: Color {
        Color(hue: 0.62, saturation: 0.22, brightness: scheme == .dark ? 0.30 : 0.95)
    }

    /// The Morandi preview: the theme's default dusty sage accent on a greige
    /// panel — what the theme actually lands on.
    private var morandiSwatch: Color {
        Color(hue: 0.28, saturation: 0.13, brightness: scheme == .dark ? 0.52 : 0.80)
    }
}

    /// Shortens a folder path for display: the app container becomes "~", and
    /// an iCloud Drive folder loses the long provider prefix.
    /// Build number and library counts, so a screenshot says which build is
    /// running without anyone having to dig through iOS Settings.
    /// The attenuation in decibels, which is the number that answers "how much
    /// quieter than the system's own lowest step is this".
    private var volumeText: String {
        guard player.volume > 0.0001 else { return L("mute") }
        return "\(Int(AudioPlayer.decibels(for: player.volume).rounded())) dB"
    }

    private var footer: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
        let folders = library.sources.count
        let tracks = library.tracks.count
        return "Aria v\(version) · " + Lplural(folders, "folder") + " · " + Lplural(tracks, "track")
    }

    private func shortPath(_ path: String) -> String {
        // NSHomeDirectory works on both platforms: the app container on iOS.
        let home = NSHomeDirectory()
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        if let range = path.range(of: "/Mobile Documents/com~apple~CloudDocs") {
            return "iCloud Drive" + path[range.upperBound...]
        }
        return path
    }

    /// Path plus the count that proves the folder is being read. A folder that
    /// gained access but held no playable files shows "0 tracks" instead of
    /// nothing.
    private func subtitle(for source: LibrarySource) -> String {
        let count = library.trackCount(in: source)
        let path = shortPath(source.path)
        guard count > 0 else { return "\(path) · " + L("no music here") }
        return "\(path) · " + Lplural(count, "track")
    }

    private var lastScanText: String {
        guard let date = library.lastScan else { return L("Never") }
        // The relative formatter renders a fresh scan as "in 0 seconds".
        guard Date().timeIntervalSince(date) > 10 else { return L("Just now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.locale = LanguageSettings.shared.language.locale
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// Full-spectrum hue picker drawn as a Material track with a pill handle.
struct HueBar: View {
    @Binding var hue: Double
    let palette: M3Palette

    private func value(at x: CGFloat, width: CGFloat) -> Double {
        Double(min(max(x / max(width, 1), 0), 1))
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(
                        colors: stride(from: 0.0, through: 1.0, by: 0.05)
                            .map { Color(hue: $0,
                                         saturation: palette.isDark ? 0.58 : 0.62,
                                         brightness: palette.isDark ? 0.55 : 0.85) },
                        startPoint: .leading, endPoint: .trailing))
                    .frame(height: 14)

                Capsule()
                    .fill(palette.onSurface)
                    .frame(width: 5, height: 26)
                    .offset(x: min(max(width * hue - 2.5, 0), width - 5))
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
#if os(iOS)
            // The old gesture was exclusive and started on touch-down
            // (`minimumDistance: 0`), so a thumb resting here while the page
            // was scrolled both fought the scroll *and* re-coloured the app to
            // whatever x it happened to land on.
            //
            // Two changes, both deliberate:
            //  • `simultaneousGesture` instead of `gesture`. An exclusive drag
            //    makes the scroll view wait for it to fail, so simply requiring
            //    a longer drag produces a dead patch where the page neither
            //    scrolls nor changes colour. Parallel recognition keeps the
            //    page's pan gesture alive.
            //  • A direction lock. The volume slider feels safe because only a
            //    deliberate horizontal intent changes its value; the same rule
            //    here leaves every vertical swipe to the page. `dy < 20` also
            //    stops a drag that starts sideways and then turns into a scroll
            //    from leaving a stray colour behind. It is stateless on purpose:
            //    a latched "this is a scroll" flag can survive a cancelled
            //    gesture and swallow the next real drag.
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { drag in
                        let dx = abs(drag.translation.width)
                        let dy = abs(drag.translation.height)
                        guard dx > 12, dx > dy * 1.5, dy < 20 else { return }
                        hue = value(at: drag.location.x, width: width)
                    }
            )
            // A plain tap still jumps the handle to that colour, so picking a
            // hue never requires a drag — the same way a tap on the volume
            // slider's track sets its value while a swipe through it does not.
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { tap in hue = value(at: tap.location.x, width: width) }
            )
#else
            // macOS: a mouse press is always intentional and there is no pan
            // gesture to steal, so keep the original press-and-track behaviour.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in hue = value(at: drag.location.x, width: width) }
            )
#endif
        }
    }
}
