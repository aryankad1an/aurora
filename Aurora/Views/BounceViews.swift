import SwiftUI

// The pieces every screen draws a bounce with — Activity's Bounced lane, the
// company page, and the contact sheet — so a bounce reads the same wherever
// it's met.

extension BounceReason {
    /// What the reason means, in a sentence.
    var explanation: String {
        switch self {
        case .addressNotFound:
            "The mail server says this address doesn't exist. It may be a typo, or the person may have left."
        case .domainNotFound:
            "The part after the @ isn't a working mail domain. That's almost always a typo."
        case .mailboxFull:
            "The mailbox exists but is full. It may start accepting mail again, so this one is worth a second try later."
        case .rejected:
            "Their server refused the mail — often a spam filter or a company policy rather than a dead address."
        case .other:
            "The mail couldn't be delivered. The server's own message is below."
        }
    }

    /// Whether giving up on the address is the likely answer. For a full
    /// mailbox or a refusal it often isn't, and the screen says so.
    var suggestsInvalid: Bool {
        switch self {
        case .addressNotFound, .domainNotFound, .other: true
        case .mailboxFull, .rejected: false
        }
    }
}

/// The "this address bounced" chip, for a contact row.
struct BouncedPill: View {
    var body: some View {
        StatusChip(text: "Bounced", systemImage: "arrow.uturn.backward.circle.fill", color: .statusInvalid)
    }
}

/// The card a list of bounces opens with: how many, what to do about them,
/// and the one action that deals with all of them.
struct BounceSummaryCard: View {
    let count: Int
    let message: String
    let onMarkAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                IconTile(systemImage: "arrow.uturn.backward", tint: .statusInvalid)
                VStack(alignment: .leading, spacing: 3) {
                    Text(count == 1 ? "1 address bounced" : "\(count) addresses bounced")
                        .font(.headline)
                        .foregroundStyle(.ink)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)

            Button {
                Haptics.press()
                onMarkAll()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle.badge.xmark")
                        .imageScale(.small)
                    Text(count == 1 ? "Mark as Invalid" : "Mark All \(count) as Invalid")
                }
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)
            }
            .filledButton(.statusInvalid, label: .paper)
        }
        .padding(14)
        .panel(accent: .statusInvalid)
        .accessibilityElement(children: .contain)
    }
}

/// One bounced address in a list, set like a contact on a company's page:
/// who, the address, and why it came back — with Mark Invalid as a round
/// button at the end, where a contact row has its send button, so it
/// never squeezes the words beside it. Tap the row to deal with it in full.
///
/// VoiceOver reads it as one sentence and offers Mark Invalid and Not a Bounce
/// as actions on it, so neither needs finding by touch.
struct BounceListRow: View {
    let item: BouncedContact
    let onOpen: () -> Void
    let onMark: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        let reason = item.bounce.reason
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    MonogramAvatar(text: item.contact.displayName, size: Theme.Avatar.small)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(item.contact.displayName)
                                .font(.headline)
                                .foregroundStyle(.ink)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text(item.bounce.at.activityLabel)
                                .font(.caption)
                                .foregroundStyle(.inkFaint)
                                .lineLimit(1)
                                .fixedSize()
                        }
                        Text(item.contact.email)
                            .font(.caption)
                            .foregroundStyle(.inkMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        // Why, then whose — one line, so every row is the same
                        // height. Whose goes first when both don't fit, rather
                        // than shrinking to "A…".
                        let why = Text("\(Image(systemName: reason.systemImage)) \(reason.label)")
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.statusInvalid)
                        let whose = Text(item.company.isEmpty ? "" : "  ·  \(item.company)")
                            .foregroundStyle(Color.inkFaint)
                        ViewThatFits(in: .horizontal) {
                            Text("\(why)\(whose)").fixedSize()
                            why
                        }
                        .font(.caption)
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(item.contact.displayName), \(item.contact.email)"
                                + (item.company.isEmpty ? "" : ", \(item.company)")
                                + ". Bounced \(item.bounce.at.activityPhrase): \(reason.label).")
            .accessibilityHint("Opens the contact, to see why, fix the address, or mark it invalid.")
            .accessibilityAction(named: "Mark as Invalid", onMark)
            .accessibilityAction(named: "Not a Bounce", onDismiss)

            Button {
                Haptics.press()
                onMark()
            } label: {
                Image(systemName: "nosign")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.statusInvalid)
                    .frame(width: 36, height: 36)
                    .background(Color.statusInvalid.opacity(0.14), in: Circle())
            }
            .buttonStyle(BouncyPress(scale: 0.82))
            // Its action is already on the row for VoiceOver.
            .accessibilityHidden(true)
        }
        .padding(12)
        .panel(accent: .statusInvalid)
        .contextMenu {
            Button(action: onOpen) { Label("Open Contact", systemImage: "person.text.rectangle") }
            Button(action: onMark) { Label("Mark as Invalid", systemImage: "person.crop.circle.badge.xmark") }
            Button(action: onDismiss) { Label("Not a Bounce", systemImage: "arrow.uturn.backward") }
        }
    }
}

/// The contact sheet's account of a bounce: what came back and when, what it
/// means, what the server said — and the three things to do about it.
struct BounceSection: View {
    let bounce: Bounce
    let onMarkInvalid: () -> Void
    let onFixAddress: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        let reason = bounce.reason
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(reason.label)
                        .font(.headline)
                        .foregroundStyle(.ink)
                } icon: {
                    Image(systemName: reason.systemImage)
                        .foregroundStyle(.statusInvalid)
                }
                Text(reason.explanation)
                    .font(.subheadline)
                    .foregroundStyle(.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)

            if let message = bounce.serverMessage, !message.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(bounce.status.map { "What their server said · \($0)" } ?? "What their server said")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.inkMuted)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
            }

            // Row buttons, full width, so each is an easy target.
            Button(action: onFixAddress) {
                Label("Fix the Address", systemImage: "pencil")
            }
            Button(action: onMarkInvalid) {
                Label {
                    Text("Mark as Invalid").foregroundStyle(Color.statusInvalid)
                } icon: {
                    Image(systemName: "person.crop.circle.badge.xmark").foregroundStyle(Color.statusInvalid)
                }
            }
            Button(action: onDismiss) {
                Label("Not a Bounce", systemImage: "arrow.uturn.backward")
            }
        } header: {
            Label("This address bounced", systemImage: "arrow.uturn.backward.circle.fill")
                .foregroundStyle(.statusInvalid)
                .font(.subheadline.weight(.semibold))
                .textCase(nil)
        } footer: {
            Text(reason.suggestsInvalid
                 ? "Came back \(bounce.at.formatted(date: .abbreviated, time: .shortened)). Fix the address if it's a typo; otherwise mark it invalid so it isn't mailed again, by anyone."
                 : "Came back \(bounce.at.formatted(date: .abbreviated, time: .shortened)). This may not mean the address is dead, so marking it invalid isn't the only answer.")
                .font(.footnote)
                .foregroundStyle(.inkMuted)
        }
    }
}
