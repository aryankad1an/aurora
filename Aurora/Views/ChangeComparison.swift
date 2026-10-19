import SwiftUI

/// What a suggested change does to a text, for deciding whether to keep it: the
/// word-level comparison, or the result as it would read, in writing help.
///
/// A new answer arrives as plain text (what was just written) and the markup
/// then fades in over it, rather than appearing all at once, struck-through
/// words and all.
struct ChangeComparison: View {
    enum Tab: Hashable { case changes, result }

    let before: String
    let after: String
    @Binding var tab: Tab
    /// Whether the glow around the text keeps turning, while it's still in play.
    var isTurning = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    var body: some View {
        let diff = TextDiff(from: before, to: after)
        VStack(alignment: .leading, spacing: 14) {
            SegmentedSelector(segments: [(Tab.changes, "Changes"), (Tab.result, "Result")], selection: $tab)

            Text(tab == .changes && revealed ? diff.attributed : AttributedString(after))
                .font(.callout)
                .foregroundStyle(Color.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .panel()
                .overlay { AIGlowBorder(isTurning: isTurning, halo: 0.10).opacity(0.75) }
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.3), value: tab)

            if tab == .changes, revealed, diff.hasChanges {
                legend(diff)
                    .transition(.opacity)
            }
        }
        .task(id: after) {
            revealed = false
            if !reduceMotion { try? await Task.sleep(for: .milliseconds(450)) }
            withAnimation(.easeInOut(duration: reduceMotion ? 0.01 : 0.5)) { revealed = true }
        }
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
}

/// "+12 −4" (a side left out when it's nothing), "Spacing only" or "No
/// changes", beside a change under review.
struct ChangeTally: View {
    let diff: TextDiff

    var body: some View {
        Group {
            if diff.hasChanges, diff.addedWords == 0, diff.removedWords == 0 {
                // Only whitespace moved, which the word counts leave out.
                Text("Spacing only")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.inkMuted)
            } else if diff.hasChanges {
                HStack(spacing: 8) {
                    if diff.addedWords > 0 { Text("+\(diff.addedWords)").foregroundStyle(Color.olive) }
                    if diff.removedWords > 0 { Text("−\(diff.removedWords)").foregroundStyle(Color.danger) }
                }
                .font(.caption.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
            } else {
                Text("No changes")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.inkMuted)
            }
        }
        .accessibilityElement(children: .combine)
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
