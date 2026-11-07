import SwiftUI

// MARK: - Quality

/// The one thing the user actually wants to know at a glance: is anything in
/// the path changing the samples (or re-encoding them) before they reach the
/// output.
enum ChainQuality {
    case idle, maximum, unverified, shared, processed, lossyLink

    var label: String {
        switch self {
        case .idle: return "NO SIGNAL"
        case .maximum: return "BIT-PERFECT"
        case .unverified: return "UNVERIFIED"
        case .shared: return "STANDARD"
        case .processed: return "PROCESSED"
        case .lossyLink: return "LOSSY LINK"
        }
    }

    var profile: String {
        switch self {
        case .idle: return "Nothing playing"
        case .maximum: return "Maximum quality"
        case .unverified: return "Exclusive not confirmed"
        case .shared: return "Shared output"
        case .processed: return "Software processed"
        case .lossyLink: return "Re-encoded"
        }
    }

    var color: Color {
        switch self {
        case .idle: return Color(red: 0.58, green: 0.60, blue: 0.64)
        case .maximum: return Color(red: 0.27, green: 0.78, blue: 0.56)
        case .shared: return Color(red: 0.52, green: 0.68, blue: 0.88)
        case .unverified, .processed: return Color(red: 0.99, green: 0.68, blue: 0.29)
        case .lossyLink: return Color(red: 0.99, green: 0.45, blue: 0.45)
        }
    }

    var explanation: String {
        switch self {
        case .idle:
            return "Start playback to inspect the signal path."
        case .maximum:
            return "Exclusive access confirmed, and the device runs at the file's own rate and depth. No gain, EQ, resampling, mixing or re-encoding in the path."
        case .unverified:
            return "The device is running at the track's sample rate, but Aria could not confirm exclusive (hog) access. If another app plays, the macOS mixer will mix it in, so bit-perfect output is not guaranteed."
        case .shared:
            return "Audio goes through the system mixer alongside other apps. Even with a matching sample rate, shared output cannot be guaranteed bit-perfect — the mixer may resample or mix in other audio."
        case .processed:
            return "Something in the path is changing the samples. See the checklist below for exactly what to fix."
        case .lossyLink:
            return "Bluetooth or AirPlay re-encodes the stream before it reaches your headphones. Wired headphones or a USB-C DAC keep the full quality."
        }
    }
}

// MARK: - Snapshot

/// A point-in-time reading of source → processing → output. Built from the
/// real player state, never from hardcoded "audiophile" marketing copy.
struct AudioChain {
    let sourceFormat: String
    let sampleRate: Int
    let bitDepth: Int
    let channels: Int
    let bitrate: Int
    let gainDB: Float
    let eqEnabled: Bool
    let eqPreamp: Float
    let eqPreset: String?
    let outputName: String
    let outputSampleRate: Double
    let outputChannels: Int
    let outputIsLossy: Bool
    /// macOS Exclusive mode whose hog-mode ownership could not be confirmed.
    let exclusiveUnverified: Bool
    /// Exclusive access both requested and verified. iOS can never set this —
    /// AVAudioSession always routes through the system mixer.
    let isExclusiveConfirmed: Bool
    /// Physical bit depth reported by the output device (0 when unknown).
    let deviceBitDepth: Int
    /// Verified lossless/integer source, not just a filename assumption.
    let sourceIsLossless: Bool

    var hasTrack: Bool { sampleRate > 0 }

    var sourceRateText: String {
        hasTrack ? String(format: "%.1f kHz", Double(sampleRate) / 1000) : "—"
    }

    var outputRateText: String {
        outputSampleRate > 0 ? String(format: "%.1f kHz", outputSampleRate / 1000) : "—"
    }

    var channelText: String {
        switch channels {
        case 1: return L("Mono")
        case 2: return L("Stereo")
        default: return channels > 0 ? "\(channels) " + L("channels") : "—"
        }
    }

    var outputChannelText: String {
        switch outputChannels {
        case 1: return L("Mono")
        case 2: return L("Stereo")
        default: return outputChannels > 0 ? "\(outputChannels) " + L("ch") : "—"
        }
    }

    var sourceHeadline: String {
        guard hasTrack else { return L("No track loaded") }
        // Lossy codecs have no sample word length worth printing.
        return bitDepth > 0
            ? "\(sourceFormat) · \(sourceRateText) · \(bitDepth) " + L("bit")
            : "\(sourceFormat) · \(sourceRateText)"
    }

