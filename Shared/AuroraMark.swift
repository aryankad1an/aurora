import SwiftUI

/// Aurora's mark: a dawn. A hairline horizon with the sun's arc on it, and one
/// stroke rising out of it to a bead — the outreach curve, the shape the app
/// exists to bend upward, breaking clear of the arc.
///
/// Every theme draws the same mark in its own colours and changes one detail,
/// so the six read as one family: Tide's horizon is a swell, Phosphor's bead a
/// cursor, Neon's sun is striped, Bloom's bead a blossom, Gilded's arc a dial.
///
/// The app icons are drawn from the same geometry by
/// `scripts/app_icons/make_theme_icons.swift`; change both together. Shared with
/// the widget extension, which draws it in the Live Activity.
struct AuroraMark: View {
    /// Which theme's version. The raw values are the theme IDs.
    enum Variant: String, Codable, Hashable, Sendable {
        case aurora, tide, phosphor, neon, bloom, gilded
    }

    var variant: Variant = .aurora
    /// The rising stroke.
    var accent: Color
    /// The bead at its tip.
    var bead: Color
    /// The horizon and the arc.
    var line: Color

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            context.translateBy(x: (size.width - side) / 2, y: (size.height - side) / 2)
            draw(in: &context, side: side)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    // MARK: - Geometry, in a unit square

    /// The horizon's height, and the sun's centre on it.
    static let horizonY = 0.74
    static let horizon = (from: 0.12, to: 0.88)
    static let sunRadius = 0.27
    static let riseStart = CGPoint(x: 0.27, y: 0.74)
    static let riseControl1 = CGPoint(x: 0.50, y: 0.74)
    static let riseControl2 = CGPoint(x: 0.60, y: 0.42)
    static let riseEnd = CGPoint(x: 0.78, y: 0.28)

