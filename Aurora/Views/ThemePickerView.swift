import SwiftUI

/// Settings › Theme: every theme as a live card — its own chart already moving
/// on its own ground, its icon, its colours — so you choose by seeing each one
/// run rather than by reading a name.
///
/// Tapping a card applies it from where the finger landed: a wash of the new
/// ground spreads from that point across the screen while every colour blends
/// underneath (``ThemeWashOverlay``), and the home-screen icon follows.
struct ThemePickerView: View {
    private var current: AppTheme { ThemeStore.shared.current }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(AppTheme.all) { theme in
                    ThemeCard(theme: theme, isCurrent: theme == current)
                }
            }
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.vertical, 8)
        }
        .paperBottomEdge()
        .paperScreen()
        .navigationTitle("Theme")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ThemeCard: View {
    let theme: AppTheme
    let isCurrent: Bool

    @State private var frame: CGRect = .zero

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous)
    }

    var body: some View {
        let palette = theme.palette
        VStack(spacing: 0) {
            // The theme running: its ground and chart, with a mock row and
            // button in its colours over them.
            ZStack(alignment: .topLeading) {
                ChartGround(theme: theme, intensity: 1.6)
                HStack(spacing: 10) {
                    Image(theme.iconPreview)
                        .resizable()
                        .frame(width: 46, height: 46)
                        .clipShape(.rect(cornerRadius: 11, style: .continuous))
                        .shadow(color: palette.accent.opacity(0.35), radius: 10)
                    VStack(alignment: .leading, spacing: 5) {
                        Capsule().fill(palette.ink.opacity(0.85)).frame(width: 92, height: 7)
                        Capsule().fill(palette.inkMuted.opacity(0.7)).frame(width: 60, height: 6)
                    }
                    Spacer()
                    Image(systemName: theme.mark)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(palette.accent, in: Circle())
                }
                .padding(10)
                .background(palette.paperRaised.opacity(0.92),
                            in: .rect(cornerRadius: Theme.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(palette.hairline, lineWidth: 1))
                .padding(12)
            }
            .frame(height: 150)
            .clipped()

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(theme.name)
                        .font(.display(19))
                        .foregroundStyle(palette.ink)
                    Text(theme.tagline)
                        .font(.caption)
                        .foregroundStyle(palette.inkMuted)
                }
                Spacer(minLength: 8)
                ThemeSwatches(palette: palette, size: 14)
                Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isCurrent ? palette.accent : palette.inkFaint)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(palette.paperRaised)
        }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(isCurrent ? palette.accent : palette.hairline, lineWidth: isCurrent ? 2 : 1)
        }
        .scaleEffect(isCurrent ? 1 : 0.985)
        .animation(Theme.Motion.pop, value: isCurrent)
        .contentShape(shape)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        // The wash starts where the finger lands, so a tap has to know where it
        // was — a plain Button reports only that it happened.
        .onTapGesture(coordinateSpace: .global) { location in
            ThemeStore.shared.apply(theme, from: location)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(theme.name) theme. \(theme.tagline)")
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction {
            ThemeStore.shared.apply(theme, from: CGPoint(x: frame.midX, y: frame.midY))
        }
    }
}

/// The wash that carries a theme change across the screen: a disc of the new
/// ground, rimmed in the new accent, spreading from the tapped point while the
/// colours under it blend, then thinning away to show the app already changed.
///
/// Sits over the whole app and never takes a touch.
struct ThemeWashOverlay: View {
    @State private var radius: CGFloat = 0
    @State private var fade: Double = 1

    var body: some View {
        GeometryReader { proxy in
            if let wash = ThemeStore.shared.wash {
                let origin = wash.origin
                let size = proxy.size
                // Far enough to reach the furthest corner from the origin.
                let reach = [CGPoint.zero, CGPoint(x: size.width, y: 0),
                             CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height)]
                    .map { hypot($0.x - origin.x, $0.y - origin.y) }
                    .max() ?? 0
                let palette = wash.theme.palette
                ZStack {
                    Circle()
                        .fill(RadialGradient(colors: [palette.paper.opacity(0.8), palette.paper.opacity(0.62)],
                                             center: .center, startRadius: 0, endRadius: max(radius, 1)))
                    Circle()
                        .strokeBorder(palette.accent.opacity(0.9), lineWidth: 3)
                        .blur(radius: 6)
                    Circle()
                        .strokeBorder(palette.accent, lineWidth: 1.5)
                }
                .frame(width: radius * 2, height: radius * 2)
                .position(origin)
                .opacity(fade)
                .task(id: wash.id) {
                    radius = 0
                    fade = 1
                    withAnimation(.easeOut(duration: 0.6)) { radius = reach + 40 }
                    try? await Task.sleep(for: .milliseconds(480))
                    withAnimation(.easeIn(duration: 0.55)) { fade = 0 }
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
