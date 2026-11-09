import SwiftUI

@main
struct AriaApp: App {
    @StateObject private var library = LibraryStore()
    @StateObject private var player = AudioPlayer()
    @StateObject private var palettes = PaletteStore()
    @StateObject private var playlists = PlaylistStore()
    @StateObject private var lang = LanguageSettings.shared
    @StateObject private var appearance = AppearanceSettings.shared
    private let nowPlaying = NowPlayingController()
    /// The library scan and system wiring run once per app launch; later runs
    /// of the bootstrap task skip the scan.
    @State private var didBootstrap = false

    /// Shared setup for both platforms: wire up the system now-playing bridge,
    /// then reconcile the cached library with what's actually on disk.
    @ViewBuilder
    private var root: some View {
        #if os(iOS)
        PhoneRootView()
            .environmentObject(library)
            .environmentObject(player)
            .environmentObject(palettes)
            .environmentObject(playlists)
            .environment(\.locale, lang.language.locale)
            .id(lang.language)
            .task {
                nowPlaying.attach(to: player)
                await library.scan()
            }
        #else
        RootView()
            .environmentObject(library)
            .environmentObject(player)
            .environmentObject(palettes)
            .environmentObject(playlists)
            .environment(\.locale, lang.language.locale)
            .id(lang.language)
            .frame(minWidth: 1000, minHeight: 660)
            .task {
                nowPlaying.attach(to: player)
                // The menu-bar player: attach() installs the status item when
                // the setting is on (the default) and follows it afterwards.
                MenuBarPlayer.shared.attach(to: player)

                await library.scan()
            }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            AppearanceGate {
                root
            }
        }
        #if os(macOS)
        // The app draws its own header, so the system title bar gets out of the way.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1160, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandMenu(L("Playback")) {
                Button(player.isPlaying ? L("Pause") : L("Play")) { player.togglePlayPause() }
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(player.current == nil)
                Button(L("Next Track")) { player.next() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button(L("Previous Track")) { player.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Divider()
                Button(L("Skip Forward 15s")) { player.skip(by: 15) }
                    .keyboardShortcut("]", modifiers: .command)
                Button(L("Skip Back 15s")) { player.skip(by: -15) }
                    .keyboardShortcut("[", modifiers: .command)
                Divider()
                Toggle(L("Shuffle"), isOn: $player.isShuffled)
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Picker(L("Repeat"), selection: $player.repeatMode) {
                    Text(L("Off")).tag(RepeatMode.off)
                    Text(L("All")).tag(RepeatMode.all)
                    Text(L("One")).tag(RepeatMode.one)
                }
            }

            CommandGroup(after: .sidebar) {
                Button(L("Rescan Library")) {
                    Task { await library.scan() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        #endif

        #if os(macOS)
        Settings {
            AppearanceGate {
                SettingsView()
                .environmentObject(library)
                .environmentObject(palettes)
                .environmentObject(playlists)
                .environmentObject(player)
                .environment(\.locale, lang.language.locale)
                .id(lang.language)
                .frame(width: 560, height: 620)
            }
        }
        #endif
    }
}
