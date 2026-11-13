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

    private static let titleKey = "ariaMenuBarShowsTitle"

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.key)
        }
    }
    /// The title item can be hidden, leaving only the 65pt transport row.
    @Published var showsTitle: Bool {
        didSet { UserDefaults.standard.set(showsTitle, forKey: Self.titleKey) }
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
        showsTitle = defaults.object(forKey: Self.titleKey) as? Bool ?? true
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

    /// Long titles are capped so the row stays a reasonable size.
    private static let maxTitleLength = 26
    private static let glyphSize: CGFloat = 17
    /// Both items keep a constant length, so macOS never reflows the status bar
    /// on a track change. The title's spare width sits at the transparent left
    /// edge of its own item, never between the name and the controls.
    private static let titleSlotWidth: CGFloat = 120
    /// The transport controls live in their own fixed-width status item, so a
    /// title change can never move them or make them overlap a neighbour.
    private static let controlWidth: CGFloat = 3 * (17 + 2) + 8   // 65

    /// Two independent items: the title may resize on a track change, the
    /// transport row never does.
    private var titleItem: NSStatusItem?
    private var controlItem: NSStatusItem?
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
        guard titleItem == nil, controlItem == nil else {
            refresh()
            return
        }
        // macOS places later items to the LEFT of earlier ones, so creating the
        // controls first puts the title immediately on their left.
        let controls = NSStatusBar.system.statusItem(withLength: Self.controlWidth)
        let title = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let controlButton = controls.button, let titleButton = title.button else { return }

        for button in [controlButton, titleButton] {
            button.title = ""
            button.image = nil
            // No `item.menu`: clicks are dispatched by position.
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        controlButton.action = #selector(controlClicked)
        titleButton.action = #selector(titleClicked)

        titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.drawsBackground = false
        titleLabel.isBordered = false
        titleLabel.usesSingleLineMode = true

        for view in [iconView, titleLabel] as [NSView] { titleButton.addSubview(view) }
        for glyph in [previousGlyph, playGlyph, nextGlyph] as [NSView] {
            controlButton.addSubview(glyph)
        }

        let menu = NSMenu()
        menu.delegate = self
        self.menu = menu
        self.titleItem = title
        self.controlItem = controls
        refresh()
    }

    private func uninstall() {
        if let titleItem { NSStatusBar.system.removeStatusItem(titleItem) }
        if let controlItem { NSStatusBar.system.removeStatusItem(controlItem) }
        titleItem = nil
        controlItem = nil
        menu = nil
    }

    /// Rebuilds the row and its width. Called on every track / play-state change
    /// and on install.
    private func refresh() {
        guard let titleItem, let controlItem,
              let titleButton = titleItem.button,
              let controlButton = controlItem.button else { return }
        let height = controlButton.bounds.height > 0 ? controlButton.bounds.height : 22
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

        // Title item: icon + name right-aligned inside a fixed slot.
        titleLabel.sizeToFit()
        let titleWidth = ceil(min(titleLabel.frame.width + 1,
                                  Self.titleSlotWidth - 30))
        let contentWidth: CGFloat = 5 + 14 + 5 + titleWidth + 6
        var x: CGFloat = Self.titleSlotWidth - contentWidth + 5
        iconView.frame = NSRect(x: x, y: (height - 14) / 2, width: 14, height: 14)
        x += 14 + 5
        titleLabel.frame = NSRect(x: x, y: (height - 17) / 2, width: titleWidth, height: 17)
        titleItem.length = Self.titleSlotWidth
        titleItem.isVisible = MenuBarSettings.shared.showsTitle

        // Control item: three glyphs in a slot whose width never changes.
        var cx: CGFloat = 4
        for glyph in [previousGlyph, playGlyph, nextGlyph] {
            glyph.frame = NSRect(x: cx, y: (height - Self.glyphSize) / 2,
                                 width: Self.glyphSize, height: Self.glyphSize)
            cx += Self.glyphSize + 2
        }
        controlItem.length = Self.controlWidth

        titleButton.toolTip = player?.current.map { "\($0.title) — \($0.artist)" } ?? L("Aria")
        controlButton.toolTip = L("Aria")
    }

    /// The colour the menu bar is using right now. Resolved inside the status
    /// bar's own appearance rather than the app's, so the row still matches when
    /// Aria forces a light or dark window of its own.
    private func menuBarTint() -> NSColor {
        guard let appearance = controlItem?.button?.effectiveAppearance else { return .labelColor }
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
        // A placeholder keeps the row identifiable before anything is playing.
        guard let track = player?.current else { return "Aria" }
        let name = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count > Self.maxTitleLength else { return name }
        return String(name.prefix(Self.maxTitleLength - 1)) + "…"
    }

    // MARK: Clicking

    /// Every click lands here — the row's parts let the event through — and is
    /// routed by where it fell.
    @objc private func controlClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu(from: controlItem)
            return
        }
        guard let button = controlItem?.button, let window = button.window else {
            showMenu(from: controlItem)
            return
        }
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let point = button.convert(inWindow, from: nil)
        if !handleClick(at: point) { showMenu(from: controlItem) }
    }

    /// Clicking the title (or right-clicking the controls) opens the full menu.
    @objc private func titleClicked() {
        showMenu(from: titleItem)
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

    private func showMenu(from item: NSStatusItem?) {
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

        let titleToggle = command(L("Show song title in menu bar"), "textformat",
                                  #selector(toggleTitleVisibility))
        titleToggle.state = MenuBarSettings.shared.showsTitle ? .on : .off
        menu.addItem(titleToggle)

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

    @objc private func toggleTitleVisibility() {
        MenuBarSettings.shared.showsTitle.toggle()
        refresh()
    }

    @objc private func showApp() {
        NSApp.activate(ignoringOtherApps: true)
        // The main window may have been closed entirely; go through the same
        // restore path as the Dock reopen event instead of assuming a live one.
        MacWindowBridge.shared.restore()
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
