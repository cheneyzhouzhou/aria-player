import AVFoundation
import Combine
import SwiftUI
#if os(macOS)
import CoreAudio
import AppKit
import AudioToolbox
#endif

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

    #if os(macOS)
    /// Devices discovered on this Mac. A nil `selectedOutputUID` follows the
    /// system default at the moment playback starts.
    @Published var outputDevices: [AudioOutputDevice] = []
    @Published var selectedOutputUID: String?
    @Published var outputMode: OutputMode = .shared
    /// What the last output-mode attempt ended up as. Kept structurally rather
    /// than as a finished sentence: a stored string freezes in whatever
    /// language was active when the status was set, so switching the app
    /// language would leave this line behind until the next status change.
    @Published private(set) var outputStatus: OutputStatus = .sharedDefault
    /// Plain-language result of the last output-mode attempt, shown in
    /// Settings. Localized at read time so a language switch re-renders it.
    var exclusiveStatus: String {
        switch outputStatus {
        case .sharedDefault:
            return L("Shared — the macOS mixer stays in charge; other apps can play at the same time.")
        case .routingFailure(let device):
            let name = device ?? L("the chosen device")
            return LanguageSettings.shared.isChinese
                ? "macOS 拒绝将音频路由到 \(name)——改为通过系统默认设备播放。请尝试其他设备，或切换独占模式。"
                : "macOS refused to route audio to \(name) — playing through the system default instead. Try another device, or toggle Exclusive mode."
        case .sharedMode(let device):
            let name = device ?? L("system default")
            return LanguageSettings.shared.isChinese
                ? "输出：\(name)。共享模式——macOS 混音器仍在信号路径中。"
                : "Output: \(name). Shared mode — the macOS mixer is still in the path."
        case .exclusivePending:
            return L("Exclusive will engage when you start playing a track.")
        case .resetLoop:
            return L("The output device keeps resetting the audio engine — pick another device or switch to Shared.")
        case .hogGranted(let device, let rate):
            return LanguageSettings.shared.isChinese
                ? "已启用独占——\(device) 已锁定至 \(rate)，无重采样。其他应用无法通过此设备播放。"
                : "Exclusive active — \(device) locked to \(rate), no resampling. Other apps cannot play through this device."
        case .hogUnverified(let device, let rate):
            return LanguageSettings.shared.isChinese
                ? "已锁定至 \(rate)（无重采样），但 macOS 未授予独占（hog）访问权限。其他应用仍可能混入此设备，因此无法保证无损直通。"
                : "Rate locked to \(rate) (no resampling), but macOS did not grant exclusive (hog) access. Other apps may still mix into this device, so bit-perfect is not guaranteed."
        case .fellBack(let reason):
            return LanguageSettings.shared.isChinese
                ? "已回退到共享模式——\(reason)"
                : "Fell back to Shared — \(reason)"
        }
    }

    /// The localized-at-read-time statuses above, one case per sentence shape.
    enum OutputStatus {
        case sharedDefault
        case routingFailure(device: String?)
        case sharedMode(device: String?)
        case exclusivePending
        case resetLoop
        case hogGranted(device: String, rate: String)
        case hogUnverified(device: String, rate: String)
        case fellBack(reason: String)
    }
    /// Re-checked shortly after acquiring: macOS can quietly take hog mode
    /// back, and we must not claim bit-perfect when it did.
    @Published var exclusiveHogGranted: Bool = false

    private var hogDeviceID: AudioObjectID?
    /// Set when the HAL output unit refused to move to the selected device and
    /// quietly kept the system default — surfaced in Settings, never hidden.
    private var outputRoutingFailed = false
    /// Every device's rate before Exclusive mode touched the clock. macOS can
    /// move several devices together, so restoring only the target is unsafe.
    private var originalRates: [AudioObjectID: Double] = [:]
    /// The HAL tears its IO client down whenever the device set changes — just
    /// taking hog is enough. AVAudioEngine answers by stopping the graph
    /// without raising an error, so the clock keeps running while no samples
    /// leave the machine: the "exclusive mode plays but is silent" bug. Repair
    /// is scheduled once the burst of notifications settles.
    private var configRepairWork: DispatchWorkItem?
    private var configRepairCount = 0
    private var lastConfigRepairAt = Date.distantPast
    #endif

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

        #if os(macOS)
        selectedOutputUID = UserDefaults.standard.string(forKey: "outputDeviceUID")
        let savedMode = OutputMode(rawValue: UserDefaults.standard.string(forKey: "outputMode") ?? "") ?? .shared
        refreshOutputDevices()

        // Touching the HAL output unit before the engine has finished its first
        // prepare is unreliable, so apply the saved device on the next turn.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyOutputDevice()
            if savedMode == .exclusive { self.setOutputMode(.exclusive) }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.disableExclusive() }
        }

        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.engineConfigurationChanged() }
        }
        #endif

        #if os(iOS)
        // A phone call, a Siri query or a dock taking over stops the session
        // without asking us. The engine falls silent while `isPlaying` stays
        // true — that is how the app and the lock screen end up disagreeing
        // about whether the music is playing.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleInterruption(note) }
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleRouteChange(note) }
        }
        #endif
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

        #if os(macOS)
        syncExclusiveRate(to: audioFile.processingFormat.sampleRate)
        #endif
        prepareEngine(for: audioFile.processingFormat)
        schedule(from: 0)

        if autoplay {
            node.play()
            isPlaying = true
            #if os(macOS)
            configRepairCount = 0
            logOutput("load-play")
            #endif
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
        #if os(macOS)
        // Rebuilding the graph throws away the manually pinned output device:
        // the HAL unit silently falls back to the system default. Pin again
        // before starting, and once more after, because `start()` can revert
        // it too — that revert is why Aria could say "外置耳机" while the sound
        // came out of the speakers.
        pinOutputDevice()
        #endif
        if !engine.isRunning {
            #if os(macOS)
            // A device change can leave the old hardware format behind; a
            // fresh AUHAL start negotiates the new one.
            if !startEngine() { reconnectForCurrentDevice(format) }
            #else
            try? engine.start()
            #endif
        }
        #if os(macOS)
        pinOutputDevice()
        reportRoutingFailure()
        #endif
    }

    #if os(macOS)
    private func startEngine() -> Bool {
        do {
            try engine.start()
            return true
        } catch {
            logOutput("start-failed \(error.localizedDescription)")
            return false
        }
    }

    /// Fallback when starting on the newly pinned device fails: drop the
    /// connections, let the engine adopt the device's own format, then rebuild
    /// the chain around it.
    private func reconnectForCurrentDevice(_ format: AVAudioFormat) {
        engine.stop()
        engine.disconnectNodeOutput(node)
        engine.disconnectNodeOutput(eq)
        engine.connect(node, to: eq, format: format)
        engine.connect(eq, to: engine.mainMixerNode, format: format)
        pinOutputDevice()
        do {
            try engine.start()
        } catch {
            logOutput("reconnect-start-failed \(error.localizedDescription)")
        }
        logOutput("reconnect")
    }
    #endif

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
        #if os(iOS)
        // The system deactivates the session during an interruption and on
        // some route changes. Without reactivating it the engine starts but
        // the phone stays silent — and the lock screen, which follows the
        // session, disagrees with the app.
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        if !engine.isRunning {
            #if os(macOS)
            // Starting without a pin follows the system default, which is not
            // where the user pointed us.
            pinOutputDevice()
            try? engine.start()
            pinOutputDevice()
            #else
            try? engine.start()
            #endif
        }
        node.play()
        isPlaying = true
        #if os(macOS)
        logOutput("resume")
        #endif
        nowPlaying?.update(for: self)
    }

    func pause() {
        node.pause()
        isPlaying = false
        #if os(iOS)
        // The system reads "is this app playing" from the engine's IO, not
        // from the now-playing info: an engine that keeps running and only
        // produces silence still counts as playing, so the Control Center's
        // pause button never changes state and pressing it does nothing
        // visible. `engine.pause()` stops the IO while preserving the node's
        // scheduled segment — resume is just start + play.
        engine.pause()
        #endif
        nowPlaying?.update(for: self)
    }

    func stop() {
        node.stop()
        isPlaying = false
        currentTime = 0
        seekFrame = 0
        #if os(iOS)
        // Same reason as in pause(): a running engine reads as "playing" to
        // the system. The next track re-schedules everything in prepareEngine.
        engine.stop()
        #endif
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
    /// Whether the music was running when the system interrupted us, so it can
    /// be picked up again when the interruption ends.
    private var resumeAfterInterruption = false

    /// A phone call, an alarm, Siri or another app taking the session stops
    /// the audio behind our back. The engine goes quiet while `isPlaying`
    /// stays true, which is exactly how the app and the lock screen end up
    /// disagreeing about whether the music is playing.
    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

        switch type {
        case .began:
            resumeAfterInterruption = isPlaying
            if isPlaying { pause() }
        case .ended:
            let options = (info[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map { AVAudioSession.InterruptionOptions(rawValue: $0) } ?? []
            if resumeAfterInterruption, options.contains(.shouldResume) {
                try? AVAudioSession.sharedInstance().setActive(true)
                resume()
            }
            resumeAfterInterruption = false
        @unknown default:
            break
        }
    }

    /// The output moved: headphones pulled out, a dock attached, AirPods
    /// connected. The hardware format follows the route, so the graph can be
    /// left stopped with the clock still running — and the music would then
    /// play into the phone's speaker instead of stopping.
    private func handleRouteChange(_ note: Notification) {
        let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))

        if reason == .oldDeviceUnavailable, isPlaying {
            pause()
        } else if isPlaying, file != nil, !(engine.isRunning && node.isPlaying) {
            rearmAfterRouteChange()
        }
        nowPlaying?.update(for: self)
    }

    /// Puts the graph back on the same frame after the route changed: the
    /// engine stops itself when the hardware format changes, and the player
    /// node then has nothing queued — the clock keeps running, the sound does
    /// not.
    private func rearmAfterRouteChange() {
        guard let file else { return }
        let format = file.processingFormat
        let session = AVAudioSession.sharedInstance()
        if abs(session.sampleRate - format.sampleRate) > 1 {
            try? session.setPreferredSampleRate(format.sampleRate)
        }
        try? session.setActive(true)

        // The position the app last showed, as a frame in the file.
        let seconds = min(max(0, currentTime), duration)
        let frame = AVAudioFramePosition(seconds * format.sampleRate)
        isSeeking = true
        node.stop()
        engine.stop()
        engine.disconnectNodeOutput(node)
        engine.disconnectNodeOutput(eq)
        engine.connect(node, to: eq, format: format)
        engine.connect(eq, to: engine.mainMixerNode, format: format)
        try? engine.start()
        schedule(from: frame)
        isSeeking = false
        node.play()
    }

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
        return String(format: "%@ · %.1f kHz", L(name), session.sampleRate / 1000)
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

