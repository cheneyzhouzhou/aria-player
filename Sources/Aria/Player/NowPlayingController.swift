import MediaPlayer
#if os(iOS)
import UIKit
#endif

/// Bridges the player to the system: media keys, Control Center, the lock
/// screen and the Now Playing widget all talk to `MPRemoteCommandCenter` /
/// `MPNowPlayingInfoCenter`.
@MainActor
final class NowPlayingController {
    private weak var player: AudioPlayer?

    /// Remote-command handlers currently installed.
    ///
    /// Registering the same command twice makes the system call *every*
    /// handler, so a play/pause from the lock screen would toggle twice and
    /// change nothing — the app and the lock screen then drift apart. A
    /// second `attach` therefore takes the old handlers out first.
    private var commandTargets: [(MPRemoteCommand, Any)] = []

    /// The artwork the system already has, kept so a later update that no
    /// longer finds the image in the cache does not drop it from the lock
    /// screen: every push replaces the whole dictionary.
    private var publishedArtKey: String?
    private var publishedArt: PlatformImage?

    /// Album whose artwork is being decoded right now.
    private var pendingArtKey: String?

    /// Keeps the elapsed time — and the artwork, once it lands — fresh while
    /// the music plays. The system extrapolates the position from the rate
    /// between pushes, but it only re-reads the artwork on a push.
    private var refreshTimer: Timer?

    func attach(to player: AudioPlayer) {
        self.player = player
        player.nowPlaying = self
        installCommands()
        startRefreshTimer()

        #if os(iOS)
        // Without this the lock screen's buttons are decorative.
        UIApplication.shared.beginReceivingRemoteControlEvents()
        #endif
    }

    // MARK: - Remote commands

    private func installCommands() {
        let center = MPRemoteCommandCenter.shared()

        for (command, target) in commandTargets { command.removeTarget(target) }
        commandTargets = []

        func add(_ command: MPRemoteCommand,
                 handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
            commandTargets.append((command, command.addTarget(handler: handler)))
        }

        /// Transport commands (play/pause/toggle/skip) with a double-fire guard:
        /// some surfaces dispatch two commands for a single press — iOS Control
        /// Center sends the play/pause pair *and* the toggle when all three are
        /// registered, so a press paused and immediately resumed. No human can
        /// press twice within 150 ms, so the machine's repeat is dropped.
        func addTransport(_ command: MPRemoteCommand,
                          _ action: @escaping (AudioPlayer) -> Void) {
            commandTargets.append((command, command.addTarget { [weak self, weak player] _ in
                guard let player else { return .commandFailed }
                if let self, !self.acceptTransport() { return .success }
                action(player)
                return .success
            }))
        }

        addTransport(center.playCommand) { $0.resume() }
        addTransport(center.pauseCommand) { $0.pause() }
        // The toggle is what wired-headphone remotes send for the middle
        // button; with it unregistered the button did nothing while
        // next/previous worked. (macOS media keys send it too.)
        addTransport(center.togglePlayPauseCommand) { $0.togglePlayPause() }
        addTransport(center.nextTrackCommand) { $0.next() }
        addTransport(center.previousTrackCommand) { $0.previous() }
        add(center.changePlaybackPositionCommand) { [weak player] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            player?.seek(to: event.positionTime)
            return .success
        }

        // The system shows 15-second skip buttons in place of next/previous
        // whenever the skip commands are registered. For a music player the
        // track buttons are what's wanted, so the skip pair stays switched off.
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true
    }

    /// See `addTransport`: a transport command within 150 ms of the previous
    /// one is a machine double-fire, not a human. Monotonic clock, so a system
    /// sleep between the two commands cannot fake a gap.
    private var lastTransportAt: TimeInterval = 0
    private func acceptTransport() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        let ok = now - lastTransportAt > 0.15
        lastTransportAt = now
        return ok
    }

    // MARK: - Now playing info

    /// Pushes the current track's state to the system. Called on every transport
    /// change; the system extrapolates elapsed time from `playbackRate` between calls.
    func update(for player: AudioPlayer) {
        let center = MPNowPlayingInfoCenter.default()

        guard let track = player.current else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            publishedArtKey = nil
            publishedArt = nil
            pendingArtKey = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyAlbumArtist: track.albumArtist,
            MPMediaItemPropertyPlaybackDuration: player.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime,
            // The rate is what the lock screen reads as "playing": it has to
            // be exactly zero while paused, otherwise the system keeps
            // offering a pause button for music that is not running.
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? 1.0 : 0.0,
            // The rate the system falls back to when it has to rebuild the
            // scrubber itself; without it the lock screen can show a
            // position that does not match the app.
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        if track.trackNumber > 0 {
            info[MPMediaItemPropertyAlbumTrackNumber] = track.trackNumber
        }
        if !player.queue.isEmpty {
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = player.queue.count
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = player.queueIndex
        }

        applyArtwork(for: track, to: &info, player: player)

        center.nowPlayingInfo = info
        center.playbackState = player.isPlaying ? .playing : .paused
    }

    /// Puts the album art into the info dictionary.
    ///
    /// The system only accepts artwork in the same dictionary as the title, so
    /// the info is pushed again once the image lands. The old code gave up
    /// after the first miss, which is why the lock screen sometimes stayed
    /// artless for the rest of the album.
    private func applyArtwork(for track: Track, to info: inout [String: Any], player: AudioPlayer) {
        let key = track.albumKey

        // Already handed to the system: reuse it, even if the cache dropped it.
        if publishedArtKey == key, let publishedArt {
            info[MPMediaItemPropertyArtwork] = Self.artworkItem(from: publishedArt)
            return
        }
        if let image = ArtworkCache.shared.cached(for: key) {
            publish(image, for: key, into: &info)
            return
        }
        // One request per album at a time; the cache does the real de-duplication.
        guard pendingArtKey != key else { return }
        pendingArtKey = key

        ArtworkCache.shared.artwork(for: track, key: key) { [weak self] image in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.pendingArtKey = nil
                guard image != nil, player.current?.albumKey == key else { return }
                self.update(for: player)
            }
        }
    }

    private func publish(_ image: PlatformImage, for key: String, into info: inout [String: Any]) {
        publishedArt = image
        publishedArtKey = key
        info[MPMediaItemPropertyArtwork] = Self.artworkItem(from: image)
    }

    /// The system keeps its own copy of whatever it is handed, so a 3000px
    /// sleeve would be carried around for the rest of the session.
    private static func artworkItem(from image: PlatformImage) -> MPMediaItemArtwork {
        let small = image.scaled(maxSide: 600)
        return MPMediaItemArtwork(boundsSize: small.size) { _ in small }
    }

    // MARK: - Refresh

    /// Republishes the info while the music plays. The system draws the
    /// position from the last push, and it only re-reads the artwork on a
    /// push — so a cover that finished decoding late still shows up.
    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player, player.isPlaying else { return }
                self.update(for: player)
            }
        }
    }
}
