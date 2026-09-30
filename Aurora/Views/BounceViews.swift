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

/// The card a list of bounces opens with: how many, what that means, and the
/// one action that deals with all of them.
struct BounceSummaryCard: View {
    let count: Int
    let message: String
    let onMarkAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(count == 1 ? "1 address bounced" : "\(count) addresses bounced")
                    .font(.headline)
                    .foregroundStyle(.ink)
            } icon: {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .foregroundStyle(.statusInvalid)
            }
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Haptics.press()
                onMarkAll()
            } label: {
                Text(count == 1 ? "Mark as Invalid" : "Mark All \(count) as Invalid")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .filledButton(.statusInvalid, label: .paper)
            .controlSize(.large)
        }
        .padding(16)
        .panel(accent: .statusInvalid)
        .accessibilityElement(children: .contain)
    }
}

/// One bounced address in a list: who, and why, in words — tap it to deal
/// with it; Mark Invalid is right there for the common case.
///
/// VoiceOver reads it as one sentence and offers Mark Invalid and Not a Bounce
/// as actions on it, so neither needs finding by touch. At the largest text
/// sizes the button moves under the text rather than squeezing it.
struct BounceListRow: View {
    let item: BouncedContact
    let onOpen: () -> Void
    let onMark: () -> Void
    let onDismiss: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let reason = item.bounce.reason
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        layout {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 12) {
                    if !typeSize.isAccessibilitySize {
                        MonogramAvatar(text: item.contact.displayName, size: Theme.Avatar.small)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.contact.displayName)
                            .font(.headline)
                            .foregroundStyle(.ink)
                        Text(item.contact.email)
                            .font(.subheadline)
                            .foregroundStyle(.inkMuted)
                            .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                            .truncationMode(.middle)
                        // Icon and words tight together, as one phrase.
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Image(systemName: reason.systemImage)
                                .imageScale(.small)
                            Text(reason.label)
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.statusInvalid)
                        .padding(.top, 2)
                        Text(([item.company].filter { !$0.isEmpty } + ["bounced " + item.bounce.at.activityPhrase])
                            .joined(separator: " · "))
                            .font(.footnote)
                            .foregroundStyle(.inkMuted)
                    }
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
                Text("Mark Invalid")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 30)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(.statusInvalid)
            // Its action is already on the row for VoiceOver.
            .accessibilityHidden(true)
        }
        .padding(14)
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

            if let snippet = bounce.snippet, !snippet.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("What their server said")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.inkMuted)
                    Text(snippet)
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