    var sourceDetail: String {
        guard hasTrack else { return L("Play a file to see its format here.") }
        var parts = [channelText]
        if bitrate > 0 { parts.append("\(bitrate) kbps") }
        parts.append(sourceIsLossless ? L("lossless") : L("lossy"))
        return parts.joined(separator: " · ")
    }

    /// Channel counts must match; a mono source rendered to stereo is the one
    /// harmless upmix (same convention RustMusic uses).
    var channelsMatch: Bool {
        channels == outputChannels || (channels == 1 && outputChannels == 2)
    }

    /// A source deeper than the device's physical format needs a conversion.
    var bitDepthFits: Bool {
        deviceBitDepth <= 0 || bitDepth <= 0 || bitDepth <= deviceBitDepth
    }

    var isResampled: Bool {
        hasTrack && outputSampleRate > 0 &&
            abs(outputSampleRate - Double(sampleRate)) > 1
    }

    var gainText: String {
        gainDB > -0.05 ? "0 dB" : String(format: "%.0f dB", gainDB)
    }

    var processingHeadline: String {
        guard hasTrack else { return L("Idle") }
        if gainDB < -0.05 {
            return LanguageSettings.shared.isChinese
                ? "已衰减 \(gainText)"
                : "Attenuated \(gainText)"
        }
        if eqEnabled || abs(eqPreamp) > 0.05 { return L("Equalizer active") }
        if isResampled { return L("Resampling") }
        return L("Untouched")
    }

    var processingDetail: String {
        guard hasTrack else { return L("No audio is running through the engine.") }
        var parts = [L("Software volume") + " " + gainText]
        parts.append(eqEnabled ? L("EQ on") + " (" + (eqPreset ?? L("Custom")) + ")" : L("EQ off"))
        parts.append(isResampled
                     ? L("Resampled") + " " + sourceRateText + " → " + outputRateText
                     : L("Sample rate matched"))
        return parts.joined(separator: " · ")
    }

    var outputDetail: String {
        var parts = [outputRateText, outputChannelText]
        parts.append(outputIsLossy ? L("Bluetooth/AirPlay re-encode") : L("CoreAudio"))
        parts.append(isExclusiveConfirmed ? L("Exclusive (hog)")
                     : exclusiveUnverified ? L("Exclusive unverified")
                     : L("Shared mixer"))
        return parts.joined(separator: " · ")
    }

    /// Ordered like RustMusic's pipelineMode(): the most severe break wins.
    /// Crucially, a shared backend is NOT bit-perfect even when every other
    /// number matches — the system mixer is still in the path.
    var quality: ChainQuality {
        guard hasTrack else { return .idle }
        if outputIsLossy { return .lossyLink }
        if gainDB < -0.05 || eqEnabled || abs(eqPreamp) > 0.05 || isResampled {
            return .processed
        }
        if !sourceIsLossless || !channelsMatch || !bitDepthFits { return .processed }
        if exclusiveUnverified { return .unverified }
        if !isExclusiveConfirmed { return .shared }
        return .maximum
    }

    /// Concrete, actionable reasons instead of one generic sentence. Mirrors
    /// the `Repli` fallback reasons and the "how to reach bit-perfect" guide.
    var improvementNotes: [String] {
        guard hasTrack, quality != .maximum else { return [] }
        var notes: [String] = []
        let zh = LanguageSettings.shared.isChinese
        if outputIsLossy {
            notes.append(L("Use wired headphones or a USB-C DAC — Bluetooth/AirPlay re-encodes the stream."))
        }
        if gainDB < -0.05 {
            notes.append(zh
                ? "将 Aria 的音量设为 0 dB（当前为 \(gainText)）。"
                : "Set Aria's volume to 0 dB (currently \(gainText)).")
        }
        if eqEnabled || abs(eqPreamp) > 0.05 {
            notes.append(L("Turn the equalizer off (and reset the preamp to 0 dB)."))
        }
        if isResampled {
            notes.append(zh
                ? "将设备时钟与 \(sourceRateText) 对齐——当前运行在 \(outputRateText)。"
                : "Match the device clock to \(sourceRateText) — it is running at \(outputRateText).")
        }
        if !sourceIsLossless {
            notes.append(L("Use a lossless file (FLAC/ALAC/WAV); this source is not lossless integer PCM."))
        }
        if !channelsMatch {
            notes.append(zh
                ? "声道布局不一致：源为 \(channelText)，输出为 \(outputChannelText)。"
                : "Channel layout differs: \(channelText) source → \(outputChannelText) output.")
        }
        if !bitDepthFits {
            notes.append(zh
                ? "文件的 \(bitDepth) 位深度超出了设备的 \(deviceBitDepth) 位格式。"
                : "The file's \(bitDepth)-bit depth exceeds the device's \(deviceBitDepth)-bit format.")
        }
        if !isExclusiveConfirmed {
            #if os(macOS)
            notes.append(L("Enable Exclusive output mode and confirm macOS grants hog access."))
            #else
            notes.append(L("iOS always routes audio through the system mixer; bit-perfect output isn't available on this platform."))
            #endif
        }
        return notes
    }
}

