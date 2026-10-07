import SwiftUI

/// The screen the app opens on while it loads.
///
/// It's a graph seen through glass. Across the paper runs an outreach curve —
/// the shape the app exists to bend upward — and it draws itself as the launch
/// loads finish, so the line *is* the progress: a real fraction of the work
/// done, not a timer dressed up as one. A bead of glass rides the tip of the
/// line as it's drawn.
///
/// In the middle floats the app's mark as a Liquid Glass lens. It sits right on
/// the curve, so what you see through it is the graph, refracted and bent at its
/// rim — the glass isn't decoration laid over a flat background, it's a lens
/// with something to look at. Three glass droplets orbit it, one per launch
/// load, and as each load lands its droplet is drawn in and fuses with the lens.
/// They share a `GlassEffectContainer`, which is what makes that fusing a real
/// liquid merge — the surfaces neck and join — rather than two discs overlapping.
///
/// The theme sets the scene: its chart moves behind the curve, its mark floats
/// in the lens, its colours run through all of it, and its tagline sits under
/// the wordmark — so the first thing the app shows is already the look you
/// picked.
///
/// Everything continuous stops under Reduce Motion; the curve and the droplets
/// still follow progress, just without drifting.
struct SplashView: View {

    /// How much of the launch work is done, 0…1.
    let progress: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Phase { case waiting, landing, settled }
    @State private var phase: Phase = .waiting
    /// `progress`, eased, so each finished load draws its stretch of curve and
    /// pulls its droplet in over most of a second rather than snapping.
    @State private var shownProgress: Double = 0

    private static let wordmarkDelay: Duration = .milliseconds(260)

    var body: some View {
        let theme = ThemeStore.shared.current
        ZStack {
            ChartGround(intensity: 0.6)
                .ignoresSafeArea()

            GraphGlassScene(progress: shownProgress, mark: theme.mark,
                            isAnimated: !reduceMotion, isRevealed: phase != .waiting)

            VStack(spacing: 8) {
                Spacer()
                Text("Aurora")
                    .font(.display(34))
                    .foregroundStyle(.ink)
                    // Condenses out of a blur as it rises, the letters drawing
                    // together — the same gathering the lens does, in type.
                    .tracking(phase == .settled ? 0 : 7)
                    .blur(radius: phase == .settled ? 0 : 8)
                    .opacity(phase == .settled ? 1 : 0)
                    .offset(y: phase == .settled ? 0 : 12)
                Text(theme.tagline)
                    .font(.subheadline)
                    .foregroundStyle(.inkMuted)
                    .opacity(phase == .settled ? 1 : 0)
                    .blur(radius: phase == .settled ? 0 : 6)
            }
            .padding(.bottom, 96)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Aurora is loading")
        .accessibilityValue("\(Int((progress * 100).rounded())) percent")
        .onChange(of: progress, initial: true) { _, value in
            withAnimation(.smooth(duration: 0.9)) { shownProgress = value }
        }
        .task {
            // The engine is primed in `RootView.init`, so this first knock lands
            // on time rather than tens of milliseconds late.
            withAnimation(.spring(duration: 0.9, bounce: 0.3)) { phase = .landing }
            Haptics.lift(0.75)

            try? await Task.sleep(for: Self.wordmarkDelay)
            withAnimation(.smooth(duration: 0.8)) { phase = .settled }
        }
    }
}

// MARK: - Scene

/// The graph, the lens over it, and the droplets — one timeline drives them all
/// so the curve's drift and the glass stay in step.
///
/// `Animatable`, so an eased change to `progress` is interpolated frame by frame:
/// the curve extends and the droplets glide in rather than jumping.
private struct GraphGlassScene: View, Animatable {
    var progress: Double
    /// The theme's glyph, floating in the lens.
    let mark: String
    let isAnimated: Bool
    let isRevealed: Bool

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    private static let lensSide: CGFloat = 112
    private static let droplets = 3
    /// Where the lens sits, as a fraction of the height. The curve is shaped to
    /// pass through here, so the lens always has the line to refract.
    private static let lensY: CGFloat = 0.42

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            TimelineView(.animation(paused: !isAnimated)) { timeline in
                let time = isAnimated
                    ? timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3_600)
                    : 0
                let chart = Chart(size: size, time: time, lensY: Self.lensY)
                let drawnTo = 0.04 + 0.96 * progress

