#if os(macOS)
import AppKit
import Combine

/// Whether the player also lives in the system menu bar. A singleton so the
/// main window and the ⌘, settings window flip the same switch.
///
/// Kept out of `AppearanceSettings`: this is a macOS-only convenience, and the
/// phone simply never reads it.
final class MenuBarSettings: ObservableObject {
    static let shared = MenuBarSettings()
    private static let key = "ariaMenuBarPlayer"

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.key)
        }
    }

    init() {
        let defaults = UserDefaults.standard
        // On by default: the point of the feature is that it is already there.
        // Anyone who dislikes it turns it off once, and that choice sticks.
        if defaults.object(forKey: Self.key) == nil {
            isEnabled = true
            defaults.set(true, forKey: Self.key)
        } else {
            isEnabled = defaults.bool(forKey: Self.key)
        }
    }
}

/// The status-bar player: the item shows the song title and three live controls
/// (previous / play-pause / next); clicking the title opens the full menu.
///
/// Built on `NSStatusItem` rather than SwiftUI's `MenuBarExtra`, which offers a
/// single click target. The row is drawn by hand and clicks are dispatched by
/// position, because `NSStatusBarButton` swallows mouse events before they reach
/// subviews — an earlier version with real `NSButton` subviews opened the menu
/// no matter which control was clicked.
@MainActor
final class MenuBarPlayer: NSObject, NSMenuDelegate {
    static let shared = MenuBarPlayer()

    /// Long titles would push every other status item aside.
    private static let maxTitleLength = 26
    private static let maxTitleWidth: CGFloat = 170
    private static let glyphSize: CGFloat = 17

    private var item: NSStatusItem?
    private var menu: NSMenu?
    private var player: AudioPlayer?
    private var subs = Set<AnyCancellable>()

    private let iconView = PassthroughImageView()
    private let titleLabel = PassthroughLabel(labelWithString: "")
    private let previousGlyph = ControlGlyph()
    private let playGlyph = ControlGlyph()
    private let nextGlyph = ControlGlyph()

    /// Wired once from the app entry point, after the player exists.
    func attach(to player: AudioPlayer) {
        guard self.player !== player else {
            refresh()
            return
        }
        self.player = player
        subs.removeAll()

        // Delivered on the main run loop, where this class already lives.
        player.$current
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
            .store(in: &subs)
        player.$isPlaying
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
            .store(in: &subs)

        MenuBarSettings.shared.$isEnabled
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                MainActor.assumeIsolated { self?.setVisible(enabled) }
            }
            .store(in: &subs)