// MARK: - Panel

/// Shared by the desktop and phone players: a compact, honest read-out of the
/// whole playback path, in the app's own Material 3 surfaces.
struct AudioChainView: View {
    let palette: M3Palette
    var onDismiss: (() -> Void)? = nil

    @EnvironmentObject var player: AudioPlayer

    private var chain: AudioChain { player.audioChain }
    private var quality: ChainQuality { chain.quality }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(palette.outline.opacity(0.35))

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(L(quality.explanation))
                        .font(.body(13))
                        .foregroundStyle(palette.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 22)

                    node(system: "doc.fill", title: "Source",
                         headline: chain.sourceHeadline, detail: chain.sourceDetail)
                    connector
                    node(system: "slider.horizontal.3", title: "Processing",
                         headline: chain.processingHeadline, detail: chain.processingDetail)
                    connector
                    node(system: "speaker.wave.2.fill", title: "Output",
                         headline: chain.outputName, detail: chain.outputDetail)

                    Divider().overlay(palette.outline.opacity(0.35))
                        .padding(.top, 20)

                    HStack {
                        Text(L("Profile"))
                            .font(.body(12))
                            .foregroundStyle(palette.onSurfaceVariant)
                        Spacer()
                        Text(L(quality.profile))
                            .font(.display(15, .semibold))
                            .foregroundStyle(palette.onSurface)
                    }
                    .padding(.top, 14)

