import AVFoundation
import Combine
import SwiftUI

enum RepeatMode: String, CaseIterable {
    case off, all, one

    var symbol: String { self == .one ? "repeat.1" : "repeat" }
}

@MainActor
final class AudioPlayer: ObservableObject {
    @Published private(set) var current: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var queue: [Track] = []
    @Published private(set) var queueIndex: Int = 0
    @Published var repeatMode: RepeatMode = .off
    @Published var isShuffled = false {
        didSet { rebuildOrder() }
    }
    /// Slider position, 0…1, read as a decibel fader rather than as a linear
    /// multiplier. 1.0 is unity gain, 0.5 is −25 dB, 0 is silence.
    ///
    /// iOS's lowest system volume step is a fixed 1/16 of the hardware range,
    /// which is still far too loud for sensitive in-ear monitors. A dB fader
    /// lets the app go on attenuating below it, and spreads the useful range
    /// over the whole slider instead of cramming it into the top few percent.
    @Published var volume: Float = 1.0 {
        didSet {
            engine.mainMixerNode.outputVolume = Self.gain(for: volume)
            UserDefaults.standard.set(volume, forKey: "volume")
            UserDefaults.standard.set(Int(Self.decibels(for: volume).rounded()), forKey: "volumeDB")
        }
    }

    /// How far down the fader can go. −50 dB is quiet enough for any in-ear
    /// on a phone whose bottom step is already too loud, and still leaves
    /// headroom above pure silence for fine adjustment.
    static let volumeFloorDB: Float = 50

    static func decibels(for position: Float) -> Float {
        -volumeFloorDB * (1 - max(0, min(1, position)))
    }