// MARK: - Audio chain snapshot

extension AudioPlayer {
    /// Reads the live engine/session state for the Audio chain panel. Kept in
    /// this file because it needs the private `engine`.
    var audioChain: AudioChain {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let outRate = session.sampleRate
        let outChannels = session.outputNumberOfChannels
        let outName = Self.routeName(for: session)
        let lossy = outputIsLossy
        let deviceBits = 0
        let exclusiveOK = false
        let unverified = false
        #else
        let format = engine.outputNode.outputFormat(forBus: 0)
        let chosen = activeOutputDevice
        let fallbackName: String
        let fallbackWireless: Bool
        if chosen == nil {
            let fallback = Self.outputDevice()
            fallbackName = fallback.name
            fallbackWireless = fallback.isWireless
        } else {
            fallbackName = "System output"
            fallbackWireless = false
        }
        // The device's nominal clock is the real DAC rate; the engine's output
        // format can lag behind after an Exclusive-mode rate change.
        let outRate = chosen.flatMap { AudioOutputHardware.nominalRate($0.id) }
            ?? format.sampleRate
        let outChannels = Int(format.channelCount)
        let outName = chosen?.name ?? fallbackName
        let lossy = chosen?.isWireless ?? fallbackWireless
        let deviceBits = chosen?.bitDepth ?? 0
        let exclusiveOK = outputMode == .exclusive && exclusiveHogGranted
        let unverified = outputMode == .exclusive && !exclusiveHogGranted
        #endif

        // Only verified lossless integer PCM can be called bit-perfect. The
        // format is resolved from the container's codec, not its file name — an
        // `.m4a` may be lossless ALAC or lossy AAC, and only one of those is.
        let lossless = current?.format.isLossless ?? false

        return AudioChain(
            sourceFormat: current?.format.displayName ?? "—",
            sampleRate: current?.sampleRate ?? 0,
            bitDepth: current?.bitDepth ?? 0,
            channels: current?.channels ?? 0,
            bitrate: current?.bitrate ?? 0,
            gainDB: Self.decibels(for: volume),
            eqEnabled: eqEnabled,
            eqPreamp: eqPreamp,
            eqPreset: eqPresetName,
            outputName: outName,
            outputSampleRate: outRate,
            outputChannels: outChannels,
            outputIsLossy: lossy,
            exclusiveUnverified: unverified,
            isExclusiveConfirmed: exclusiveOK,
            deviceBitDepth: deviceBits,
            sourceIsLossless: lossless
        )
    }

