#if os(macOS)
import Foundation
import CoreAudio
import SwiftUI

// MARK: - Model

/// One CoreAudio output device with its declared capabilities. Everything here
/// is read from the HAL, nothing is guessed from the device name.
struct AudioOutputDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transport: UInt32
    let channels: Int
    let bitDepth: Int
    let nominalRate: Double
    let availableRates: [Double]
    let isDefault: Bool

    var maxRate: Double { availableRates.max() ?? nominalRate }

    /// The "Hi-Res / CD quality" style badge, derived from what the device
    /// actually declares rather than a hardcoded capability table.
    /// Hi-Res needs both a high clock and at least 24 real bits; Ultra starts
    /// at 352.8 kHz. Mirrors RustMusic's `qualityTier()` so a 96 kHz/16-bit
    /// device can't be advertised as Hi-Res.
    var capability: String {
        guard maxRate >= 88_200, bitDepth >= 24 else { return "CD quality" }
        return maxRate >= 352_800 ? "Ultra Hi-Res" : "Hi-Res"
    }

    var capabilityColor: Color {
        switch capability {
        case "Ultra Hi-Res": return Color(red: 0.68, green: 0.52, blue: 0.96)
        case "Hi-Res": return Color(red: 0.99, green: 0.68, blue: 0.29)
        default: return Color(red: 0.62, green: 0.65, blue: 0.70)
        }
    }

    var isWireless: Bool {
        transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
            || transport == kAudioDeviceTransportTypeAirPlay
    }

    var symbol: String {
        if isWireless { return "airpodspro" }
        switch transport {
        case kAudioDeviceTransportTypeUSB: return "cable.connector.horizontal"
        case kAudioDeviceTransportTypeHDMI,
             kAudioDeviceTransportTypeDisplayPort: return "display"
        case kAudioDeviceTransportTypeBuiltIn: return "speaker.wave.2.fill"
        default: return "hifispeaker.fill"
        }
    }

    /// The headline rate in the device list is the top of the declared range
    /// (96 kHz, 384 kHz …), not whatever the clock happens to be running at.
    var rateText: String { Self.kHz(maxRate) }
    var bitText: String { bitDepth > 0 ? "\(bitDepth) " + L("bit") : "—" }
    var channelText: String { channels > 0 ? "\(channels) " + L("ch") : "—" }

    static func kHz(_ rate: Double) -> String {
        guard rate > 0 else { return "—" }
        return String(format: "%.1f kHz", rate / 1000)
    }

    /// Whether the device declares this exact rate (within 1 Hz).
    func supports(rate: Double) -> Bool {
        availableRates.contains { abs($0 - rate) < 1 }
    }
}

// MARK: - Modes

enum OutputMode: String, Codable, CaseIterable {
    case shared
    case exclusive

    var title: String {
        switch self {
        case .shared: return "Shared"
        case .exclusive: return "Exclusive · bit-perfect"
        }
    }

    /// Compact label for tight spots (the audio-chain chips), where the
    /// descriptive `title` would not fit on one line.
    var shortTitle: String {
        switch self {
        case .shared: return "Shared"
        case .exclusive: return "Exclusive"
        }
    }

    var detail: String {
        switch self {
        case .shared:
            return "Audio goes through the macOS mixer alongside other apps. The system may resample it. Best for everyday use."
        case .exclusive:
            return "Aria takes exclusive access to the device (hog mode) and switches it to each track's own sample rate, so no resampling or mixing happens."
        }
    }
}

// MARK: - HAL access

