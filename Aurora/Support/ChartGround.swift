import SwiftUI
import UIKit

/// The ground every screen stands on: the theme's paper, ruled as graph paper,
/// with the theme's chart moving slowly across it.
///
/// The chart is faint on purpose — it's the room the app sits in, not something
/// to read — and every instance is driven by the wall clock rather than by its
/// own start time, so the ground under a screen and under the next one pushed
/// over it are the same frame of the same chart: a push or a tab switch never
/// shows a seam in the motion.
///
/// A theme change cross-fades the whole ground: the old chart dissolves as the
/// new one surfaces, under colours that are blending at the same time.
struct ChartGround: View {
    /// A specific theme (a preview card in Settings); nil follows the app's.
    var theme: AppTheme?
    /// How strongly the chart shows. The splash runs it brighter than a screen.
    var intensity: Double = 1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let theme = theme ?? ThemeStore.shared.current
        ZStack {
            ZStack {
                theme.palette.paper
                GraphPaper(theme: theme)
                ChartMotion(theme: theme, intensity: intensity, isAnimated: !reduceMotion)
            }
            .id(theme.id)
            .transition(.opacity)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Graph paper: faint rules on a square grid, every fourth one a shade
/// stronger, like the axis grid of a chart.
///
/// A single 4×4-cell tile per theme, rendered once and repeated by the GPU. It
/// used to be a full-screen `Canvas`, which is re-drawn whenever the screen
/// above it is — including under every menu and sheet as it animated.
struct GraphPaper: View {
    var theme: AppTheme?

    var body: some View {
        Image(uiImage: Self.tile(for: theme ?? ThemeStore.shared.current))
            .resizable(resizingMode: .tile)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private static let spacing: CGFloat = 22
    /// One repeat of the pattern, for anything that has to line up with it.
    static let tileSide: CGFloat = spacing * 4

    private static var tiles: [AppTheme.ID: UIImage] = [:]

    private static func tile(for theme: AppTheme) -> UIImage {
        if let tile = tiles[theme.id] { return tile }
        let side = tileSide
        let major = UIColor(theme.palette.hairline).withAlphaComponent(0.55).cgColor
        let minor = UIColor(theme.palette.grid).cgColor
        let tile = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            let cg = context.cgContext
            cg.setLineWidth(0.5)
            for index in 0..<4 {
                let offset = CGFloat(index) * spacing + 0.25
                cg.setStrokeColor(index == 0 ? major : minor)
                cg.move(to: CGPoint(x: offset, y: 0)); cg.addLine(to: CGPoint(x: offset, y: side))
                cg.move(to: CGPoint(x: 0, y: offset)); cg.addLine(to: CGPoint(x: side, y: offset))
                cg.strokePath()
            }
        }
        tiles[theme.id] = tile
        return tile
    }
}

// MARK: - The moving chart

/// The theme's chart, drawn each frame from the clock. Thirty frames a second
/// is plenty for motion this slow, and half the work of sixty.
struct ChartMotion: View {
    let theme: AppTheme
    var intensity: Double = 1
    var isAnimated = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isAnimated)) { timeline in
            // A fixed moment when paused, so Reduce Motion gets a still chart
            // rather than whatever frame it happened to stop on.
            let time = isAnimated ? timeline.date.timeIntervalSinceReferenceDate : 120
            Canvas { context, size in
                var painter = ChartPainter(context: context, size: size, time: time,
                                           palette: theme.palette, intensity: intensity)
                painter.draw(theme.motion)
            }
        }
    }
}

/// Draws one frame of a theme's chart. Pure functions of the clock and the
/// size, so every instance agrees.
private struct ChartPainter {
    var context: GraphicsContext
    let size: CGSize
    let time: Double
    let palette: ThemePalette
    let intensity: Double

    private var w: CGFloat { size.width }
    private var h: CGFloat { size.height }

