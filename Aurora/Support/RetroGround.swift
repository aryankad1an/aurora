import SwiftUI

/// The ground every screen stands on: the black paper under still film
/// grain, with one slow retro figure in the top corner, a seventies sun whose
/// slits drift down through it.
///
/// Faint on purpose: it's the room the app sits in, not something to watch.
/// Every instance is driven by the wall clock rather than its own start time,
/// so the ground under a screen and under the next one pushed over it are the
/// same frame: a push or a tab switch never shows a seam in the motion.
struct RetroGround: View {
    /// How strongly the sun shows.
    var intensity: Double = 1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.paper
            StripedSun(intensity: intensity, isAnimated: !reduceMotion)
            FilmGrain(boils: false)
                .opacity(0.5)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The sun in the corner, drawn each frame from the clock. Thirty frames a
/// second is plenty for a drift this slow.
private struct StripedSun: View {
    let intensity: Double
    let isAnimated: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isAnimated)) { timeline in
            // A fixed moment when paused, so Reduce Motion gets a still sun.
            let time = isAnimated ? timeline.date.timeIntervalSinceReferenceDate : 0
            Canvas { context, size in
                let radius = size.width * 0.46
                let center = CGPoint(x: size.width * 0.9, y: radius * 0.42)
                RetroSun.draw(in: &context, center: center, radius: radius, time: time,
                              opacity: 0.09 * intensity)
            }
        }
    }
}

/// A seventies sun: a disc banded mustard to rust from the top down, cut by
/// slits that thicken toward its foot and drift slowly downward. The ground's
/// figure, and the splash's.
enum RetroSun {
    /// How far apart the slits are, as a share of the radius.
    static let slitSpacing = 0.14

    /// `foot`: where the bands end and the slits are thickest; the bottom of
    /// the disc unless a horizon cuts it off higher.
    static func draw(in context: inout GraphicsContext, center: CGPoint, radius: CGFloat,
                     time: Double, opacity: Double, slitsFrom: Double = 0.1, foot: CGFloat? = nil) {
        let foot = foot ?? center.y + radius
        let top = center.y - radius
        let disc = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                          width: radius * 2, height: radius * 2))
        // In a layer of its own, so the slits can be cut clean through to
        // whatever is behind the sun.
        context.drawLayer { sun in
            sun.clip(to: disc)

            // The colour, in four bands from the top to the foot.
            let band = (foot - top) / CGFloat(Palette.stripes.count)
            for (index, colour) in Palette.stripes.enumerated() {
                sun.fill(Path(CGRect(x: center.x - radius, y: top + CGFloat(index) * band,
                                     width: radius * 2, height: band + 1)),
                         with: .color(colour.opacity(opacity)))
            }

            // The slits. They start a little below the top and thicken toward
            // the foot as they drift down.
            sun.blendMode = .destinationOut
            let spacing = radius * slitSpacing
            let phase = CGFloat((time * 7).truncatingRemainder(dividingBy: Double(spacing)))
            let from = top + (foot - top) * slitsFrom
            var y = from - spacing + phase
            while y < foot {
                let depth = max(0, (y - from) / (foot - from))
                let thickness = 1 + spacing * 0.55 * depth
                if y + thickness > from {
                    let start = max(y, from)
                    sun.fill(Path(CGRect(x: center.x - radius, y: start, width: radius * 2,
                                         height: y + thickness - start)),
                             with: .color(.black))
                }
                y += spacing
            }
        }
    }
}