                    if !chain.improvementNotes.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L("TO REACH BIT-PERFECT"))
                                .font(.body(10.5, .bold))
                                .kerning(1.0)
                                .foregroundStyle(palette.onSurfaceVariant)
                            ForEach(chain.improvementNotes, id: \.self) { note in
                                HStack(alignment: .top, spacing: 8) {
                                    Circle()
                                        .fill(quality.color)
                                        .frame(width: 5, height: 5)
                                        .padding(.top, 5)
                                    Text(note)
                                        .font(.body(12))
                                        .foregroundStyle(palette.onSurfaceVariant)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(.top, 20)
                    }
                }
                .padding(22)
            }
            .scrollContentBackground(.hidden)
            // Soft bottom edge: the pinned footer cuts the read-out where it
            // ends, and a hard mid-line crop reads as a layout bug.
            .mask {
                VStack(spacing: 0) {
                    Color.white
                    LinearGradient(colors: [.white, .clear],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 16)
                }
            }

            #if os(macOS)
            // Pinned below the read-out: the two settings people actually
            // change while listening, without a trip to Settings. The scroll
            // view is greedy, so the footer needs to claim its height first.
            Divider().overlay(palette.outline.opacity(0.35))
            outputShortcuts
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            #endif
        }
        .background(palette.surface)
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let onDismiss {
                IconButton(system: "chevron.down", size: 38, glyph: 14,
                           fill: palette.surfaceContainer,
                           foreground: palette.onSurface,
                           action: onDismiss)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(L("Audio chain"))
                    .font(.display(22, .semibold))
                    .foregroundStyle(palette.onSurface)
                Text(L("Source → processing → output"))
                    .font(.body(11.5))
                    .foregroundStyle(palette.onSurfaceVariant)
            }

            Spacer()

            HStack(spacing: 6) {
                Circle().fill(quality.color).frame(width: 7, height: 7)
                Text(L(quality.label))
                    .font(.body(11, .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(quality.color)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Capsule().fill(quality.color.opacity(0.14)))
            .overlay(Capsule().stroke(quality.color.opacity(0.45), lineWidth: 1))
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private func node(system: String, title: String,
                      headline: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(palette.surfaceContainerHigh)
                    .frame(width: 38, height: 38)
                Image(systemName: system)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.onSurface)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(L(title))
                    .font(.body(10.5, .bold))
                    .kerning(1.1)
                    .foregroundStyle(palette.onSurfaceVariant)
                Text(headline)
                    .font(.display(17, .bold))
                    .foregroundStyle(palette.onSurface)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.body(12))
                    .foregroundStyle(palette.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    /// The thin line joining two nodes, centred under the 38pt icon above.
    private var connector: some View {
        Rectangle()
            .fill(palette.outline.opacity(0.55))
            .frame(width: 1, height: 24)
            .frame(width: 38)
    }

    #if os(macOS)
    // MARK: Quick output controls

    /// Two rows of chips: which device, and how it is driven. Both write
    /// straight through to the player, so the panel doubles as the fastest way
    /// to A/B a routing change while a track is playing.
    private var outputShortcuts: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                shortcutLabel("Output").padding(.top, 8)
                ChipFlow(spacing: 8, lineSpacing: 8) {
                    ForEach(player.outputDevices) { device in
                        chip(device.name,
                             symbol: device.symbol,
                             selected: isOutputSelected(device),
                             help: "\(device.name) — \(L(device.capability)), \(device.rateText)") {
                            // Re-selecting the active device would tear the
                            // render chain down for nothing — audible gap.
                            guard !isOutputSelected(device) else { return }
                            player.selectOutputDevice(uid: device.uid)
                        }
                    }
                }
            }

            HStack(alignment: .center, spacing: 10) {
                shortcutLabel("Mode")
                ChipFlow(spacing: 8, lineSpacing: 8) {
                    ForEach(OutputMode.allCases, id: \.self) { mode in
                        chip(L(mode.shortTitle),
                             selected: player.outputMode == mode,
                             help: L(mode.detail)) {
                            guard player.outputMode != mode else { return }
                            player.setOutputMode(mode)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private func isOutputSelected(_ device: AudioOutputDevice) -> Bool {
        player.selectedOutputUID == device.uid
            || (player.selectedOutputUID == nil && device.isDefault)
    }

    private func shortcutLabel(_ text: String) -> some View {
        Text(L(text))
            .font(.body(10, .bold))
            .kerning(1.0)
            .foregroundStyle(palette.onSurfaceVariant)
            .frame(width: 58, alignment: .leading)
    }

    /// Selected chips fill solid with the accent. A tinted container would
    /// vanish on greyscale artwork (the palette is derived from the cover, so
    /// a black-and-white sleeve gives a black-and-white UI), and the fill is
    /// the same treatment `PillButtonStyle(.filled)` already uses.
    private func chip(_ title: String, symbol: String? = nil, selected: Bool,
                      help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10.5, weight: .semibold))
                }
                Text(title)
                    .font(.body(12, selected ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? palette.onPrimary : palette.onSurface)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(selected ? palette.primary : palette.surfaceContainerHigh)
            )
            .overlay(
                Capsule().stroke(selected ? Color.clear : palette.outline.opacity(0.3),
                                 lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(ChipPressStyle())
        .help(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    #endif
}

#if os(macOS)
/// Left-to-right chip row that drops to a second line instead of clipping —
/// device names vary a lot in length, so a fixed HStack would truncate.
private struct ChipFlow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let limit = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = measure(view, limit: limit)
            if x > 0, x + size.width > limit {
                y += rowHeight + lineSpacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(widest, limit), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = measure(view, limit: bounds.width)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + lineSpacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }

    /// A single oversized name is squeezed to the row instead of overflowing.
    private func measure(_ view: LayoutSubview, limit: CGFloat) -> CGSize {
        let ideal = view.sizeThatFits(.unspecified)
        guard ideal.width > limit, limit.isFinite else { return ideal }
        return view.sizeThatFits(ProposedViewSize(width: limit, height: nil))
    }
}

private struct ChipPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.78 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.14), value: configuration.isPressed)
    }
}
#endif