/// Thin, read-only-until-asked CoreAudio wrapper. Kept out of the player class
/// so the same probes can be used by the settings UI and the signal chain.
enum AudioOutputHardware {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// Reads a CFString property. `withUnsafeMutablePointer` keeps the pointer
    /// semantics explicit (and avoids Swift's Optional-to-raw-pointer warning).
    private static func stringProperty(_ id: AudioObjectID,
                                       _ selector: AudioObjectPropertySelector) -> String? {
        var a = address(selector)
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(id, &a, 0, nil, &size, UnsafeMutableRawPointer(ptr))
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    private static func fixed<T>(_ id: AudioObjectID, _ a: inout AudioObjectPropertyAddress,
                                 _ value: inout T) -> Bool {
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr
    }

    static func defaultDeviceID() -> AudioObjectID? {
        var a = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioObjectID(0)
        return fixed(systemObject, &a, &id) ? id : nil
    }

    private static func allDeviceIDs() -> [AudioObjectID] {
        var a = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &a, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0,
                                  count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(systemObject, &a, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    static func outputChannelCount(_ id: AudioObjectID) -> Int {
        var a = address(kAudioDevicePropertyStreamConfiguration,
                        scope: kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: Int(size))
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return 0 }
        // AudioBufferList is variable-length: use the proper pointer wrapper,
        // otherwise the second and later buffers are read out of bounds.
        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func nominalRate(_ id: AudioObjectID) -> Double? {
        var a = address(kAudioDevicePropertyNominalSampleRate)
        var value = Float64(0)
        return fixed(id, &a, &value) ? value : nil
    }

    static func availableRates(_ id: AudioObjectID) -> [Double] {
        var a = address(kAudioDevicePropertyAvailableNominalSampleRates)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: count)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &ranges) == noErr else {
            return []
        }
        return ranges.map(\.mMinimum).filter { $0 > 0 }.sorted()
    }

    static func bitDepth(_ id: AudioObjectID) -> Int {
        var a = address(kAudioDevicePropertyStreamFormat,
                        scope: kAudioDevicePropertyScopeOutput)
        var format = AudioStreamBasicDescription()
        return fixed(id, &a, &format) ? Int(format.mBitsPerChannel) : 0
    }

    static func transport(_ id: AudioObjectID) -> UInt32 {
        var a = address(kAudioDevicePropertyTransportType)
        var value: UInt32 = 0
        return fixed(id, &a, &value) ? value : 0
    }

    static func devices() -> [AudioOutputDevice] {
        let defaultID = defaultDeviceID()
        return allDeviceIDs().compactMap { id in
            let channels = outputChannelCount(id)
            guard channels > 0 else { return nil }   // input-only device
            let name = stringProperty(id, kAudioObjectPropertyName) ?? "Unknown device"
            // AVAudioEngine spawns a private aggregate device (named after our
            // own pid) while probing formats. It is not a real output to offer.
            guard !name.hasPrefix("CADefaultDeviceAggregate") else { return nil }
            return AudioOutputDevice(
                id: id,
                uid: stringProperty(id, kAudioDevicePropertyDeviceUID) ?? "device-\(id)",
                name: name,
                transport: transport(id),
                channels: channels,
                bitDepth: bitDepth(id),
                nominalRate: nominalRate(id) ?? 0,
                availableRates: availableRates(id),
                isDefault: id == defaultID
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name < rhs.name
        }
    }

    // MARK: Mutating (only used by Exclusive mode)

    /// Sets the device's clock rate, then reads it back. A device can silently
    /// ignore the request, so the read-back is what actually proves success.
    @discardableResult
    static func setNominalRate(_ id: AudioObjectID, _ rate: Double) -> Bool {
        var a = address(kAudioDevicePropertyNominalSampleRate)
        var value = Float64(rate)
        let size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectSetPropertyData(id, &a, 0, nil, size, &value) == noErr else {
            return false
        }
        return nominalRate(id).map { abs($0 - rate) < 1 } ?? false
    }

    /// Returns the pid currently holding hog mode, or -1 when nobody does.
    static func hogOwner(_ id: AudioObjectID) -> pid_t {
        var a = address(kAudioDevicePropertyHogMode)
        var owner: pid_t = -1
        _ = fixed(id, &a, &owner)
        return owner
    }

    /// Takes hog mode, but only if it is free (or already ours), and verifies
    /// ownership by reading the property back — the same guard RustMusic uses.
    static func acquireHog(_ id: AudioObjectID) -> Bool {
        let existing = hogOwner(id)
        let me = getpid()
        if existing != -1 && existing != me { return false }

        var a = address(kAudioDevicePropertyHogMode)
        var want = me
        let size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectSetPropertyData(id, &a, 0, nil, size, &want)
        return status == noErr && hogOwner(id) == me
    }

    static func releaseHog(_ id: AudioObjectID) {
        guard hogOwner(id) == getpid() else { return }
        var a = address(kAudioDevicePropertyHogMode)
        var free: pid_t = -1
        let size = UInt32(MemoryLayout<pid_t>.size)
        _ = AudioObjectSetPropertyData(id, &a, 0, nil, size, &free)
    }
}
#endif
