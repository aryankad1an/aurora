import SwiftUI

/// The screen the app opens on while it loads, as a seventies ident.
///
/// A striped sun rises over a hairline horizon, its slits drifting down
/// through it, and under the horizon four stripes (mustard, orange, vermilion,
/// rust) run out from the left edge as the launch loads finish, so the stripes
/// *are* the progress: a real fraction of the work done, not a timer dressed up
/// as one. The wordmark rises out of its own baseline once the sun is up, and
/// film grain boils over all of it. It leaves by lifting off the top, like the
/// app's curtains.
///
/// Under Reduce Motion the sun is simply up and still; the stripes still
/// follow progress.
struct SplashView: View {

    /// How much of the launch work is done, 0…1.
    let progress: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far the sun has risen, 0…1.
    @State private var rise: Double = 0
    @State private var titled = false
    /// `progress`, eased, so each finished load runs its stretch of stripe out
    /// over most of a second rather than snapping.
    @State private var shownProgress: Double = 0
    /// Set after a long wait, so a slow connection says so instead of leaving a
    /// splash that looks frozen for as long as the request takes to time out.
    @State private var isSlow = false

    var body: some View {
        ZStack {
            Color.paper.ignoresSafeArea()
            RadialGradient(colors: [Color.clay.opacity(0.16), .clear],
                           center: UnitPoint(x: 0.5, y: 0.42), startRadius: 0, endRadius: 360)
                .ignoresSafeArea()

            RetroIdent(rise: rise, progress: shownProgress, isAnimated: !reduceMotion)
                .ignoresSafeArea()

            VStack(spacing: 8) {
                Spacer()
                Text("Aurora")
                    .font(.display(36))
                    .foregroundStyle(.ink)
                    // Rises out of its own baseline, as titles do in motion graphics.
                    .offset(y: titled ? 0 : 52)
                    .clipped()
                Text("Charting your outreach")
                    .font(.subheadline)
                    .foregroundStyle(.inkMuted)
                    .opacity(titled ? 1 : 0)
                    .offset(y: titled ? 0 : 8)
            }
            .padding(.bottom, 96)
            // An overlay, so the wordmark and tagline stay exactly where they were
            // and the hint arrives beneath them without moving anything.
            .overlay(alignment: .bottom) {
                Text("Taking longer than usual — check your connection")
                    .font(.footnote)
                    .foregroundStyle(.inkFaint)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 44)
                    .opacity(isSlow ? 1 : 0)
                    .animation(.easeInOut(duration: 0.6), value: isSlow)
            }

            FilmGrain().ignoresSafeArea()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Aurora is loading")
        .accessibilityValue("\(Int((progress * 100).rounded())) percent")
        .onChange(of: progress, initial: true) { _, value in
            withAnimation(.timingCurve(0.3, 0, 0.2, 1, duration: 0.8)) { shownProgress = value }
        }
        .task {
            if reduceMotion {
                rise = 1
                titled = true
            } else {
                // The engine is primed in `RootView.init`, so this first knock lands
                // on time rather than tens of milliseconds late.
                Haptics.lift(0.75)
                withAnimation(.timingCurve(0.2, 0.9, 0.3, 1, duration: 1.1)) { rise = 1 }
                try? await Task.sleep(for: .milliseconds(320))
                withAnimation(.timingCurve(0.2, 0.9, 0.3, 1, duration: 0.6)) { titled = true }
            }
            try? await Task.sleep(for: .seconds(10))
            isSlow = true
        }
    }
}

/// The sun, the horizon and the stripes. `Animatable`, so an eased change to
/// `rise` or `progress` is interpolated frame by frame; one timeline drives
/// the slits' drift.
private struct RetroIdent: View, Animatable {
    var rise: Double
    var progress: Double
    let isAnimated: Bool

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(rise, progress) }
        set { rise = newValue.first; progress = newValue.second }
    }

    private static let stripeHeight: CGFloat = 7
    private static let stripeGap: CGFloat = 5

    var body: some View {
        TimelineView(.animation(paused: !isAnimated)) { timeline in
            let time = isAnimated ? timeline.date.timeIntervalSinceReferenceDate : 0
            Canvas { context, size in
                let horizonY = size.height * 0.46
                let radius = min(size.width * 0.34, 150)
                let center = CGPoint(x: size.width / 2, y: horizonY + radius * (1.08 - rise))

                // The sun, only above the horizon.
                var sky = context
                sky.clip(to: Path(CGRect(x: 0, y: 0, width: size.width, height: horizonY)))
                RetroSun.draw(in: &sky, center: center, radius: radius, time: time, opacity: 1,
                              slitsFrom: 0.3, foot: horizonY)

                // The horizon.
                var line = Path()
                line.move(to: CGPoint(x: 28, y: horizonY))
                line.addLine(to: CGPoint(x: size.width - 28, y: horizonY))
                context.stroke(line, with: .color(Color.inkFaint.opacity(0.8 * rise)), lineWidth: 1)

                // The stripes, running out from the left edge with the launch.
                for (index, colour) in Palette.stripes.enumerated() {
                    // Each starts a little behind the one above, and all four
                    // reach the far edge together.
                    let lag = Double(index) * 0.06
                    let share = min(max((progress - lag) / (1 - lag), 0), 1)
                    guard share > 0 else { continue }
                    let y = horizonY + 18 + CGFloat(index) * (Self.stripeHeight + Self.stripeGap)
                    let width = (size.width + Self.stripeHeight) * share
                    context.fill(Path(roundedRect: CGRect(x: -Self.stripeHeight, y: y, width: width,
                                                          height: Self.stripeHeight),
                                      cornerRadius: Self.stripeHeight / 2),
                                 with: .color(colour))
                }
            }
        }
    }
}
