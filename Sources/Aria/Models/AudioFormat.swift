import AudioToolbox
import Foundation

/// The containers Aria opens. Only FLAC is parsed by hand; everything else is
/// decoded by AVFoundation, but the *codec* still has to be named correctly:
/// an `.m4a` can hold either ALAC (lossless) or AAC (lossy), and only the first
/// may ever inherit a lossless or bit-perfect claim.
enum AudioFormat: String, Codable, Hashable, CaseIterable {
    case flac, alac, aac, mp3, wav, aiff, caf

    /// Extensions the scanner walks. Ogg, Opus, WMA, APE and DSD are absent on
    /// purpose: AVFoundation has no decoder for them, so listing them would only
    /// produce rows that fail the moment you press play.
    static let supportedExtensions: Set<String> = [
        "flac", "m4a", "m4b", "mp3", "wav", "aiff", "aif", "aifc", "caf", "aac",
    ]

    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Maps the decoded codec to a format. PCM has no useful codec identity, so
    /// WAV, AIFF and CAF are told apart by their file name.
    static func from(mediaSubType: AudioFormatID, url: URL) -> AudioFormat {
        switch mediaSubType {
        case kAudioFormatFLAC: return .flac
        case kAudioFormatAppleLossless: return .alac
        case kAudioFormatMPEGLayer3: return .mp3
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE,
             kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_LD,
             kAudioFormatMPEG4AAC_ELD:
            return .aac
        default: return inferred(from: url)
        }
    }

    /// Last resort for containers whose codec AVFoundation only calls "PCM",
    /// and for cache entries written before the codec was stored.
    static func inferred(from url: URL) -> AudioFormat {
        switch url.pathExtension.lowercased() {
        case "flac": return .flac
        case "mp3": return .mp3
        case "wav": return .wav
        case "aif", "aiff", "aifc": return .aiff
        case "caf": return .caf
        default: return .aac
        }
    }

    /// What the badges and the audio-chain panel print.
    var displayName: String {
        switch self {
        case .flac: return "FLAC"
        case .alac: return "ALAC"
        case .aac: return "AAC"
        case .mp3: return "MP3"
        case .wav: return "WAV"
        case .aiff: return "AIFF"
        case .caf: return "CAF"
        }
    }

    /// Uncompressed or losslessly compressed. Anything else is transcoded before
    /// it reaches the DAC, so it can never be bit-perfect.
    var isLossless: Bool {
        switch self {
        case .flac, .alac, .wav, .aiff, .caf: return true
        case .aac, .mp3: return false
        }
    }

    /// Human list for empty-state copy and error messages.
    static var readableList: String { "FLAC, ALAC, MP3, AAC, WAV or AIFF" }
}
