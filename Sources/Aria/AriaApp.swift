import SwiftUI

@main
struct AriaApp: App {
    @StateObject private var library = LibraryStore()
    @StateObject private var player = AudioPlayer()
    @StateObject private var palettes = PaletteStore()
    @StateObject private var playlists = PlaylistStore()
    private let nowPlaying = NowPlayingController()

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
            .frame(minWidth: 1000, minHeight: 660)
            .task {
                nowPlaying.attach(to: player)
                await library.scan()
            }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            root
        }
        #if os(macOS)
        // The app draws its own header, so the system title bar gets out of the way.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1160, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandMenu("Playback") {
                Button(player.isPlaying ? "Pause" : "Play") { player.togglePlayPause() }
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(player.current == nil)
                Button("Next Track") { player.next() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Previous Track") { player.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Divider()
                Button("Skip Forward 15s") { player.skip(by: 15) }
                    .keyboardShortcut("]", modifiers: .command)
                Button("Skip Back 15s") { player.skip(by: -15) }
                    .keyboardShortcut("[", modifiers: .command)
                Divider()
                Toggle("Shuffle", isOn: $player.isShuffled)
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Picker("Repeat", selection: $player.repeatMode) {
                    Text("Off").tag(RepeatMode.off)
                    Text("All").tag(RepeatMode.all)
                    Text("One").tag(RepeatMode.one)
                }
            }

            CommandGroup(after: .sidebar) {
                Button("Rescan Library") {
                    Task { await library.scan() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(library)
                .environmentObject(palettes)
            .environmentObject(playlists)
                .environmentObject(player)
                .frame(width: 560, height: 620)
        }
        #endif
    }
}