    mutating func draw(_ motion: AppTheme.Motion) {
        switch motion {
        case .lines: lines()
        case .waves: waves()
        case .candles: candles()
        case .neon: neon()
        case .scatter: scatter()
        case .radar: radar()
        }
    }

    private func a(_ alpha: Double) -> Double { min(1, alpha * intensity) }

    /// A smooth, endlessly varying signal: a few incommensurate sines.
    private func signal(_ x: Double, seed: Double, speed: Double = 1) -> Double {
        let t = time * speed
        return sin(x * 5.1 + t * 0.31 + seed) * 0.5
            + sin(x * 9.7 - t * 0.47 + seed * 1.7) * 0.28
            + sin(x * 17.3 + t * 0.83 + seed * 2.9) * 0.12
    }

    private func path(steps: Int = 80, _ y: (Double) -> CGFloat) -> Path {
        Path { path in
            for step in 0...steps {
                let x = Double(step) / Double(steps)
                let point = CGPoint(x: w * CGFloat(x), y: y(x))
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
    }

    private func glow(_ path: Path, _ color: Color, width: CGFloat, radius: CGFloat) {
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: radius))
            layer.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width * 2.5, lineCap: .round))
        }
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

    // MARK: Lines — Aurora

    private func lines() {
        func main(_ x: Double) -> CGFloat { h * CGFloat(0.66 - 0.26 * x + 0.07 * signal(x, seed: 0)) }
        func second(_ x: Double) -> CGFloat { h * CGFloat(0.74 - 0.12 * x + 0.06 * signal(x, seed: 4, speed: 0.8)) }
        func third(_ x: Double) -> CGFloat { h * CGFloat(0.5 + 0.05 * signal(x, seed: 9, speed: 0.6)) }

        let line = path(main)
        var area = line
        area.addLine(to: CGPoint(x: w, y: h)); area.addLine(to: CGPoint(x: 0, y: h)); area.closeSubpath()
        context.fill(area, with: .linearGradient(
            Gradient(colors: [palette.accent.opacity(a(0.10)), palette.accent.opacity(0)]),
            startPoint: CGPoint(x: 0, y: h * 0.35), endPoint: CGPoint(x: 0, y: h)))

        context.stroke(path(third), with: .color(palette.inkFaint.opacity(a(0.35))),
                       style: StrokeStyle(lineWidth: 1, dash: [2, 6]))
        context.stroke(path(second), with: .color(palette.waiting.opacity(a(0.22))), lineWidth: 1.2)
        glow(line, palette.accent.opacity(a(0.34)), width: 1.6, radius: 5)

        // The cursor sweeping the chart, with its reading on the line.
        let x = (time * 0.035).truncatingRemainder(dividingBy: 1.2) - 0.1
        let point = CGPoint(x: w * CGFloat(x), y: main(x))
        var cursor = Path()
        cursor.move(to: CGPoint(x: point.x, y: 0)); cursor.addLine(to: CGPoint(x: point.x, y: h))
        context.stroke(cursor, with: .color(palette.accent.opacity(a(0.14))),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
        dot(at: point, radius: 3.5, color: palette.accent.opacity(a(0.7)))
    }

    private func dot(at point: CGPoint, radius: CGFloat, color: Color) {
        let halo = Path(ellipseIn: CGRect(x: point.x - radius * 3, y: point.y - radius * 3,
                                          width: radius * 6, height: radius * 6))
        context.fill(halo, with: .radialGradient(Gradient(colors: [color.opacity(0.5), color.opacity(0)]),
                                                 center: point, startRadius: 0, endRadius: radius * 3))
        context.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                                            width: radius * 2, height: radius * 2)), with: .color(color))
    }

    // MARK: Waves — Tide

    private func waves() {
        for band in 0..<3 {
            let b = Double(band)
            let base = 0.58 + 0.09 * b
            let speed = 0.05 + 0.025 * b
            let crest = path { x in
                let phase = x * (1.6 + 0.4 * b) + time * speed * 2 * .pi
                return h * CGFloat(base + 0.035 * sin(phase) + 0.015 * sin(phase * 2.3 + b))
            }
            var body = crest
            body.addLine(to: CGPoint(x: w, y: h)); body.addLine(to: CGPoint(x: 0, y: h)); body.closeSubpath()
            context.fill(body, with: .linearGradient(
                Gradient(colors: [palette.accent.opacity(a(0.11 - 0.025 * b)), palette.accent.opacity(a(0.02))]),
                startPoint: CGPoint(x: 0, y: h * CGFloat(base - 0.05)), endPoint: CGPoint(x: 0, y: h)))
            if band == 0 {
                glow(crest, palette.accent.opacity(a(0.32)), width: 1.4, radius: 4)
            } else {
                context.stroke(crest, with: .color(palette.accent.opacity(a(0.16))), lineWidth: 1)
            }
        }
        // A tide line overhead: the reply rate, drifting.
        context.stroke(path { x in h * CGFloat(0.34 + 0.05 * signal(x, seed: 2, speed: 0.6)) },
                       with: .color(palette.reply.opacity(a(0.2))), style: StrokeStyle(lineWidth: 1.2, dash: [4, 6]))
        // Bubbles rising off the crest.
        for index in 0..<14 {
            let i = Double(index)
            let rise = (time * (0.02 + 0.006 * hash(i)) + hash(i * 3.1)).truncatingRemainder(dividingBy: 1)
            let x = w * CGFloat(hash(i * 7.3)) + 8 * CGFloat(sin(time * 0.7 + i))
            let y = h * CGFloat(0.62 - 0.45 * rise)
            let r = CGFloat(1.5 + 2.5 * hash(i * 1.9))
            context.stroke(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                           with: .color(palette.accent.opacity(a(0.28 * (1 - rise)))), lineWidth: 0.8)
        }
    }

    // MARK: Candles — Phosphor

    private func candles() {
        let spacing: CGFloat = 16
        let scroll = CGFloat(time * 10)
        let first = Int(floor(scroll / spacing))
        let count = Int(w / spacing) + 3
        func value(_ n: Double) -> Double {
            0.55 - 0.05 * sin(n * 0.11) - 0.04 * sin(n * 0.037 + 1) - 0.02 * sin(n * 0.53)
        }
        var average = Path()
        for k in 0..<count {
            let n = Double(first + k)
            let x = CGFloat(first + k) * spacing - scroll
            let open = value(n - 1), close = value(n)
            let wick = 0.012 + 0.018 * hash(n)
            let high = min(open, close) - wick, low = max(open, close) + wick
            let rising = close < open   // y grows downward: a smaller y is higher
            let color = (rising ? palette.accent : palette.danger).opacity(a(rising ? 0.34 : 0.22))
            var line = Path()
            line.move(to: CGPoint(x: x, y: h * CGFloat(high))); line.addLine(to: CGPoint(x: x, y: h * CGFloat(low)))
            context.stroke(line, with: .color(color), lineWidth: 1)
            let top = h * CGFloat(min(open, close)), bodyHeight = max(2, h * CGFloat(abs(close - open)))
            let body = Path(CGRect(x: x - 4, y: top, width: 8, height: bodyHeight))
            if rising { context.fill(body, with: .color(color)) } else { context.stroke(body, with: .color(color), lineWidth: 1) }

            let mean = (value(n) + value(n - 1) + value(n - 2) + value(n - 3)) / 4
            let point = CGPoint(x: x, y: h * CGFloat(mean))
            if k == 0 { average.move(to: point) } else { average.addLine(to: point) }
        }
        glow(average, palette.reply.opacity(a(0.26)), width: 1.2, radius: 4)
        // The phosphor's scanline, rolling down the glass.
        let scan = h * CGFloat((time * 0.06).truncatingRemainder(dividingBy: 1))
        context.fill(Path(CGRect(x: 0, y: scan - 40, width: w, height: 80)),
                     with: .linearGradient(Gradient(colors: [palette.accent.opacity(0), palette.accent.opacity(a(0.05)),
                                                             palette.accent.opacity(0)]),
                                           startPoint: CGPoint(x: 0, y: scan - 40), endPoint: CGPoint(x: 0, y: scan + 40)))
    }

    // MARK: Neon — Neon

    private func neon() {
        let horizon = h * 0.6
        let vanishing = CGPoint(x: w / 2, y: horizon)
        // The sun, sliced, sinking into the horizon.
        let sunRadius = w * 0.26
        let sun = Path(ellipseIn: CGRect(x: vanishing.x - sunRadius, y: horizon - sunRadius * 1.15,
                                         width: sunRadius * 2, height: sunRadius * 2))
        context.drawLayer { layer in
            layer.clip(to: Path(CGRect(x: 0, y: 0, width: w, height: horizon)))
            layer.fill(sun, with: .linearGradient(Gradient(colors: [palette.attention.opacity(a(0.16)),
                                                                     palette.accent.opacity(a(0.14))]),
                                                  startPoint: CGPoint(x: 0, y: horizon - sunRadius * 1.15),
                                                  endPoint: CGPoint(x: 0, y: horizon)))
            for stripe in 0..<5 {
                let y = horizon - CGFloat(stripe) * sunRadius * 0.14 - 6
                layer.fill(Path(CGRect(x: 0, y: y, width: w, height: 2 + CGFloat(stripe) * 0.6)),
                           with: .color(palette.paper))
            }
        }
        // The floor, running toward you.
        var floor = Path()
        let lines = 9
        let phase = (time * 0.18).truncatingRemainder(dividingBy: 1)
        for k in 0..<lines {
            let depth = (Double(k) + phase) / Double(lines)
            let y = horizon + (h - horizon) * CGFloat(depth * depth)
            floor.move(to: CGPoint(x: 0, y: y)); floor.addLine(to: CGPoint(x: w, y: y))
        }
        for k in -8...8 {
            floor.move(to: vanishing)
            floor.addLine(to: CGPoint(x: vanishing.x + CGFloat(k) * w * 0.22, y: h))
        }
        context.drawLayer { layer in
            layer.clip(to: Path(CGRect(x: 0, y: horizon, width: w, height: h - horizon)))
            layer.stroke(floor, with: .linearGradient(Gradient(colors: [palette.accent.opacity(0), palette.accent.opacity(a(0.26))]),
                                                      startPoint: CGPoint(x: 0, y: horizon), endPoint: CGPoint(x: 0, y: h)),
                         lineWidth: 1)
        }
        // The signal over it.
        let zig = path(steps: 60) { x in h * CGFloat(0.4 - 0.12 * x + 0.06 * signal(x * 1.4, seed: 5, speed: 1.3)) }
        glow(zig, palette.reply.opacity(a(0.32)), width: 1.5, radius: 6)
        let second = path(steps: 60) { x in h * CGFloat(0.47 - 0.06 * x + 0.05 * signal(x * 1.1, seed: 11, speed: 0.9)) }
        glow(second, palette.accent.opacity(a(0.28)), width: 1.2, radius: 5)
    }

    // MARK: Scatter — Bloom

    private func scatter() {
        // The trend the points scatter about.
        let trend = path { x in h * CGFloat(0.7 - 0.36 * x + 0.03 * signal(x, seed: 3, speed: 0.4)) }
        context.stroke(trend, with: .color(palette.accent.opacity(a(0.22))),
                       style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [1, 5]))
        for index in 0..<46 {
            let i = Double(index)
            let speed = 0.012 + 0.012 * hash(i * 2.7)
            let life = (time * speed + hash(i * 5.3)).truncatingRemainder(dividingBy: 1)
            let baseX = hash(i * 1.3)
            let x = w * CGFloat(baseX) + 14 * CGFloat(sin(time * 0.5 + i * 1.7))
            let y = h * CGFloat(1.02 - 1.1 * life)
            let r = CGFloat(1.8 + 3.6 * hash(i * 9.1))
            let fade = sin(.pi * life)
            let color = (index % 4 == 0 ? palette.reply : palette.accent).opacity(a(0.36 * fade))
            // A petal: a dot, stretched and turned as it rises.
            let petal = Path(ellipseIn: CGRect(x: -r * 1.4, y: -r, width: r * 2.8, height: r * 2))
            context.fill(petal.applying(CGAffineTransform(rotationAngle: CGFloat(time * 0.6 + i))
                                            .concatenating(CGAffineTransform(translationX: x, y: y))),
                         with: .color(color))
        }
    }

    // MARK: Radar — Gilded

    private func radar() {
        let center = CGPoint(x: w * 0.5, y: h * 0.4)
        let radius = min(w, h) * 0.62
        var rings = Path()
        for k in 1...4 {
            let r = radius * CGFloat(k) / 4
            rings.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        }
        for k in 0..<6 {
            let angle = Double(k) * .pi / 3
            rings.move(to: center)
            rings.addLine(to: CGPoint(x: center.x + radius * CGFloat(cos(angle)), y: center.y + radius * CGFloat(sin(angle))))
        }
        context.stroke(rings, with: .color(palette.accent.opacity(a(0.12))), lineWidth: 0.8)

        // The spider chart, breathing.
        var web = Path()
        for k in 0...6 {
            let angle = Double(k % 6) * .pi / 3
            let reach = 0.45 + 0.3 * (0.5 + 0.5 * sin(time * 0.4 + Double(k) * 1.9))
            let point = CGPoint(x: center.x + radius * CGFloat(reach * cos(angle)),
                                y: center.y + radius * CGFloat(reach * sin(angle)))
            if k == 0 { web.move(to: point) } else { web.addLine(to: point) }
        }
        context.fill(web, with: .color(palette.accent.opacity(a(0.06))))
        context.stroke(web, with: .color(palette.accent.opacity(a(0.24))), lineWidth: 1)

        // The sweep.
        let sweep = (time * 0.7).truncatingRemainder(dividingBy: 2 * .pi)
        var wedge = Path()
        wedge.move(to: center)
        wedge.addArc(center: center, radius: radius, startAngle: .radians(sweep - 0.7), endAngle: .radians(sweep), clockwise: false)
        wedge.closeSubpath()
        context.fill(wedge, with: .conicGradient(
            Gradient(stops: [.init(color: palette.accent.opacity(0), location: 0),
                             .init(color: palette.accent.opacity(0), location: 1 - 0.7 / (2 * .pi)),
                             .init(color: palette.accent.opacity(a(0.2)), location: 1)]),
            center: center, angle: .radians(sweep)))
        var arm = Path()
        arm.move(to: center)
        arm.addLine(to: CGPoint(x: center.x + radius * CGFloat(cos(sweep)), y: center.y + radius * CGFloat(sin(sweep))))
        glow(arm, palette.accent.opacity(a(0.4)), width: 1.2, radius: 4)

        // Blips that light as the arm passes them, then fade.
        for index in 0..<9 {
            let i = Double(index)
            let angle = hash(i * 4.1) * 2 * .pi
            let reach = 0.2 + 0.75 * hash(i * 6.7)
            var since = (sweep - angle).truncatingRemainder(dividingBy: 2 * .pi)
            if since < 0 { since += 2 * .pi }
            let glow = exp(-since * 1.1)
            let point = CGPoint(x: center.x + radius * CGFloat(reach * cos(angle)),
                                y: center.y + radius * CGFloat(reach * sin(angle)))
            dot(at: point, radius: 2.5, color: (index % 3 == 0 ? palette.reply : palette.accent).opacity(a(0.15 + 0.6 * glow)))
        }
    }

    /// A fixed pseudo-random number in 0..<1 for a seed.
    private func hash(_ seed: Double) -> Double {
        let value = sin(seed * 12.9898 + 78.233) * 43_758.5453
        return value - floor(value)
    }
}
