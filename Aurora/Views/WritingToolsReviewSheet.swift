import SwiftUI

/// What Writing Tools changed, as a word-level comparison, with the choice the
/// system's own panel doesn't leave: keep it, or put the old text back. It also
/// says when a change damaged a `{placeholder}`, which Writing Tools has no idea
/// is anything but text.
struct WritingToolsReviewSheet: View {
    let change: WritingToolsChange
    let onRevert: () -> Void
    let onKeep: () -> Void

    private enum Tab: Hashable { case changes, result }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var tab = Tab.changes
    @State private var sealed = false

    var body: some View {
        let diff = change.diff
        let damage = PlaceholderDamage(before: change.before, after: change.after)
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(diff)

                    if !damage.isEmpty { damageNote(damage) }

                    SegmentedSelector(segments: [(Tab.changes, "Changes"), (Tab.result, "Result")], selection: $tab)

                    Group {
                        if tab == .changes {
                            Text(diff.attributed)
                        } else {
                            Text(change.after)
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(Color.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .panel()
                    .overlay { AIGlowBorder(isTurning: !sealed, halo: 0.10).opacity(0.8) }
                    .contentTransition(.opacity)

                    if tab == .changes { legend(diff) }
                }
                .padding(.horizontal, Theme.Space.gutter)
                .padding(.top, 22)
                .padding(.bottom, 16)
            }

            actions
        }
        .paperScreen()
        .overlay { seal }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // A choice, not a dismissal: swiping away would leave unsaid whether
        // the change was kept.
        .interactiveDismissDisabled()
        .onAppear { Haptics.arrival() }
    }

    private func header(_ diff: TextDiff) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.title3.weight(.semibold))
                .foregroundStyle(AIStyle.linear)
                .symbolEffect(.pulse, options: .repeating.speed(0.5), isActive: !reduceMotion)
            VStack(alignment: .leading, spacing: 2) {
                Text("Apple Intelligence changed your text")
                    .font(.headline)
                    .foregroundStyle(Color.ink)
                Text("Keep it, or put your original back.")
                    .font(.footnote)
                    .foregroundStyle(Color.inkMuted)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Text("+\(diff.addedWords)").foregroundStyle(Color.olive)
                Text("−\(diff.removedWords)").foregroundStyle(Color.danger)
            }
            .font(.caption.weight(.semibold).monospacedDigit())
        }
    }

    private func damageNote(_ damage: PlaceholderDamage) -> some View {
        var parts: [String] = []
        if !damage.removed.isEmpty { parts.append("removed \(damage.removed.joined(separator: ", "))") }
        if !damage.added.isEmpty { parts.append("added \(damage.added.joined(separator: ", "))") }
        return Label {
            Text("This change \(parts.joined(separator: " and ")). The mail would go out with a blank or a stray token where it was — revert, or fix it by hand.")
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(Color.kraft)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.kraft.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.inner, style: .continuous))
    }

    private func legend(_ diff: TextDiff) -> some View {
        HStack(spacing: 14) {
            if diff.addedWords > 0 { key("Added", Color.olive) }
            if diff.removedWords > 0 { key("Removed", Color.danger) }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(Color.inkMuted)
    }

    private func key(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.35)).frame(width: 12, height: 12)
            Text(title)
        }
    }

    private var actions: some View {
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            if stacked { keepButton }
            Button {
                Haptics.warning()
                onRevert()
                dismiss()
            } label: {
                Label("Revert", systemImage: "arrow.uturn.backward")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .secondaryButton()
            if !stacked { keepButton }
        }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var keepButton: some View {
        Button {
            Haptics.success()
            sealed = true
            onKeep()
            Task {
                try? await Task.sleep(for: .milliseconds(reduceMotion ? 250 : 900))
                dismiss()
            }
        } label: {
            Label("Keep changes", systemImage: "checkmark")
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 28)
        }
        .primaryButton()
    }

    /// A tick and a burst of sparkles as the change is kept.
    @ViewBuilder
    private var seal: some View {
        if sealed {
            ZStack {
                Color.paper.opacity(0.9).ignoresSafeArea()
                AISparkleBurst()
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(AIStyle.linear)
                    .symbolEffect(.bounce, options: .nonRepeating)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
            .transition(.opacity)
        }
    }
}

extension TextDiff {
    /// The comparison as one string: removed words struck through in red, added
    /// ones shaded green.
    var attributed: AttributedString {
        var out = AttributedString()
        var previous: Kind?
        for segment in segments {
            // A word and its replacement would otherwise touch ("HiHello").
            if previous == .removed, segment.kind == .added { out += AttributedString("\u{2009}") }
            previous = segment.kind
            var piece = AttributedString(segment.text)
            switch segment.kind {
            case .same:
                break
            case .added:
                piece.backgroundColor = Color.olive.opacity(0.28)
            case .removed:
                piece.backgroundColor = Color.danger.opacity(0.16)
                piece.foregroundColor = Color.danger
                piece.strikethroughStyle = .single
            }
            out += piece
        }
        return out
    }
}
