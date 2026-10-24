import SwiftUI

/// The screen's main verb: the glyph at the front of the top bar's capsule.
struct TopBarPrimary {
    let title: String
    let systemImage: String
    /// Coloured, for the one tap that commits something (Save).
    var isProminent = false
    /// Working on it: the glyph turns in place. Still tappable — the action
    /// decides what a tap means meanwhile (Activity's shows the check's
    /// progress), since a control that ignores taps reads as broken.
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
        modifier(TopBarActions<More, EmptyView>(primary: primary, isHidden: isHidden,
                                                onCancel: onCancel, more: more()))
    }

    /// The same bar with a filter menu at the front of the capsule, for a list
    /// that can be cut down: its choices live there rather than as chips over
    /// the list. The glyph fills in clay while `isFiltering`, so a cut-down list
    /// never passes for the whole one.
    func topBarActions<More: View, Filter: View>(
        _ primary: TopBarPrimary?,
        isHidden: Bool = false,
        onCancel: (() -> Void)? = nil,
        isFiltering: Bool,
        @ViewBuilder filter: () -> Filter,
        @ViewBuilder more: () -> More
    ) -> some View {
        modifier(TopBarActions(primary: primary, isHidden: isHidden, onCancel: onCancel,
                               more: more(), filter: filter(), isFiltering: isFiltering))
    }
}

private struct TopBarActions<More: View, Filter: View>: ViewModifier {
    let primary: TopBarPrimary?
    let isHidden: Bool
    let onCancel: (() -> Void)?
    let more: More
    var filter: Filter?
    var isFiltering = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Bumped on every arrival; each glyph bounces when its own count changes,
    /// the menu's a beat after the verb's, so the ripple travels.
    @State private var filterArrival = 0
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
                    if let filter, !isEditing {
                        ToolbarItem(placement: .topBarTrailing) { filterMenu(filter) }
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
        .accessibilityLabel(primary.title)
    }

    private func filterMenu(_ filter: Filter) -> some View {
        Menu {
            filter
        } label: {
            Image(systemName: isFiltering ? "line.3.horizontal.decrease.circle.fill"
                                          : "line.3.horizontal.decrease")
                .foregroundStyle(isFiltering ? AnyShapeStyle(.clay) : AnyShapeStyle(.primary))
                .contentTransition(.symbolEffect(.replace.magic(fallback: .downUp.byLayer)))
                .symbolEffect(.bounce.up.byLayer, options: .nonRepeating, value: filterArrival)
        }
        .accessibilityLabel("Filter")
        .accessibilityValue(isFiltering ? "On" : "Off")
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
        Task {
            if filter != nil {
                filterArrival += 1
                try? await Task.sleep(for: Self.ripple)
            }
            primaryArrival += 1
            try? await Task.sleep(for: primary == nil ? .zero : Self.ripple)
            moreArrival += 1
        }
    }
}