    /// The rise at `t` (0…1), in the unit square.
    static func rise(_ t: Double) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * riseStart.x + b * riseControl1.x + c * riseControl2.x + d * riseEnd.x,
                       y: a * riseStart.y + b * riseControl1.y + c * riseControl2.y + d * riseEnd.y)
    }

    /// The rise as one closed outline that swells from `from` wide at the
    /// horizon to `to` at its end, like a brush stroke, with round ends, stopping
    /// `gap` short of the tip so the bead sits apart: a full stop after the line.
    /// Unit-square sizes.
    static func riseOutline(from: Double, to: Double, gap: Double) -> Path {
        let tip = riseEnd
        let samples = (0...200).map { rise(Double($0) / 200) }
        let last = samples.lastIndex { hypot($0.x - tip.x, $0.y - tip.y) > gap } ?? samples.count - 1
        let points = Array(samples[...last])
        var left: [CGPoint] = [], right: [CGPoint] = []
        var normals: [CGVector] = []
        for (i, point) in points.enumerated() {
            let before = points[max(i - 1, 0)], after = points[min(i + 1, points.count - 1)]
            let dx = after.x - before.x, dy = after.y - before.y
            let length = max(hypot(dx, dy), 1e-9)
            let t = Double(i) / Double(max(points.count - 1, 1))
            let half = (from + (to - from) * t * t * (3 - 2 * t)) / 2
            let normal = CGVector(dx: -dy / length, dy: dx / length)
            normals.append(normal)
            left.append(CGPoint(x: point.x + normal.dx * half, y: point.y + normal.dy * half))
            right.append(CGPoint(x: point.x - normal.dx * half, y: point.y - normal.dy * half))
        }
        // A half circle round each end, so the outline is one shape: two
        // overlapping fills would show their seam through a translucent colour.
        func cap(at point: CGPoint, normal n: CGVector, radius: Double, sign: Double) -> [CGPoint] {
            let d = CGVector(dx: n.dy, dy: -n.dx)
            return (1..<24).map { k in
                let a = Double(k) / 24 * .pi
                return CGPoint(x: point.x + sign * (n.dx * radius * cos(a) + d.dx * radius * sin(a)),
                               y: point.y + sign * (n.dy * radius * cos(a) + d.dy * radius * sin(a)))
            }
        }
        var outline = left
        outline += cap(at: points[points.count - 1], normal: normals[normals.count - 1], radius: to / 2, sign: 1)
        outline += right.reversed()
        outline += cap(at: points[0], normal: normals[0], radius: from / 2, sign: -1)
        var path = Path()
        path.addLines(outline)
        path.closeSubpath()
        return path
    }

    private func draw(in context: inout GraphicsContext, side: CGFloat) {
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * side, y: y * side) }
        func p(_ point: CGPoint) -> CGPoint { p(point.x, point.y) }

        // Small, as in the Dynamic Island, the hairlines would blur into the
        // stroke: keep the horizon and the rise, and make both bolder.
        let small = side < 30
        let hairline = side * (small ? 0.06 : 0.022)
        let beadRadius = side * (small ? 0.105 : 0.056)
        let center = p(0.5, Self.horizonY)
        let radius = Self.sunRadius * side

        // The sun.
        if !small {
            let arc = Path { path in
                path.addArc(center: center, radius: radius, startAngle: .degrees(180), endAngle: .degrees(360),
                            clockwise: false)
            }
            switch variant {
            case .neon:
                var disc = Path()
                disc.addPath(arc)
                disc.closeSubpath()
                // Slits cut across the sun, clipped to it.
                var sunContext = context
                sunContext.clip(to: disc)
                var sun = disc
                for k in 0..<3 {
                    let y = Self.horizonY - 0.05 - Double(k) * 0.065
                    sun.addRect(CGRect(origin: p(0.1, y), size: CGSize(width: 0.8 * side, height: (0.022 + 0.008 * Double(k)) * side)))
                }
                sunContext.fill(sun, with: .linearGradient(Gradient(colors: [accent.opacity(0.1), accent.opacity(0.42)]),
                                                        startPoint: p(0.5, Self.horizonY - Self.sunRadius),
                                                        endPoint: center),
                             style: FillStyle(eoFill: true))
            case .gilded:
                context.stroke(arc, with: .color(line), lineWidth: hairline)
                var ticks = Path()
                for k in 0...8 {
                    let angle = Double.pi + Double(k) * .pi / 8
                    let inner = radius + side * 0.035, outer = radius + side * (k % 2 == 0 ? 0.075 : 0.055)
                    ticks.move(to: CGPoint(x: center.x + inner * cos(angle), y: center.y + inner * sin(angle)))
                    ticks.addLine(to: CGPoint(x: center.x + outer * cos(angle), y: center.y + outer * sin(angle)))
                }
                context.stroke(ticks, with: .color(line), style: StrokeStyle(lineWidth: hairline, lineCap: .round))
            default:
                context.stroke(arc, with: .color(line), lineWidth: hairline)
            }
        }

        // The horizon.
        var horizon = Path()
        if variant == .tide {
            for i in 0...60 {
                let t = Double(i) / 60
                let x = Self.horizon.from + (Self.horizon.to - Self.horizon.from) * t
                let point = p(x, Self.horizonY + 0.018 * sin(t * .pi * 4))
                if i == 0 { horizon.move(to: point) } else { horizon.addLine(to: point) }
            }
        } else {
            horizon.move(to: p(Self.horizon.from, Self.horizonY))
            horizon.addLine(to: p(Self.horizon.to, Self.horizonY))
        }
        let dash: [CGFloat] = variant == .phosphor && !small ? [side * 0.045, side * 0.03] : []
        context.stroke(horizon, with: .color(line),
                       style: StrokeStyle(lineWidth: hairline, lineCap: dash.isEmpty ? .round : .butt, dash: dash))

        // The rise.
        let outline = small
            ? Self.riseOutline(from: 0.1, to: 0.13, gap: 0)
            : Self.riseOutline(from: 0.042, to: 0.07, gap: 0.1)
        context.fill(outline.applying(CGAffineTransform(scaleX: side, y: side)),
                     with: .linearGradient(Gradient(colors: [accent.mix(with: .black, by: 0.14), accent]),
                                           startPoint: p(Self.riseStart), endPoint: p(Self.riseEnd)))

        // The bead.
        let tip = p(Self.riseEnd)
        switch variant {
        case .phosphor:
            let s = beadRadius * 1.8
            context.fill(Path(roundedRect: CGRect(x: tip.x - s / 2, y: tip.y - s / 2, width: s, height: s),
                              cornerRadius: s * 0.22, style: .continuous), with: .color(bead))
        case .bloom where !small:
            for k in 0..<5 {
                var petal = context
                petal.translateBy(x: tip.x, y: tip.y)
                petal.rotate(by: .radians(Double(k) * 2 * .pi / 5 - .pi / 2))
                petal.fill(Path(ellipseIn: CGRect(x: beadRadius * 0.15, y: -beadRadius * 0.42,
                                                  width: beadRadius * 1.05, height: beadRadius * 0.84)),
                           with: .color(bead))
            }
            context.fill(Path(ellipseIn: CGRect(x: tip.x - beadRadius * 0.32, y: tip.y - beadRadius * 0.32,
                                                width: beadRadius * 0.64, height: beadRadius * 0.64)),
                         with: .color(accent))
        default:
            context.fill(Path(ellipseIn: CGRect(x: tip.x - beadRadius, y: tip.y - beadRadius,
                                                width: beadRadius * 2, height: beadRadius * 2)),
                         with: .color(bead))
        }
    }
}
