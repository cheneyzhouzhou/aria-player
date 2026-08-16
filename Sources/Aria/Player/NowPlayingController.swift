import MediaPlayer

/// Bridges the player to macOS: media keys, Control Center, and the Now Playing
/// widget all talk to `MPRemoteCommandCenter` / `MPNowPlayingInfoCenter`.
@MainActor
final class NowPlayingController {
    private weak var player: AudioPlayer?
    private var lastArtKey: String?

    func attach(to player: AudioPlayer) {
        self.player = player
        player.nowPlaying = self

        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak player] _ in
            player?.resume()
            return .success
        }
        center.pauseCommand.addTarget { [weak player] _ in
            player?.pause()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak player] _ in
            player?.togglePlayPause()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak player] _ in
            player?.next()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak player] _ in
            player?.previous()
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak player] event in
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

    /// Pushes the current track's state to the system. Called on every transport
    /// change; the system extrapolates elapsed time from `playbackRate` between calls.
    func update(for player: AudioPlayer) {
        let center = MPNowPlayingInfoCenter.default()

        guard let track = player.current else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyAlbumArtist: track.albumArtist,
            MPMediaItemPropertyPlaybackDuration: player.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        if track.trackNumber > 0 {
            info[MPMediaItemPropertyAlbumTrackNumber] = track.trackNumber
        }

        // Reuse whatever the UI already decoded; only fetch when the album changes.
        let key = track.albumKey
        if let image = ArtworkCache.shared.cached(for: key) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            lastArtKey = key
        } else if lastArtKey != key {
            lastArtKey = key
            ArtworkCache.shared.artwork(for: track, key: key) { [weak self] image in
                // Re-entering with the art now cached fills in the artwork field.
                guard image != nil, let self, let player = self.player,
                      player.current?.albumKey == key else { return }
                self.update(for: player)
            }
        }

        center.nowPlayingInfo = info
        center.playbackState = player.isPlaying ? .playing : .paused
    }
}
