import SwiftUI

/// A progress control with a little character standing on the track, dancing
/// where the playhead is. Drag it to scrub.
///
/// Like the wave it replaces, the animation only runs while playing — a paused
/// `TimelineView(.animation)` would redraw at display rate forever for nothing.
struct MascotScrubber: View {
    var progress: Double                 // 0...1
    var isAnimating: Bool
    var height: CGFloat = 46
    var mascotSize: CGFloat = 30
    var trackWidth: CGFloat = 4
    var activeColor: Color
    var inactiveColor: Color
    /// Pupils and mouth — must contrast with `activeColor`.
    var inkColor: Color
    var onScrub: ((Double) -> Void)?
    var onCommit: ((Double) -> Void)?

    @State private var dragFraction: Double?

    private var shown: Double {
        min(max(dragFraction ?? progress, 0), 1)
    }

    var body: some View {
        GeometryReader { geo in
            // Inset by half the mascot so it never hangs off either end.
            let inset = mascotSize / 2
            let usable = max(geo.size.width - inset * 2, 1)

            Group {
                if isAnimating {
                    TimelineView(.animation) { timeline in
                        stage(size: geo.size, inset: inset, usable: usable,
                              phase: timeline.date.timeIntervalSinceReferenceDate)
                    }
                } else {
                    stage(size: geo.size, inset: inset, usable: usable, phase: 0)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = min(max((value.location.x - inset) / usable, 0), 1)
                        dragFraction = fraction
                        onScrub?(fraction)
                    }
                    .onEnded { _ in
                        if let fraction = dragFraction { onCommit?(fraction) }
                        dragFraction = nil
                    }
            )
        }
        .frame(height: height)
    }

