import Foundation

/// A named set of gains, one per band, in decibels.
struct EQPreset: Identifiable, Equatable {
    var name: String
    var gains: [Float]

    var id: String { name }
    var isFlat: Bool { gains.allSatisfy { abs($0) < 0.05 } }
}

enum Equalizer {
    /// Winamp's original band centres. Using them verbatim means the shipped
    /// presets are exactly as designed — no resampling onto other frequencies.
    static let frequencies: [Float] = [70, 180, 320, 600, 1000, 3000, 6000, 12000, 14000, 16000]

    static var bandCount: Int { frequencies.count }

    /// Winamp's own 18 presets, converted from its 0...63 storage (33 = unity,
    /// +/-20 dB span) to decibels.
    static let presets: [EQPreset] = [
        EQPreset(name: "Flat", gains: [  0.0,   0.0,   0.0,   0.0,   0.0,   0.0,   0.0,   0.0,   0.0,   0.0]),
        EQPreset(name: "Rock", gains: [  7.7,   4.5,  -6.5,  -9.0,  -4.5,   3.9,   9.0,  11.0,  11.0,  11.0]),
        EQPreset(name: "Pop", gains: [ -2.6,   4.5,   7.1,   7.7,   5.2,  -1.9,  -3.2,  -3.2,  -2.6,  -2.6]),
        EQPreset(name: "Dance", gains: [  9.7,   7.1,   1.9,  -0.6,  -0.6,  -7.1,  -8.4,  -8.4,  -0.6,  -0.6]),
        EQPreset(name: "Techno", gains: [  7.7,   5.8,   0.0,  -6.5,  -5.8,   0.0,   7.7,   9.7,   9.7,   9.0]),
        EQPreset(name: "Club", gains: [  0.0,   0.0,   3.2,   5.8,   5.8,   5.8,   3.2,   0.0,   0.0,   0.0]),
        EQPreset(name: "Party", gains: [  7.1,   7.1,   0.0,   0.0,   0.0,   0.0,   0.0,   0.0,   7.1,   7.1]),
        EQPreset(name: "Live", gains: [ -5.8,   0.0,   3.9,   5.2,   5.8,   5.8,   3.9,   2.6,   2.6,   1.9]),
        EQPreset(name: "Ska", gains: [ -3.2,  -5.8,  -5.2,  -1.3,   3.9,   5.8,   9.0,   9.7,  11.0,   9.7]),
        EQPreset(name: "Reggae", gains: [  0.0,   0.0,  -1.3,  -7.1,   0.0,   6.5,   6.5,   0.0,   0.0,   0.0]),
        EQPreset(name: "Soft", gains: [  4.5,   1.3,  -1.9,  -3.2,  -1.9,   3.9,   8.4,   9.7,  11.0,  12.3]),
        EQPreset(name: "Soft Rock", gains: [  3.9,   3.9,   1.9,  -1.3,  -5.2,  -6.5,  -4.5,  -1.3,   2.6,   9.0]),
        EQPreset(name: "Classical", gains: [  0.0,   0.0,   0.0,   0.0,   0.0,   0.0,  -8.4,  -8.4,  -8.4, -11.0]),
        EQPreset(name: "Large Hall", gains: [ 10.3,  10.3,   5.8,   5.8,   0.0,  -5.8,  -5.8,  -5.8,   0.0,   0.0]),
        EQPreset(name: "Full Bass", gains: [  9.7,   9.7,   9.7,   5.8,   1.3,  -5.2,  -9.7, -11.6, -12.3, -12.3]),
        EQPreset(name: "Bass & Treble", gains: [  7.1,   5.8,   0.0,  -8.4,  -5.8,   1.3,   8.4,  11.0,  12.3,  12.3]),
        EQPreset(name: "Full Treble", gains: [-11.0, -11.0, -11.0,  -5.2,   2.6,  11.0,  16.1,  16.1,  16.1,  17.4]),
        EQPreset(name: "Laptop / Headphones", gains: [  4.5,  11.0,   5.2,  -4.5,  -3.2,   1.3,   4.5,   9.7,  12.9,  14.8]),
    ]

    static let flat = presets[0]

    static func preset(named name: String) -> EQPreset? {
        presets.first { $0.name == name }
    }

    /// Short label for a band, e.g. "180" or "12k".
    static func label(for frequency: Float) -> String {
        frequency >= 1000
            ? "\(Int(frequency / 1000))k"
            : "\(Int(frequency))"
    }
}
