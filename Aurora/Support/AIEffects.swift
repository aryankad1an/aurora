import SwiftUI

// MARK: - Apple Intelligence look
//
// The AI features share one visual language: a slowly turning ring of soft
// colour around whatever Apple Intelligence changed, and a burst of sparkles
// when a change is kept. All of it holds still
// when Reduce Motion is on, and none of it blurs — a blur redrawn every frame
// is the cost the rest of the app's motion avoids (see LiquidMotion.swift).

enum AIStyle {
    /// Pink through violet to blue: the colours Apple Intelligence glows with,
    /// read as the app's own because they sit beside the theme's accent.
    static let colors: [Color] = [
        Color(red: 1.00, green: 0.42, blue: 0.55),
        Color(red: 1.00, green: 0.66, blue: 0.36),
        Color(red: 0.69, green: 0.47, blue: 0.97),
        Color(red: 0.34, green: 0.60, blue: 1.00),
        Color(red: 0.30, green: 0.84, blue: 0.86)
    ]

    static func gradient(angle: Angle = .zero) -> AngularGradient {
        AngularGradient(colors: colors + [colors[0]], center: .center, angle: angle)
    }

    static var linear: LinearGradient {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// A ring of turning colour around a rounded rectangle.
struct AIGlowBorder: View {
    var cornerRadius: CGFloat = Theme.Radius.card
    var lineWidth: CGFloat = 2
    /// Turning (true) or holding still (false).
    var isTurning = true
    /// Strength of the soft halo drawn inside the ring.
    var halo: Double = 0.2

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Thirty frames a second: the ring turns slowly, and every frame redraws a
        // gradient stroke over whatever it surrounds.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !isTurning)) { context in
            let seconds = context.date.timeIntervalSinceReferenceDate
            let angle = reduceMotion ? Angle.zero : .degrees((seconds * 70).truncatingRemainder(dividingBy: 360))
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            shape
                .strokeBorder(AIStyle.gradient(angle: angle), lineWidth: lineWidth)
                .background {
                    shape.strokeBorder(AIStyle.gradient(angle: angle), lineWidth: lineWidth * 5)
                        .opacity(halo)
                        .clipShape(shape)
                }
        }
        .allowsHitTesting(false)
    }
}

extension View {
    /// A glow that rings this view for a moment each time `trigger` changes —
    /// the host's acknowledgement that a change from the AI just landed in it.
    func aiAppliedFlash(trigger: Int, cornerRadius: CGFloat = Theme.Radius.card,
                        inset: EdgeInsets = EdgeInsets()) -> some View {
        modifier(AIAppliedFlash(trigger: trigger, cornerRadius: cornerRadius, inset: inset))
    }
}

private struct AIAppliedFlash: ViewModifier {
    let trigger: Int
    let cornerRadius: CGFloat
    let inset: EdgeInsets
    @State private var visible = false
    @State private var generation = 0

    func body(content: Content) -> some View {
        content
            .overlay {
                if visible {
                    AIGlowBorder(cornerRadius: cornerRadius, lineWidth: 2.5, halo: 0.25)
                        .padding(inset)
                        .transition(.opacity)
                }
            }
            .onChange(of: trigger) {
                generation += 1
                let mine = generation
                withAnimation(.easeOut(duration: 0.25)) { visible = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.6))
                    guard mine == generation else { return }
                    withAnimation(.easeIn(duration: 0.7)) { visible = false }
                }
            }
    }
}

/// Stars flying outward from the centre and fading, once, as a change lands.
struct AISparkleBurst: View {
    var count = 14
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Values {
        var distance = 0.0
        var scale = 0.2
        var opacity = 1.0
    }

    var body: some View {
        if reduceMotion {
            EmptyView()
        } else {
            KeyframeAnimator(initialValue: Values(), repeating: false) { values in
                GeometryReader { geometry in
                    let reach = min(geometry.size.width, geometry.size.height) * 0.42
                    ZStack {
                        ForEach(0..<count, id: \.self) { index in
                            let turn = Double(index) / Double(count) * 2 * .pi + (index.isMultiple(of: 2) ? 0.18 : -0.1)
                            let far = index.isMultiple(of: 3) ? 0.78 : 1.0
                            Image(systemName: "sparkle")
                                .font(.system(size: index.isMultiple(of: 2) ? 26 : 16, weight: .bold))
                                .foregroundStyle(AIStyle.colors[index % AIStyle.colors.count])
                                .scaleEffect(values.scale)
                                .opacity(values.opacity)
                                .offset(x: cos(turn) * reach * values.distance * far,
                                        y: sin(turn) * reach * values.distance * far)
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
            } keyframes: { _ in
                KeyframeTrack(\.distance) { CubicKeyframe(1, duration: 0.95) }
                KeyframeTrack(\.scale) {
                    CubicKeyframe(1.0, duration: 0.25)
                    CubicKeyframe(0.3, duration: 0.7)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(1, duration: 0.45)
                    LinearKeyframe(0, duration: 0.5)
                }
            }
        }
    }
}