    static func gain(for position: Float) -> Float {
        let p = max(0, min(1, position))
        guard p > 0.0001 else { return 0 }
        return powf(10, decibels(for: p) / 20)
    }

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: Equalizer.bandCount)
    private var file: AVAudioFile?
    private var connectedFormat: AVAudioFormat?

    /// Frame the current scheduled segment started at — the player node's own
    /// clock resets on every stop/schedule, so seeking is tracked separately.
    private var seekFrame: AVAudioFramePosition = 0
    /// Bumped on every schedule so a stale completion callback can't advance us.
    private var generation = 0
    private var isSeeking = false
    private var ticker: Timer?

    /// Playback order into `queue`: identity normally, a permutation when shuffled.
    private var order: [Int] = []
    private var orderPosition: Int = 0

    // MARK: Equalizer

    @Published var eqEnabled: Bool = false {
        didSet {
            applyEQ()
            UserDefaults.standard.set(eqEnabled, forKey: "eqEnabled")
        }
    }
    /// Per-band gain in dB, matching `Equalizer.frequencies`.
    @Published private(set) var eqGains: [Float] = Equalizer.flat.gains
    /// Name of the preset in use, or nil once bands are hand-adjusted.
    @Published private(set) var eqPresetName: String? = Equalizer.flat.name
    /// Overall trim, useful to claw back headroom after a heavy boost.
    @Published var eqPreamp: Float = 0 {
        didSet {
            applyEQ()
            UserDefaults.standard.set(eqPreamp, forKey: "eqPreamp")
        }
    }

    var nowPlaying: NowPlayingController?

    init() {
        let saved = UserDefaults.standard.object(forKey: "volume") as? Float
        volume = saved ?? 1.0

        #if os(iOS)
        // Without this the app is silenced by the ringer switch and stops on
        // lock. macOS has no session to configure.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        #endif
        engine.attach(node)
        engine.attach(eq)
        for (index, frequency) in Equalizer.frequencies.enumerated() {
            let band = eq.bands[index]
            band.filterType = .parametric
            band.frequency = frequency
            band.bandwidth = 0.75      // octaves — overlaps neighbours smoothly
            band.bypass = false
            band.gain = 0
        }
        engine.connect(node, to: eq, format: nil)
        engine.connect(eq, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = Self.gain(for: volume)

        // Restore the saved curve before the first track is scheduled.
        if let saved = UserDefaults.standard.array(forKey: "eqGains") as? [Double],
           saved.count == Equalizer.bandCount {
            eqGains = saved.map(Float.init)
        }
        eqPresetName = UserDefaults.standard.string(forKey: "eqPreset")
        eqPreamp = UserDefaults.standard.object(forKey: "eqPreamp") as? Float ?? 0
        eqEnabled = UserDefaults.standard.bool(forKey: "eqEnabled")
        engine.prepare()
        startTicker()
    }

    // MARK: - Queue control

    /// Plays `track` in the context of `tracks` so next/previous follow the list
    /// the user actually clicked in.
    func play(_ track: Track, in tracks: [Track]) {
        queue = tracks
        let index = tracks.firstIndex(of: track) ?? 0
        queueIndex = index
        rebuildOrder(startingAt: index)
        load(track, autoplay: true)
    }

    func playAll(_ tracks: [Track], shuffled: Bool = false) {
        guard !tracks.isEmpty else { return }
        if shuffled != isShuffled { isShuffled = shuffled }
        queue = tracks
        rebuildOrder(startingAt: shuffled ? Int.random(in: 0..<tracks.count) : 0)
        queueIndex = order[orderPosition]
        load(queue[queueIndex], autoplay: true)
    }

    func next(userInitiated: Bool = true) {
        guard !queue.isEmpty else { return }
        if repeatMode == .one && !userInitiated {
            seek(to: 0)
            resume()
            return
        }
        if orderPosition + 1 < order.count {
            orderPosition += 1
        } else if repeatMode == .all || userInitiated {
            orderPosition = 0
        } else {
            stop()
            return
        }
        queueIndex = order[orderPosition]
        load(queue[queueIndex], autoplay: true)
    }

    func previous() {
        guard !queue.isEmpty else { return }
        // Matches every other player: restart the track unless you're near its start.
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        orderPosition = orderPosition > 0 ? orderPosition - 1 : max(0, order.count - 1)
        queueIndex = order[orderPosition]
        load(queue[queueIndex], autoplay: true)
    }

    private func rebuildOrder(startingAt index: Int? = nil) {
        guard !queue.isEmpty else {
            order = []
            orderPosition = 0
            return
        }
        let anchor = index ?? queueIndex
        if isShuffled {
            var rest = Array(queue.indices)
            rest.removeAll { $0 == anchor }
            order = [anchor] + rest.shuffled()
            orderPosition = 0
        } else {
            order = Array(queue.indices)
            orderPosition = min(anchor, order.count - 1)
        }
    }

    // MARK: - Transport

    private func load(_ track: Track, autoplay: Bool) {
        node.stop()
        generation += 1

        guard let audioFile = try? AVAudioFile(forReading: track.url) else {
            // A file that vanished or won't decode shouldn't wedge the queue.
            current = track
            duration = 0
            if queue.count > 1 { next(userInitiated: false) }
            return
        }

        file = audioFile
        current = track
        duration = track.duration > 0
            ? track.duration
            : Double(audioFile.length) / audioFile.processingFormat.sampleRate
        currentTime = 0
        seekFrame = 0

        prepareEngine(for: audioFile.processingFormat)
        schedule(from: 0)

        if autoplay {
            node.play()
            isPlaying = true
        }
        nowPlaying?.update(for: self)
    }

    /// Sample rates differ between albums, so the mixer connection is rebuilt
    /// whenever the incoming file's format changes.
    private func prepareEngine(for format: AVAudioFormat) {
        #if os(iOS)
        // iOS runs its output at 48 kHz by default. Every 44.1 kHz file would
        // then be resampled on the fly; asking the hardware to match the file
        // avoids that conversion entirely. Bluetooth ignores the request and
        // picks its own rate, which is expected.
        let session = AVAudioSession.sharedInstance()
        if abs(session.sampleRate - format.sampleRate) > 1 {
            try? session.setPreferredSampleRate(format.sampleRate)
        }
        #endif

        if connectedFormat == nil || !format.isEqual(connectedFormat!) {
            engine.stop()
            // Two hops to rebuild now that the equalizer sits in the chain.
            engine.disconnectNodeOutput(node)
            engine.disconnectNodeOutput(eq)
            engine.connect(node, to: eq, format: format)
            engine.connect(eq, to: engine.mainMixerNode, format: format)
            connectedFormat = format
        }
        if !engine.isRunning {
            try? engine.start()
        }
    }

    private func schedule(from frame: AVAudioFramePosition) {
        guard let file else { return }
        let remaining = AVAudioFrameCount(max(0, file.length - frame))
        guard remaining > 0 else { return }
        seekFrame = frame
        generation += 1
        let token = generation

        node.scheduleSegment(file, startingFrame: frame, frameCount: remaining, at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, token == self.generation, !self.isSeeking else { return }
                self.handleTrackFinished()
            }
        }
    }

    private func handleTrackFinished() {
        if repeatMode == .one {
            seek(to: 0)
            resume()
        } else {
            next(userInitiated: false)
        }
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func resume() {
        guard current != nil else { return }
        if !engine.isRunning { try? engine.start() }
        node.play()
        isPlaying = true
        nowPlaying?.update(for: self)
    }

    func pause() {
        node.pause()
        isPlaying = false
        nowPlaying?.update(for: self)
    }

    func stop() {
        node.stop()
        isPlaying = false
        currentTime = 0
        seekFrame = 0
        nowPlaying?.update(for: self)
    }

    func seek(to seconds: Double) {
        guard let file else { return }
        let rate = file.processingFormat.sampleRate
        let target = AVAudioFramePosition(max(0, min(seconds, duration)) * rate)
        let wasPlaying = isPlaying

        // The stop below fires the outgoing segment's completion callback; the
        // flag keeps that from being read as "track ended".
        isSeeking = true
        node.stop()
        schedule(from: target)
        currentTime = Double(target) / rate
        isSeeking = false

        if wasPlaying {
            node.play()
            isPlaying = true
        }
        nowPlaying?.update(for: self)
    }

    func skip(by delta: Double) {
        seek(to: currentTime + delta)
    }

    // MARK: - Output diagnostics

    #if os(iOS)
    /// What the audio is actually leaving through, and at what rate.
    var outputDescription: String {
        let session = AVAudioSession.sharedInstance()
        let port = session.currentRoute.outputs.first
        let name: String
        switch port?.portType {
        case .some(.bluetoothA2DP), .some(.bluetoothLE), .some(.bluetoothHFP):
            name = "Bluetooth"
        case .some(.headphones): name = "Wired headphones"
        case .some(.builtInSpeaker): name = "Phone speaker"
        case .some(.airPlay): name = "AirPlay"
        case .some(.usbAudio): name = "USB audio"
        default: name = port?.portName ?? "Unknown"
        }
        return String(format: "%@ · %.1f kHz", name, session.sampleRate / 1000)
    }

    /// Bluetooth re-encodes the stream, so lossless source material stops being
    /// lossless at the point it leaves the phone.
    var outputIsLossy: Bool {
        switch AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType {
        case .some(.bluetoothA2DP), .some(.bluetoothLE), .some(.bluetoothHFP), .some(.airPlay):
            return true
        default:
            return false
        }
    }
    #endif

    // MARK: - Equalizer control

    func apply(preset: EQPreset) {
        eqGains = preset.gains
        eqPresetName = preset.name
        if !eqEnabled && !preset.isFlat { eqEnabled = true }
        persistEQ()
        applyEQ()
    }

    /// Adjusts one band, which drops the "preset" label since the curve is now
    /// the user's own.
    func setGain(_ gain: Float, forBand index: Int) {
        guard eqGains.indices.contains(index) else { return }
        eqGains[index] = max(-12, min(12, gain))
        eqPresetName = Equalizer.presets.first { $0.gains == eqGains }?.name
        persistEQ()
        applyEQ()
    }

    func resetEQ() {
        apply(preset: .init(name: Equalizer.flat.name, gains: Equalizer.flat.gains))
        eqPreamp = 0
    }

    /// Pushes the current curve onto the audio unit. Bypassing costs nothing
    /// when the equalizer is off.
    private func applyEQ() {
        for (index, band) in eq.bands.enumerated() where index < eqGains.count {
            band.gain = eqEnabled ? eqGains[index] : 0
            band.bypass = !eqEnabled
        }
        eq.globalGain = eqEnabled ? eqPreamp : 0
    }

    private func persistEQ() {
        UserDefaults.standard.set(eqGains.map(Double.init), forKey: "eqGains")
        UserDefaults.standard.set(eqPresetName, forKey: "eqPreset")
    }

    // MARK: - Clock

    private func startTicker() {
        ticker = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard isPlaying, let file else { return }
        guard let renderTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: renderTime) else { return }
        let frame = seekFrame + playerTime.sampleTime
        currentTime = min(Double(frame) / file.processingFormat.sampleRate, duration)
    }

    /// The upcoming track, for the queue view.
    var upNext: [Track] {
        guard !order.isEmpty else { return [] }
        let tail = order[min(orderPosition + 1, order.count)...]
        return tail.map { queue[$0] }
    }
}