        setVisible(MenuBarSettings.shared.isEnabled)
    }

    // MARK: Status item

    private func setVisible(_ visible: Bool) {
        if visible {
            install()
        } else {
            uninstall()
        }
    }

    private func install() {
        guard item == nil else {
            refresh()
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }

        button.title = ""
        button.image = nil
        // No `item.menu`: every click is routed by `statusButtonClicked`, which
        // decides between a transport action and opening the menu.
        button.target = self
        button.action = #selector(statusButtonClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.drawsBackground = false
        titleLabel.isBordered = false
        titleLabel.usesSingleLineMode = true

        for view in [iconView, titleLabel, previousGlyph, playGlyph, nextGlyph] as [NSView] {
            button.addSubview(view)
        }

        let menu = NSMenu()
        menu.delegate = self
        self.menu = menu
        self.item = item
        refresh()
    }

    private func uninstall() {
        if let item {
            NSStatusBar.system.removeStatusItem(item)
        }
        item = nil
        menu = nil
    }

    /// Rebuilds the row and its width. Called on every track / play-state change
    /// and on install.
    private func refresh() {
        guard let item, let button = item.button else { return }
        let height = button.bounds.height > 0 ? button.bounds.height : 22
        let playing = player?.isPlaying == true
        let hasTrack = player?.current != nil
        let tint = menuBarTint()

        iconView.image = symbol("music.note")
        iconView.contentTintColor = tint

        titleLabel.stringValue = statusTitle()
        titleLabel.textColor = tint.withAlphaComponent(playing ? 1 : 0.62)
        titleLabel.alignment = .left

        previousGlyph.image = symbol("backward.fill")
        playGlyph.image = symbol(playing ? "pause.fill" : "play.fill")
        nextGlyph.image = symbol("forward.fill")
        for glyph in [previousGlyph, playGlyph, nextGlyph] {
            glyph.contentTintColor = tint.withAlphaComponent(hasTrack ? 1 : 0.35)
        }

        var x: CGFloat = 5
        iconView.frame = NSRect(x: x, y: (height - 14) / 2, width: 14, height: 14)
        x += 14 + 5

        // Measure the rendered string, not the cell's ideal width: the cell's
        // padding made the label truncate a title that still had room.
        titleLabel.sizeToFit()
        let titleWidth = min(titleLabel.frame.width + 1, Self.maxTitleWidth)
        titleLabel.frame = NSRect(x: x, y: (height - 17) / 2, width: titleWidth, height: 17)
        x += titleWidth + 6

        for glyph in [previousGlyph, playGlyph, nextGlyph] {
            glyph.frame = NSRect(x: x, y: (height - Self.glyphSize) / 2,
                                 width: Self.glyphSize, height: Self.glyphSize)
            x += Self.glyphSize + 2
        }
        x += 4

        item.length = ceil(x)
        button.toolTip = player?.current.map { "\($0.title) — \($0.artist)" } ?? L("Aria")
    }

    /// The colour the menu bar is using right now. Resolved inside the status
    /// bar's own appearance rather than the app's, so the row still matches when
    /// Aria forces a light or dark window of its own.
    private func menuBarTint() -> NSColor {
        guard let appearance = item?.button?.effectiveAppearance else { return .labelColor }
        var tint = NSColor.labelColor
        appearance.performAsCurrentDrawingAppearance {
            tint = NSColor.labelColor
        }
        return tint
    }

    private func symbol(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    private func statusTitle() -> String {
        guard let track = player?.current else { return "" }
        let name = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count > Self.maxTitleLength else { return name }
        return String(name.prefix(Self.maxTitleLength - 1)) + "…"
    }

    // MARK: Clicking

    /// Every click lands here — the row's parts let the event through — and is
    /// routed by where it fell.
    @objc private func statusButtonClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
            return
        }
        guard let button = item?.button, let window = button.window else {
            showMenu()
            return
        }
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let point = button.convert(inWindow, from: nil)

        if !handleClick(at: point) {
            showMenu()
        }
    }

    /// Returns true when the point hit one of the three controls.
    @discardableResult
    private func handleClick(at point: NSPoint) -> Bool {
        guard player?.current != nil else { return false }
        if previousGlyph.frame.contains(point) {
            previousTrack()
            previousGlyph.flash()
            return true
        }
        if playGlyph.frame.contains(point) {
            togglePlayPause()
            playGlyph.flash()
            return true
        }
        if nextGlyph.frame.contains(point) {
            nextTrack()
            nextGlyph.flash()
            return true
        }
        return false
    }

    @objc private func showMenu() {
        guard let item, let menu, let button = item.button else { return }
        menuNeedsUpdate(menu)
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.height + 4),
                   in: button)
    }

    // MARK: Menu

    /// Rebuilt each time it opens: the play/pause wording, the shuffle tick and
    /// the repeat label are all read fresh, so the menu can never go stale.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let track = player?.current {
            let header = NSMenuItem()
            header.attributedTitle = nowPlayingTitle(track)
            header.isEnabled = false
            menu.addItem(header)
        } else {
            let header = NSMenuItem(title: L("Nothing playing"), action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
        }

        menu.addItem(.separator())

        menu.addItem(command(L("Previous Track"), "backward.fill", #selector(previousTrack)))
        menu.addItem(command(player?.isPlaying == true ? L("Pause") : L("Play"),
                             player?.isPlaying == true ? "pause.fill" : "play.fill",
                             #selector(togglePlayPause)))
        menu.addItem(command(L("Next Track"), "forward.fill", #selector(nextTrack)))

        menu.addItem(.separator())

        let shuffle = command(L("Shuffle"), "shuffle", #selector(toggleShuffle))
        shuffle.state = player?.isShuffled == true ? .on : .off
        menu.addItem(shuffle)

        let repeatItem = command(repeatTitle(), "repeat", #selector(cycleRepeat))
        if let mode = player?.repeatMode, mode != .off { repeatItem.state = .on }
        menu.addItem(repeatItem)

        menu.addItem(.separator())

        menu.addItem(command(L("Show Aria"), "macwindow", #selector(showApp)))
        menu.addItem(command(L("Quit Aria"), "power", #selector(quitApp)))
    }

    private func nowPlayingTitle(_ track: Track) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: track.title,
            attributes: [.font: NSFont.menuFont(ofSize: 13),
                         .foregroundColor: NSColor.labelColor]
        )
        let detail = [track.artist, track.album]
            .filter { !$0.isEmpty && $0 != "Unknown Artist" }
            .joined(separator: " · ")
        if !detail.isEmpty {
            text.append(NSAttributedString(
                string: "  " + detail,
                attributes: [.font: NSFont.menuFont(ofSize: 11),
                             .foregroundColor: NSColor.secondaryLabelColor]
            ))
        }
        return text
    }

    private func repeatTitle() -> String {
        switch player?.repeatMode ?? .off {
        case .off: return L("Repeat")
        case .all: return "\(L("Repeat")) — \(L("All"))"
        case .one: return "\(L("Repeat")) — \(L("One"))"
        }
    }

    private func command(_ title: String, _ symbol: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    // MARK: Actions

    @objc private func togglePlayPause() {
        player?.togglePlayPause()
        refresh()
    }

    @objc private func nextTrack() {
        player?.next()
        refresh()
    }

    @objc private func previousTrack() {
        player?.previous()
        refresh()
    }

    @objc private func toggleShuffle() {
        player?.isShuffled.toggle()
    }

    @objc private func cycleRepeat() {
        guard let player else { return }
        switch player.repeatMode {
        case .off: player.repeatMode = .all
        case .all: player.repeatMode = .one
        case .one: player.repeatMode = .off
        }
    }

    @objc private func showApp() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain && !($0 is NSPanel) }?
            .makeKeyAndOrderFront(nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

/// Parts of the row must not steal clicks: anything that is not a control has to
/// fall through to the status button, which routes the event.
private final class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class PassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A transport glyph. Non-interactive by design — the status button dispatches
/// the click — but it flashes when used so the press is acknowledged.
private final class ControlGlyph: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        imageScaling = .scaleProportionallyDown
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func flash() {
        alphaValue = 0.35
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.alphaValue = 1
        }
    }
}
#endif