    #if os(iOS)
    private static func routeName(for session: AVAudioSession) -> String {
        let port = session.currentRoute.outputs.first
        switch port?.portType {
        case .some(.bluetoothA2DP), .some(.bluetoothLE), .some(.bluetoothHFP):
            return "Bluetooth"
        case .some(.headphones): return "Wired headphones"
        case .some(.builtInSpeaker): return "iPhone speaker"
        case .some(.airPlay): return "AirPlay"
        case .some(.usbAudio): return "USB audio"
        default: return port?.portName ?? "Output"
        }
    }
    #else
    /// Queried at most once every few seconds: the toolbar badge asks for the
    /// chain on every body update, so this must not hit CoreAudio each tick —
    /// but it still has to notice switching from wired to AirPods.
    private static var cachedDevice: (name: String, isWireless: Bool)?
    private static var cachedAt: Date?

    private static func outputDevice() -> (name: String, isWireless: Bool) {
        if let cachedDevice, let cachedAt,
           Date().timeIntervalSince(cachedAt) < 3 { return cachedDevice }

        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &deviceID) == noErr else {
            return ("System output", false)
        }

        var name: CFString?
        size = UInt32(MemoryLayout<CFString?>.size)
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let resultName: String
        if AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &size, &name) == noErr,
           let name {
            resultName = name as String
        } else {
            resultName = "System output"
        }

        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var wireless = false
        if AudioObjectGetPropertyData(deviceID, &transportAddress, 0, nil,
                                      &size, &transport) == noErr {
            wireless = transport == kAudioDeviceTransportTypeBluetooth
                || transport == kAudioDeviceTransportTypeBluetoothLE
                || transport == kAudioDeviceTransportTypeAirPlay
        }

        let result = (name: resultName, isWireless: wireless)
        cachedDevice = result
        cachedAt = Date()
        return result
    }
    #endif
}

