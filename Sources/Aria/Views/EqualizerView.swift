import SwiftUI

/// Ten-band equalizer: a preset shelf on top, a rack of vertical faders below.
struct EqualizerView: View {
    let palette: M3Palette
    var onDismiss: (() -> Void)? = nil

    @EnvironmentObject var player: AudioPlayer

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    presetShelf
                    faderRack
                    preampRow
                }
                .padding(.horizontal, screenInset)
                .padding(.top, 18)
                .padding(.bottom, 28)
            }
            .scrollContentBackground(.hidden)
        }
        .background(palette.surface)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            if let onDismiss {
                IconButton(system: "chevron.down", size: 38, glyph: 14,
                           fill: palette.surfaceContainer, foreground: palette.onSurface,
                           action: onDismiss)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Equalizer")
                    .font(.display(22, .semibold))
                    .foregroundStyle(palette.onSurface)
                Text(player.eqPresetName ?? "Custom")
                    .font(.body(11.5))
                    .foregroundStyle(palette.onSurfaceVariant)
            }

            Spacer()

            Toggle("", isOn: $player.eqEnabled)
                .labelsHidden()
                .tint(palette.primary)
        }
        .padding(.horizontal, screenInset)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    // MARK: Presets

    private var presetShelf: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("PRESETS")
                .font(.label(10.5, .semibold))
                .tracking(0.9)
                .foregroundStyle(palette.primary)

            // Two rows of chips that scroll sideways — 18 presets is too many
            // for one line on a phone.
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(0..<2, id: \.self) { row in
                        HStack(spacing: 8) {
                            ForEach(presetRow(row)) { preset in
                                FilterChip(title: preset.name,
                                           isSelected: player.eqPresetName == preset.name,
                                           palette: palette) {
                                    withAnimation(.snappy(duration: 0.25)) {
                                        player.apply(preset: preset)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func presetRow(_ row: Int) -> [EQPreset] {
        let half = (Equalizer.presets.count + 1) / 2
        return row == 0
            ? Array(Equalizer.presets.prefix(half))
            : Array(Equalizer.presets.suffix(from: half))
    }

    // MARK: Faders

    private var faderRack: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("BANDS")
                    .font(.label(10.5, .semibold))
                    .tracking(0.9)
                    .foregroundStyle(palette.primary)
                Spacer()
                Button("Reset") { withAnimation(.snappy(duration: 0.25)) { player.resetEQ() } }
                    .buttonStyle(PillButtonStyle(
                        kind: .text, palette: palette, size: 12,
                        padding: EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)))
            }

            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(Equalizer.frequencies.enumerated()), id: \.offset) { index, frequency in
                    BandFader(
                        gain: player.eqGains.indices.contains(index) ? player.eqGains[index] : 0,
                        label: Equalizer.label(for: frequency),
                        palette: palette,
                        enabled: player.eqEnabled
                    ) { player.setGain($0, forBand: index) }
                }
            }
            .frame(height: 210)
            .padding(.vertical, 10)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(palette.surfaceContainer))
            .opacity(player.eqEnabled ? 1 : 0.45)
        }
    }

    // MARK: Preamp

    private var preampRow: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("PREAMP")
                    .font(.label(10.5, .semibold))
                    .tracking(0.9)
                    .foregroundStyle(palette.primary)
                Spacer()
                Text(String(format: "%+.1f dB", player.eqPreamp))
                    .font(.ticker(11.5))
                    .foregroundStyle(palette.onSurfaceVariant)
            }

            Slider(value: $player.eqPreamp, in: -12...12, step: 0.5)
                .tint(palette.primary)
                .disabled(!player.eqEnabled)

            Text("Heavy boosts can clip. Pull the preamp down if loud passages distort.")
                .font(.body(11))
                .foregroundStyle(palette.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .fill(palette.surfaceContainer))
        .opacity(player.eqEnabled ? 1 : 0.45)
    }
}

/// One vertical fader: a track with the filled portion growing from the centre
/// line, so cuts and boosts read at a glance.
struct BandFader: View {
    let gain: Float
    let label: String
    let palette: M3Palette
    let enabled: Bool
    let onChange: (Float) -> Void

    private let range: Float = 12

    var body: some View {
        VStack(spacing: 6) {
            Text(String(format: "%+.0f", gain))
                .font(.ticker(9.5))
                .foregroundStyle(abs(gain) < 0.05 ? palette.onSurfaceVariant : palette.primary)

            GeometryReader { geo in
                let height = geo.size.height
                let mid = height / 2
                let fraction = CGFloat(gain / range)          // -1...1
                let knobY = mid - fraction * mid

                ZStack(alignment: .top) {
                    Capsule()
                        .fill(palette.onSurfaceVariant.opacity(0.22))
                        .frame(width: 5)
                        .frame(maxWidth: .infinity)

                    // Centre tick marks unity gain.
                    Rectangle()
                        .fill(palette.onSurfaceVariant.opacity(0.45))
                        .frame(height: 1)
                        .offset(y: mid)

                    // Filled span between centre and the knob.
                    Capsule()
                        .fill(palette.primary)
                        .frame(width: 5, height: abs(knobY - mid))
                        .offset(y: min(knobY, mid))
                        .frame(maxWidth: .infinity)

                    Capsule()
                        .fill(palette.primary)
                        .frame(width: 20, height: 11)
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                        .offset(y: knobY - 5.5)
                        .frame(maxWidth: .infinity)
                }
                .frame(width: geo.size.width, height: height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard enabled else { return }
                            let clamped = min(max(value.location.y, 0), height)
                            onChange(Float((mid - clamped) / mid) * range)
                        }
                )
            }

            Text(label)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(palette.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity)
    }
}
