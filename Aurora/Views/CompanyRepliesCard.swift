import SwiftUI

/// A company's replies, newest first: who wrote back, when, and what they said.
/// One panel on the company's screen, between its hiring details and the
/// contacts, so the answers aren't left to be found one contact at a time.
///
/// Shows the latest few and folds the rest behind "Show all", so a company
/// that answered often doesn't push its contacts off the screen.
struct CompanyRepliesCard: View {
    /// The company's contacts who replied, in any order.
    let replied: [Contact]
    /// How many of the company's contacts were mailed, for the summary line.
    let contacted: Int
    let onOpen: (Contact) -> Void

    @State private var isExpanded = false

    /// How many show before "Show all".
    private static let folded = 3

    private var sorted: [Contact] {
        replied.sorted { ($0.repliedAt ?? .distantPast) > ($1.repliedAt ?? .distantPast) }
    }

    var body: some View {
        let all = sorted
        let shown = isExpanded ? all : Array(all.prefix(Self.folded))
        VStack(alignment: .leading, spacing: 0) {
            header(count: all.count)
                .padding(14)
            ForEach(shown) { contact in
                Divider().overlay(Color.hairline)
                row(contact)
            }
            if all.count > Self.folded {
                Divider().overlay(Color.hairline)
                Button {
                    Haptics.tap()
                    withAnimation(Theme.Motion.snappy) { isExpanded.toggle() }
                } label: {
                    Text(isExpanded ? "Show Fewer" : "Show All \(all.count)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.clay)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .panelAccented(.olive)
    }

    private func header(count: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.body)
                .foregroundStyle(Color.olive)
            VStack(alignment: .leading, spacing: 2) {
                Text("Replies")
                    .font(.headline)
                    .foregroundStyle(Color.ink)
                Text(contacted > 0 ? "\(count) of \(contacted) contacted wrote back" : "\(count) wrote back")
                    .font(.caption)
                    .foregroundStyle(Color.inkMuted)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func row(_ contact: Contact) -> some View {
        Button {
            Haptics.tap()
            onOpen(contact)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                // Name and date share a line until the text is too big for it.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        name(contact)
                        Spacer(minLength: 0)
                        date(contact).fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        name(contact)
                        date(contact)
                    }
                }
                if let snippet = contact.replyPreview {
                    HStack(spacing: 7) {
                        Capsule().fill(Color.olive).frame(width: 2.5)
                        Text(snippet)
                            .font(.caption)
                            .foregroundStyle(.inkMuted)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("No preview captured")
                        .font(.caption)
                        .foregroundStyle(.inkFaint)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(CardPress())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows the mail and the reply")
    }

    private func name(_ contact: Contact) -> some View {
        Text(contact.displayName)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.ink)
            .lineLimit(2)
    }

    private func date(_ contact: Contact) -> some View {
        Text(contact.repliedAt?.activityLabel ?? "Replied")
            .font(.caption)
            .foregroundStyle(Color.olive)
    }
}