// MARK: - Output device & mode (macOS)

#if os(macOS)
extension AudioPlayer {
    func refreshOutputDevices() {
        outputDevices = AudioOutputHardware.devices()
        if let uid = selectedOutputUID,
           !outputDevices.contains(where: { $0.uid == uid }) {
            // Unplugged since last launch: follow the system default again.
            selectedOutputUID = nil
            UserDefaults.standard.removeObject(forKey: "outputDeviceUID")
        }
    }

    var activeOutputDevice: AudioOutputDevice? {
        if let uid = selectedOutputUID,
           let found = outputDevices.first(where: { $0.uid == uid }) { return found }
        return outputDevices.first { $0.isDefault }
    }

    private func activeDeviceID() -> AudioObjectID? {
        activeOutputDevice?.id ?? AudioOutputHardware.defaultDeviceID()
    }

    /// Points AVAudioEngine's HAL output unit at the chosen device. Once set
    /// explicitly the unit stops following the system default, so we always
    /// pin it to the current default when the user hasn't chosen one.
    ///
    /// The pin is fragile: reconnecting the graph, and in some cases starting
    /// the engine, hands the unit back to the system default. `pinOutputDevice`
    /// is therefore also called from `prepareEngine`, and every teardown here
    /// has to be followed by `restartRenderChain(at:)` or playback comes back
    /// up silent.
    private func applyOutputDevice() {
        guard activeDeviceID() != nil else { return }
        let wasRunning = engine.isRunning
        engine.stop()
        // The new device has its own clock, so the render chain has to be
        // negotiated again against it.
        connectedFormat = nil
        pinOutputDevice()
        if wasRunning { try? engine.start() }
        // The first pin often does not stick while the engine is stopped; the
        // start renegotiates the unit, so pin once more.
        pinOutputDevice()
        logOutput("apply")
    }