                ZStack {
                    chart.area(upTo: drawnTo)
                        .fill(LinearGradient(colors: [Color.clay.opacity(0.22), Color.clay.opacity(0)],
                                             startPoint: .top, endPoint: .bottom))
                        // Feathered at the leading edge, so the fill runs out
                        // like wet paint behind the tip instead of stopping at
                        // a hard vertical cut.
                        .mask {
                            LinearGradient(stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: max(0, drawnTo - 0.16)),
                                .init(color: .clear, location: drawnTo)
                            ], startPoint: .leading, endPoint: .trailing)
                        }
                    chart.line(upTo: 1, series: .baseline)
                        .stroke(Color.inkFaint.opacity(0.35),
                                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 5]))
                    chart.line(upTo: drawnTo, series: .main)
                        .stroke(Color.clay, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                    dataPoints(chart, drawnTo: drawnTo)

                    glass(size: size, time: time, chart: chart, drawnTo: drawnTo)
                }
                .opacity(isRevealed ? 1 : 0)
                .blur(radius: isRevealed ? 0 : 16)
                .scaleEffect(isRevealed ? 1 : 0.94)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    // MARK: Graph

    /// Markers along the drawn part of the curve, each popping in as the line
    /// reaches it.
    private func dataPoints(_ chart: Chart, drawnTo: Double) -> some View {
        ForEach(Chart.markers, id: \.self) { x in
            let reached = x <= drawnTo
            Circle()
                .fill(Color.paper)
                .stroke(Color.clay, lineWidth: 2)
                .frame(width: 9, height: 9)
                .scaleEffect(reached ? 1 : 0.01)
                .opacity(reached ? 1 : 0)
                .animation(Theme.Motion.pop, value: reached)
                .position(chart.point(at: x, series: .main))
        }
    }

    // MARK: Glass

    private func glass(size: CGSize, time: Double, chart: Chart, drawnTo: Double) -> some View {
        let center = CGPoint(x: size.width / 2, y: size.height * Self.lensY)
        let tip = chart.point(at: drawnTo, series: .main)
        let share = 1 / Double(Self.droplets)

        return ZStack {
            // The lens and its droplets share a container, so they merge as
            // liquid when they meet.
            GlassEffectContainer(spacing: 34) {
                ZStack {
                    ForEach(0..<Self.droplets, id: \.self) { index in
                        let i = Double(index)
                        // 0 while this droplet's load is outstanding, 1 once in.
                        let absorbed = min(max((progress - i * share) / share, 0), 1)
                        let pull = absorbed * absorbed * (3 - 2 * absorbed)
                        let angle = time * (0.6 + 0.2 * i) + i * (2 * .pi / 3)
                        let reach = (96 + 14 * sin(time * 0.9 + i * 2.1)) * (1 - pull)
                        let diameter = (38 + 4 * sin(time * 2 + i)) * (1 - 0.4 * pull)
                        Color.clear
                            .frame(width: diameter, height: diameter)
                            .glassEffect(.clear.tint(Color.clay.opacity(0.22)), in: .circle)
                            .offset(x: cos(angle) * reach, y: sin(angle) * reach * 0.85)
                    }

                    lens(time: time)
                }
                .position(center)
            }

            // The bead riding the tip of the line: a small lens scanning the
            // graph as it's drawn. Its own container — it should never fuse with
            // the mark on its way past.
            GlassEffectContainer {
                Color.clear
                    .frame(width: 30, height: 30)
                    .glassEffect(.clear.tint(Color.clay.opacity(0.12)), in: .circle)
            }
            .position(tip)
            .opacity(progress < 0.999 ? 1 : 0)
        }
    }

    /// The mark: a glass tile, tinted with the accent, with the theme's glyph
    /// floating in it.
    private func lens(time: Double) -> some View {
        Image(systemName: mark)
            .font(.system(size: 40, weight: .medium))
            .foregroundStyle(Color.clay)
            .rotationEffect(.degrees(-14 + 3 * sin(time * 1.3)))
            .offset(x: 1.5 * cos(time * 0.9), y: 2.5 * sin(time * 1.6))
            .frame(width: Self.lensSide, height: Self.lensSide)
            // Clear rather than regular glass: regular frosts what's behind it,
            // and the point of the lens is to show the graph, bent.
            .glassEffect(.clear.tint(Color.clay.opacity(0.12)).interactive(),
                         in: .rect(cornerRadius: 34, style: .continuous))
            .scaleEffect(1 + 0.025 * sin(time * 1.1))
    }
}

// MARK: - Chart geometry

/// The outreach curve: a rising line with a slow liquid drift, bent to pass
/// through the lens. Pure geometry, so the line, its fill, its markers and the
/// bead all agree on where the curve is.
private struct Chart {
    let size: CGSize
    let time: Double
    let lensY: CGFloat

    enum Series { case main, baseline }

    static let markers: [Double] = [0.14, 0.3, 0.5, 0.68, 0.86]

    /// The underlying rise with a plateau and a late climb — the shape of
    /// replies arriving.
    private static func rise(_ x: Double) -> Double {
        0.76 - 0.52 * x - 0.07 * sin(x * .pi * 2.2)
    }

    /// Height of the curve at `x` (0…1), as a fraction of the screen height.
    private func y(_ x: Double, series: Series) -> CGFloat {
        switch series {
        case .main:
            let ripple = 0.012 * sin(x * 9 + time * 1.4) + 0.006 * sin(x * 17 - time * 2.1)
            // Pull the middle of the curve onto the lens.
            let bend = (Double(lensY) - Self.rise(0.5)) * exp(-pow((x - 0.5) / 0.22, 2))
            return CGFloat(Self.rise(x) + ripple + bend)
        case .baseline:
            return CGFloat(0.7 - 0.12 * x + 0.008 * sin(x * 7 - time * 0.8))
        }
    }

    func point(at x: Double, series: Series) -> CGPoint {
        CGPoint(x: size.width * CGFloat(x), y: size.height * y(x, series: series))
    }

    func line(upTo end: Double, series: Series) -> Path {
        Path { path in
            let steps = 90
            let last = max(1, Int((Double(steps) * end).rounded(.up)))
            path.move(to: point(at: 0, series: series))
            for step in 1...last {
                path.addLine(to: point(at: min(Double(step) / Double(steps), end), series: series))
            }
        }
    }

    func area(upTo end: Double) -> Path {
        var path = line(upTo: end, series: .main)
        path.addLine(to: CGPoint(x: size.width * CGFloat(end), y: size.height))
        path.addLine(to: CGPoint(x: 0, y: size.height))
        path.closeSubpath()
        return path
    }
}

#Preview {
    @Previewable @State var progress = 0.0
    SplashView(progress: progress)
        .task {
            for step in 1...3 {
                try? await Task.sleep(for: .seconds(1.2))
                progress = Double(step) / 3
            }
        }
}
