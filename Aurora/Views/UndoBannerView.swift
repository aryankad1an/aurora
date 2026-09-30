import SwiftUI

/// A warm, floating confirmation banner shown when an edit occurs,
/// allowing the user to undo the action within 5 seconds.
struct UndoBannerView: View {
    var coordinator: UndoCoordinator = .shared

    var body: some View {
        if let item = coordinator.activeItem {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(Color.olive)

                Text(item.message)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)

                Spacer(minLength: 8)

                // 5-second countdown pill
                HStack(spacing: 6) {
                    Text("\(coordinator.secondsRemaining)s")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Color.inkMuted)
                        .contentTransition(.numericText(countsDown: true))
                        .animation(Theme.Motion.snappy, value: coordinator.secondsRemaining)
                        .accessibilityHidden(true)

                    Button("Undo") {
                        Task { await coordinator.undo() }
                    }
                    .font(.subheadline.weight(.semibold))
                    .filledButton()
                    .accessibilityHint("Reverts the change")
                }
            }
            .accessibilityElement(children: .combine)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            // Glass, like every other floating bar in the app: it hovers over
            // whatever screen it lands on, and the material keeps that screen
            // legible underneath instead of blanking a strip of it.
            .glassEffect(.regular.interactive(), in: .capsule)
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.bottom, 8)
            .transition(.glassRise)
        }
    }
}

extension View {
    /// Attach the floating 5-second undo banner to any screen.
    func undoBanner() -> some View {
        overlay(alignment: .bottom) { UndoBannerOverlay() }
    }
}

/// Owns the banner's show/hide animation, which needs to observe the shared
/// coordinator from inside a view body.
private struct UndoBannerOverlay: View {
    private let coordinator = UndoCoordinator.shared

    var body: some View {
        UndoBannerView(coordinator: coordinator)
            .animation(Theme.Motion.liquid, value: coordinator.activeItem?.id)
    }
}