    private func stage(size: CGSize, inset: CGFloat, usable: CGFloat, phase: Double) -> some View {
        // The character stands on the rail, so the rail hugs the bottom.
        let railTop = size.height - trackWidth
        let x = inset + usable * shown

        return ZStack(alignment: .topLeading) {
            Capsule()
                .fill(inactiveColor)
                .frame(width: usable, height: trackWidth)
                .offset(x: inset, y: railTop)

            Capsule()
                .fill(activeColor)
                .frame(width: max(usable * shown, trackWidth), height: trackWidth)
                .offset(x: inset, y: railTop)

            // Mascot art puts the feet on its own bottom edge, so sitting the
            // frame directly on the rail plants it.
            Mascot(phase: phase, isDancing: isAnimating, size: mascotSize,
                   fill: activeColor, ink: inkColor)
                .frame(width: mascotSize, height: mascotSize)
                .offset(x: x - mascotSize / 2, y: railTop - mascotSize + 3)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

/// The character: a round head in headphones on two legs. It bounces, tilts,
/// swings its arms and steps on the beat — and dozes off when the music stops.
///
/// Two things this drawing has to get right. Every limb is drawn *outside* the
/// head outline, because body and limbs share one fill and anything tucked
/// inside simply vanishes. And the floating notes go in an `.overlay`, since as
/// ZStack children their reach would inflate the bounds and shove the character
/// off the rail it is supposed to be standing on.
struct Mascot: View {
    var phase: Double
    var isDancing: Bool
    var size: CGFloat
    var fill: Color
    var ink: Color

    /// Roughly two bounces a second.
    private var t: Double { phase * 6.6 }
    private var beat: Double { isDancing ? sin(t) : 0 }
    /// 0 at the top of the hop, 1 on landing — drives the squash.
    private var landing: Double { isDancing ? 1 - abs(sin(t)) : 0 }

    /// Headphones and arms turn to mush below this; the mini player gets the
    /// simplified read.
    private var detailed: Bool { size >= 26 }

    private var blinking: Bool {
        guard isDancing else { return false }
        return (phase * 0.4 + 0.37).truncatingRemainder(dividingBy: 1) < 0.05
    }

    // Geometry, relative to `size`, measured from the frame centre.
    // The head spans -0.44…+0.12 and the legs run from there to +0.50, so the
    // feet land exactly on the frame's bottom edge.
    private var headRadius: CGFloat { size * 0.28 }
    private var headY: CGFloat { -size * 0.16 }

    var body: some View {
        character
            .overlay { isDancing ? AnyView(notes) : AnyView(snooze) }
            .frame(width: size, height: size)
    }

    private var character: some View {
        ZStack {
            if detailed { arms }
            legs
            if detailed { headphones }
            head
            face
        }
        // Pin the bounds before transforming, so the feet stay put.
        .frame(width: size, height: size)
        .rotationEffect(.degrees(beat * 7), anchor: .bottom)
        .scaleEffect(x: 1 + landing * 0.11, y: 1 - landing * 0.11, anchor: .bottom)
        .offset(y: isDancing ? -abs(sin(t)) * size * 0.06 : 0)
    }

    // MARK: Parts

    private var head: some View {
        Circle()
            .fill(fill)
            .frame(width: headRadius * 2, height: headRadius * 2)
            .offset(y: headY)
    }

    /// Band over the crown with a cup each side, both clear of the head edge.
    private var headphones: some View {
        ZStack {
            Circle()
                .trim(from: 0.57, to: 0.93)
                .stroke(fill, style: StrokeStyle(lineWidth: size * 0.06, lineCap: .round))
                .frame(width: size * 0.66, height: size * 0.66)
                .offset(y: headY)

            ForEach([-1.0, 1.0], id: \.self) { side in
                Capsule()
                    .fill(fill)
                    .frame(width: size * 0.10, height: size * 0.18)
                    .offset(x: headRadius * 1.10 * side, y: headY)
            }
        }
    }

    private var face: some View {
        VStack(spacing: size * 0.03) {
            HStack(spacing: size * 0.095) {
                eye
                eye
            }
            mouth
        }
        .offset(y: headY + size * 0.02)
    }

    @ViewBuilder
    private var eye: some View {
        if blinking || !isDancing {
            // Closed: a lid line reads far better than a squashed circle.
            Capsule()
                .fill(ink)
                .frame(width: size * 0.14, height: size * 0.042)
        } else {
            ZStack {
                Circle()
                    .fill(.white)
                    .frame(width: size * 0.16, height: size * 0.16)
                Circle()
                    .fill(ink)
                    .frame(width: size * 0.08, height: size * 0.08)
                    // Pupils lead the direction of the bounce.
                    .offset(x: beat * size * 0.026, y: size * 0.012)
            }
        }
    }

    @ViewBuilder
    private var mouth: some View {
        if isDancing {
            // Singing along — the mouth opens and shuts on the beat.
            Ellipse()
                .fill(ink)
                .frame(width: size * 0.12, height: size * (0.045 + 0.075 * abs(beat)))
        } else {
            Capsule()
                .fill(ink)
                .frame(width: size * 0.12, height: size * 0.035)
        }
    }

    /// Pivoted at the shoulder and swung outward, well clear of the head.
    /// Negative rotation carries the right arm away from the body; `side`
    /// mirrors it for the left.
    private var arms: some View {
        ForEach([-1.0, 1.0], id: \.self) { side in
            let length = size * 0.25
            let swing = -(isDancing ? 34 + beat * 40 : 24) * side
            Capsule()
                .fill(fill)
                .frame(width: size * 0.085, height: length)
                .rotationEffect(.degrees(swing), anchor: .top)
                // Offset carries the anchor, so this lands the pivot on the shoulder.
                .offset(x: headRadius * 0.90 * side, y: headY + length / 2)
        }
    }

    /// Long enough to read as legs, alternating so it steps rather than hops.
    private var legs: some View {
        ForEach([-1.0, 1.0], id: \.self) { side in
            let lift = isDancing ? max(0, sin(t) * side) * size * 0.06 : 0
            Capsule()
                .fill(fill)
                .frame(width: size * 0.09, height: size * 0.42)
                // Centre 0.29 + half-height 0.21 puts the foot on the frame edge.
                .offset(x: size * 0.11 * side, y: size * 0.29 - lift)
        }
    }

    /// Notes drifting up while the music plays.
    private var notes: some View {
        ForEach(0..<2, id: \.self) { i in
            let cycle = (phase * 0.6 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
            Image(systemName: i == 0 ? "music.note" : "music.quarternote.3")
                .font(.system(size: size * 0.22, weight: .bold))
                .foregroundStyle(fill)
                .opacity((1 - cycle) * 0.8)
                .scaleEffect(0.55 + cycle * 0.45)
                .offset(x: size * (0.44 + Double(i) * 0.17),
                        y: -size * (0.26 + cycle * 0.45))
        }
    }

    private var snooze: some View {
        Text("z")
            .font(.system(size: size * 0.24, weight: .heavy, design: .rounded))
            .foregroundStyle(fill.opacity(0.8))
            .offset(x: size * 0.34, y: -size * 0.40)
    }
}
