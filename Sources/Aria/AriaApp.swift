import SwiftUI

#if os(macOS)
import AppKit
#endif

@main
struct AriaApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    #endif
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
            // Give the app delegate SwiftUI's `openWindow` action so a closed
            // main window can be recreated (see MacWindowBridge below).
            .background { MacWindowBridgeRegistrar() }
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
        WindowGroup(id: "main") {
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

#if os(macOS)
/// Keeping the menu-bar player alive means the process survives its last
/// window being closed — playback continues, which is what we want. The flip
/// side is that SwiftUI no longer has a window to reactivate: clicking the Dock
/// icon (or "Show All Windows") sends a reopen event that nobody handled,
/// leaving Aria running but invisible. These two hooks close that gap.
private final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MacWindowBridge.shared.restore() }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
}

/// Shared by the app delegate and the menu-bar player's "Show Aria" item.
final class MacWindowBridge {
    static let shared = MacWindowBridge()
    private init() {}
    /// Supplied by the window content once SwiftUI's `openWindow` is available.
    var reopen: (() -> Void)?

    func restore() {
        // A closed-but-retained window only needs ordering back in.
        if let window = NSApp.windows.first(where: {
            $0.canBecomeMain && !($0 is NSPanel)
        }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // SwiftUI released it entirely: ask the scene for a fresh one.
            reopen?()
        }
    }
}

private struct MacWindowBridgeRegistrar: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onAppear {
                MacWindowBridge.shared.reopen = { openWindow(id: "main") }
            }
    }
}
#endif