    /// Says so plainly when macOS kept the audio on the system default instead
    /// of the device the user picked — otherwise the UI would be lying.
    private func reportRoutingFailure() {
        guard outputRoutingFailed else { return }
        outputStatus = .routingFailure(device: activeOutputDevice?.name)
    }

    /// The device the HAL output unit is bound to right now, which is not
    /// necessarily the one the UI has selected.
    private func unitDevice(_ unit: AudioUnit) -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                   kAudioUnitScope_Global, 0, &id, &size) == noErr else {
            return nil
        }
        return id
    }

    /// Makes the HAL output unit follow the selected device and verifies it by
    /// reading the property back — a device can quietly refuse the switch.
    @discardableResult
    private func pinOutputDevice() -> Bool {
        guard let wanted = activeDeviceID(),
              let unit = engine.outputNode.audioUnit else { return false }
        if unitDevice(unit) == wanted {
            outputRoutingFailed = false
            return true
        }
        var target: AudioDeviceID = wanted
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &target, UInt32(MemoryLayout<AudioDeviceID>.size))
        let landed = status == noErr && unitDevice(unit) == wanted
        outputRoutingFailed = !landed
        if !landed {
            logOutput("pin-failed osstatus=\(status)")
        }
        return landed
    }

    func selectOutputDevice(uid: String) {
        // Read the frame counter while the old device is still running —
        // everything below tears the engine down.
        let resumeAt = renderedFrame()
        let reacquire = outputMode == .exclusive
        if reacquire { disableExclusive() }
        selectedOutputUID = uid
        UserDefaults.standard.set(uid, forKey: "outputDeviceUID")
        refreshOutputDevices()
        applyOutputDevice()
        if reacquire {
            // Same work as tapping the Exclusive card, but without its own
            // re-arm: this whole switch re-arms once, at the end.
            engageOutputMode(.exclusive)
        } else {
            outputStatus = .sharedMode(device: activeOutputDevice?.name)
        }
        restartRenderChain(at: resumeAt)
        reportRoutingFailure()
    }

    func setOutputMode(_ mode: OutputMode) {
        let resumeAt = renderedFrame()
        engageOutputMode(mode)
        restartRenderChain(at: resumeAt)
        reportRoutingFailure()
    }

    /// The mode work on its own, with no playback re-arming, so a caller doing
    /// several engine restarts in a row (device switch, then mode) can put the
    /// player back together exactly once.
    private func engageOutputMode(_ mode: OutputMode) {
        if mode == .shared {
            disableExclusive()
            return
        }
        UserDefaults.standard.set(OutputMode.exclusive.rawValue, forKey: "outputMode")
        let rate = file?.processingFormat.sampleRate
            ?? current.map { Double($0.sampleRate) }
            ?? 0
        if rate > 0 {
            engageExclusive(rate: rate)
        } else {
            // Nothing is playing yet; the real lock happens on the first track.
            outputMode = .exclusive
            outputStatus = .exclusivePending
        }
    }

    /// Where the player node has actually rendered up to, in source frames,
    /// including the seek offset. Has to be read *before* the engine stops:
    /// the node's clock does not survive a restart.
    private func renderedFrame() -> AVAudioFramePosition? {
        guard let file else { return nil }
        if isPlaying,
           let renderTime = node.lastRenderTime,
           let playerTime = node.playerTime(forNodeTime: renderTime) {
            // `playerTime` is relative to the scheduled segment, `seekFrame` is
            // where that segment started.
            return seekFrame + playerTime.sampleTime
        }
        // Paused, or the clock is already gone. `currentTime` is already an
        // absolute track position — adding `seekFrame` on top would jump the
        // track forward by however far in the last segment started.
        return AVAudioFramePosition(currentTime * file.processingFormat.sampleRate)
    }

    /// Ground truth for output switching: what the HAL output unit is really
    /// bound to, which can differ from the device the UI shows as chosen.
    /// Silent unless `defaults write com.example.aria debugOutputLog -bool YES`.
    private func logOutput(_ step: String) {
        guard UserDefaults.standard.bool(forKey: "debugOutputLog") else { return }
        var actual: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        if let unit = engine.outputNode.audioUnit {
            _ = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                     kAudioUnitScope_Global, 0, &actual, &size)
        }
        let bound = outputDevices.first { $0.id == actual }?.name ?? "device-\(actual)"
        let format = engine.outputNode.outputFormat(forBus: 0)
        let line = String(
            format: "%@ wanted=%@ actual=%@ engine=%@ node=%@ out=%.0fHz/%uch t=%.2f\n",
            step,
            activeOutputDevice?.name ?? "system default",
            bound,
            engine.isRunning ? "running" : "stopped",
            node.isPlaying ? "playing" : "idle",
            format.sampleRate, format.channelCount, currentTime)
        let url = URL(fileURLWithPath: "/tmp/aria-output.log")
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    /// An engine restart drops the segment the player node had queued: the
    /// graph comes back up silent while the clock keeps ticking, which is why
    /// switching devices used to need a manual pause/play. Rebuild the chain
    /// against the (new) device and drop back into the same frame.
    private func restartRenderChain(at frame: AVAudioFramePosition?) {
        guard let file else { return }
        let format = file.processingFormat
        let resumeAt = min(max(0, frame ?? renderedFrame() ?? 0),
                           max(0, file.length - 1))

        // `node.stop()` fires the outgoing segment's completion callback; the
        // flag keeps that from being read as "track ended". `schedule` bumps
        // the generation too, so an older callback can't advance the queue.
        isSeeking = true
        node.stop()
        prepareEngine(for: format)   // rebuilds the connections, starts the engine
        schedule(from: resumeAt)
        isSeeking = false

        currentTime = Double(resumeAt) / format.sampleRate
        if isPlaying { node.play() }
        nowPlaying?.update(for: self)
        logOutput("rearm")
    }

    /// Any change to the device set makes the HAL close and reopen its IO
    /// client — taking hog mode is such a change. AVAudioEngine reacts by
    /// stopping the graph without throwing, so `isPlaying` stays true and the
    /// clock keeps advancing while the device sits idle: that silence is what
    /// "switching output mode kills the sound" really was. Give the burst of
    /// notifications a moment to settle, then put the graph back on the same
    /// frame.
    private func engineConfigurationChanged() {
        guard file != nil else { return }
        // Our own rebuilds fire this too. A live engine with a playing node
        // means there is nothing to repair.
        guard !(engine.isRunning && node.isPlaying) else {
            configRepairCount = 0
            return
        }
        configRepairWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.repairRenderChain() }
        }
        configRepairWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func repairRenderChain() {
        configRepairWork = nil
        guard file != nil, isPlaying else { return }
        guard !(engine.isRunning && node.isPlaying) else { return }
        // Only a device that keeps collapsing the graph in quick succession is
        // a real failure; a burst of user-driven switches is not.
        if Date().timeIntervalSince(lastConfigRepairAt) > 2 {
            configRepairCount = 0
        }
        lastConfigRepairAt = Date()
        configRepairCount += 1
        guard configRepairCount <= 5 else {
            outputStatus = .resetLoop
            return
        }
        logOutput("config-repair")
        restartRenderChain(at: renderedFrame())
    }

    /// The real work: verify the device declares this rate, switch its clock,
    /// restart the engine on the new format, then take hog mode and read the
    /// ownership back. Any failed step falls back to Shared rather than
    /// pretending to be bit-perfect — the same guard RustMusic uses.
    private func engageExclusive(rate: Double) {
        guard let id = activeDeviceID() else {
            fallBackToShared(reason: "No output device is available.")
            return
        }
        let device = outputDevices.first { $0.id == id }
        guard device?.supports(rate: rate) == true else {
            fallBackToShared(reason: "\(device?.name ?? "The device") does not list \(AudioOutputDevice.kHz(rate)) among its supported rates.")
            return
        }

        // Remember every device's clock before touching it: setting one device's
        // nominal rate can move the others on this Mac too.
        originalRates = [:]
        for device in outputDevices {
            if let rate = AudioOutputHardware.nominalRate(device.id) {
                originalRates[device.id] = rate
            }
        }

        engine.stop()
        guard AudioOutputHardware.setNominalRate(id, rate) else {
            fallBackToShared(reason: "The device refused to switch to \(AudioOutputDevice.kHz(rate)).")
            try? engine.start()
            return
        }
        connectedFormat = nil
        // Changing the clock re-negotiates the stream on the system default,
        // so make sure the unit is still on the device we just re-clocked.
        pinOutputDevice()
        _ = startEngine()
        pinOutputDevice()

        // Hog mode is a bonus, not a prerequisite: a rate-matched stream is
        // still useful without it, but it is NOT guaranteed bit-perfect while
        // other apps can mix into the device. Say so plainly.
        let granted = AudioOutputHardware.acquireHog(id)
        exclusiveHogGranted = granted
        hogDeviceID = granted ? id : nil
        outputMode = .exclusive
        logOutput("engage-hog")

        let rateText = AudioOutputDevice.kHz(rate)
        let deviceName = device?.name ?? "device"
        outputStatus = granted
            ? .hogGranted(device: deviceName, rate: rateText)
            : .hogUnverified(device: deviceName, rate: rateText)

        guard granted else { return }
        // macOS can quietly reclaim hog mode once the engine is running.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.outputMode == .exclusive,
                  let held = self.hogDeviceID,
                  self.exclusiveHogGranted else { return }
            let stillOurs = AudioOutputHardware.hogOwner(held) == getpid()
            self.exclusiveHogGranted = stillOurs
            self.outputStatus = stillOurs
                ? .hogGranted(device: deviceName, rate: rateText)
                : .hogUnverified(device: deviceName, rate: rateText)
        }
    }

    private func disableExclusive() {
        let held = hogDeviceID
        if let held { AudioOutputHardware.releaseHog(held) }
        hogDeviceID = nil
        exclusiveHogGranted = false
        for (deviceID, rate) in originalRates {
            if let now = AudioOutputHardware.nominalRate(deviceID), abs(now - rate) >= 1 {
                AudioOutputHardware.setNominalRate(deviceID, rate)
            }
        }
        originalRates = [:]
        connectedFormat = nil
        outputMode = .shared
        UserDefaults.standard.set(OutputMode.shared.rawValue, forKey: "outputMode")
        outputStatus = .sharedDefault
    }

    private func fallBackToShared(reason: String) {
        disableExclusive()
        outputStatus = .fellBack(reason: reason)
    }

    /// Exclusive mode has to follow each track's rate. Called from `load(_:)`
    /// before the engine connections are rebuilt.
    private func syncExclusiveRate(to rate: Double) {
        guard outputMode == .exclusive else { return }
        guard hogDeviceID != nil else {
            engageExclusive(rate: rate)
            return
        }
        guard let id = activeDeviceID(),
              let device = outputDevices.first(where: { $0.id == id }),
              device.supports(rate: rate) else {
            fallBackToShared(reason: "This track's \(AudioOutputDevice.kHz(rate)) is not supported by the device.")
            return
        }
        if let now = AudioOutputHardware.nominalRate(id), abs(now - rate) < 1 { return }
        engine.stop()
        guard AudioOutputHardware.setNominalRate(id, rate) else {
            fallBackToShared(reason: "The device refused to switch to \(AudioOutputDevice.kHz(rate)).")
            return
        }
        connectedFormat = nil
        // prepareEngine(_:) restarts the engine on the new device format.
    }
}
#endif
