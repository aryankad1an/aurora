import SwiftUI

/// The screen's main verb: the glyph at the front of the top bar's capsule.
struct TopBarPrimary {
    let title: String
    let systemImage: String
    /// Coloured, for the one tap that commits something (Save).
    var isProminent = false
    /// Working on it: the glyph turns in place and the button can't be tapped
    /// again until it's done.
    var isBusy = false
    let action: () -> Void
}

extension View {
    /// The top bar every panel shares, so switching tabs never moves a control:
    ///
    /// - **trailing**, one Liquid Glass capsule holding the screen's main verb
    ///   and the `⋯` menu with everything else, in the same spot on every tab;
    /// - **editing** (`onCancel` set): the menu steps aside and a ✕ takes the
    ///   leading edge, while the verb's glyph morphs into the commit (✎ → ✓);
    /// - **hidden** while the screen is selecting — `selectionActions` owns the
    ///   bar then, with Select All and Done.
    ///
    /// The capsule greets each arrival: whenever the panel appears — a tab
    /// switched to, a detail popped back from — its glyphs bounce in one after
    /// the other, a ripple running along the glass rather than the bar simply
    /// being there. Menus in the `⋯` should order their items the same way
    /// everywhere: things to add, Select, a divider, then view options — and
    /// keep Select listed, disabled, when there's nothing to select, so a menu
    /// never changes shape or opens empty.
    func topBarActions<More: View>(
        _ primary: TopBarPrimary?,
        isHidden: Bool = false,
        onCancel: (() -> Void)? = nil,
        @ViewBuilder more: () -> More
    ) -> some View {
        modifier(TopBarActions(primary: primary, isHidden: isHidden,
                               onCancel: onCancel, more: more()))
    }
}

private struct TopBarActions<More: View>: ViewModifier {
    let primary: TopBarPrimary?
    let isHidden: Bool
    let onCancel: (() -> Void)?
    let more: More

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Bumped on every arrival; each glyph bounces when its own count changes,
    /// the menu's a beat after the verb's, so the ripple travels.
    @State private var primaryArrival = 0
    @State private var moreArrival = 0

    private var isEditing: Bool { onCancel != nil }

    /// The gap between the verb's bounce and the dots', long enough to read as a
    /// wave and short enough to finish before the eye has left the bar.
    private static var ripple: Duration { .milliseconds(90) }

    func body(content: Content) -> some View {
        content
            .toolbar {
                if !isHidden {
                    if let onCancel {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                Haptics.tap(0.5)
                                withAnimation(Theme.Motion.liquid) { onCancel() }
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .accessibilityLabel("Cancel")
                        }
                    }
                    if let primary {
                        ToolbarItem(placement: .topBarTrailing) { primaryButton(primary) }
                    }
                    if !isEditing {
                        ToolbarItem(placement: .topBarTrailing) { moreMenu }
                    }
                }
            }
            .onAppear(perform: arrive)
    }

    private func primaryButton(_ primary: TopBarPrimary) -> some View {
        Button {
            Haptics.tap()
            primary.action()
        } label: {
            Image(systemName: primary.systemImage)
                .fontWeight(primary.isProminent ? .semibold : nil)
                .foregroundStyle(primary.isProminent ? AnyShapeStyle(.clay) : AnyShapeStyle(.primary))
                // One slot, several glyphs over its life — ✎ becoming ✓, + and
                // ↻ trading places — so a change of verb morphs, never cuts.
                .contentTransition(.symbolEffect(.replace.magic(fallback: .downUp.byLayer)))
                .symbolEffect(.bounce.up.byLayer, options: .nonRepeating, value: primaryArrival)
                .symbolEffect(.rotate.byLayer, options: .repeat(.continuous), isActive: primary.isBusy)
        }
        .disabled(primary.isBusy)
        .accessibilityLabel(primary.title)
    }

    private var moreMenu: some View {
        Menu {
            more
        } label: {
            Image(systemName: "ellipsis")
                .symbolEffect(.bounce.up.byLayer, options: .nonRepeating, value: moreArrival)
        }
        .accessibilityLabel("More actions")
    }

    private func arrive() {
        guard !reduceMotion else { return }
        primaryArrival += 1
        Task {
            try? await Task.sleep(for: primary == nil ? .zero : Self.ripple)
            moreArrival += 1
        }
    }
}
