import SwiftUI

/// The small status chip contacts wear in lists — "Sent 3 days ago",
/// "Invalid", "New". One shape, one type size, one padding, so a row that shows
/// two of them side by side still reads as one row rather than two competing
/// badges.
struct StatusChip: View {
    let text: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(color.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
        // Intrinsic width so the chip can never be squeezed — the name beside it
        // truncates instead.
        .fixedSize(horizontal: true, vertical: false)
        // A chip is almost always *replacing* another one — Sent becoming
        // Replied, anything becoming Invalid. Springing in from the trailing edge
        // it shares with the chip it replaced makes that read as a swap rather
        // than as two unrelated fades.
        .transition(LiquidMaterialize(scale: 0.7, anchor: .trailing))
    }
}

/// A company's outreach state as one line of chips — replies, and how long the
/// rest have been quiet — shared by the Home and Companies cards.
///
/// The line always holds at least one chip. It used to appear only once someone
/// had been mailed, so a company you'd started on was a line taller than one you
/// hadn't, and the list's rows jumped between two heights as you scrolled.
/// Saying "not mailed yet" is also more use than saying nothing.
struct OutreachChips: View {
    let job: Job

    var body: some View {
        let replied = job.repliedContacts.count
        let quiet = job.quietDays
        HStack(spacing: 6) {
            if replied > 0 {
                StatusChip(text: "\(replied) replied",
                           systemImage: "arrowshape.turn.up.left.fill",
                           color: .statusDone)
            }
            if let quiet {
                StatusChip(text: quiet == 0 ? "Sent today" : "\(quiet)d quiet",
                           systemImage: "hourglass",
                           color: .statusWaiting)
            }
            if replied == 0 && quiet == nil {
                StatusChip(text: job.contacts.isEmpty ? "No contacts" : "Not mailed yet",
                           systemImage: job.contacts.isEmpty ? "person.slash" : "sparkle",
                           color: .inkFaint)
            }
        }
    }
}

/// The "already mailed" chip, shared by every list that shows contacts.
///
/// Deliberately grey, not green: green is reserved for a reply. When both chips
/// were green, a row that had merely been sent looked exactly as good as one that
/// had been answered.
///
/// Three screens had grown their own copy of this — the company detail list, the
/// Suggested drawer, and (missing entirely) the compose recipient list — which is
/// why the same fact rendered three different ways, or not at all. One component
/// keeps the wording, colour and shape identical wherever a contact appears.
struct SentPill: View {
    let sentAt: Date?
    /// What to show for a contact that has never been mailed. Leave nil to render
    /// nothing at all, which is what a list of *pending* contacts wants.
    var unsentLabel: String? = nil

    var body: some View {
        if let sentAt {
            // The glyph already says "sent"; repeating it in words cost enough
            // width to truncate the recipient's name beside it.
            StatusChip(text: sentAt.activityLabel,
                       systemImage: "clock.arrow.circlepath", color: .inkMuted)
        } else if let unsentLabel {
            StatusChip(text: unsentLabel, systemImage: "sparkle", color: .accentColor)
        }
    }
}

/// The "they wrote back" chip. Outranks the sent chip in a row: once someone has
/// replied, when the mail went out stops being the useful fact.
struct RepliedPill: View {
    let at: Date?

    var body: some View {
        StatusChip(text: at?.activityLabel ?? "Replied",
                   systemImage: "arrowshape.turn.up.left.fill", color: .statusDone)
    }
}

/// The "ruled out" chip: this address bounces, or the person has left. Orange
/// rather than red — the contact isn't gone or broken, it's just been set aside,
/// and it can be put back with one swipe.
struct InvalidPill: View {
    var body: some View {
        StatusChip(text: "Invalid", systemImage: "exclamationmark.triangle.fill",
                   color: .statusInvalid)
    }
}

/// A mail domain as a chip. `listed` domains are saved on the company and solid;
/// the others are only seen on its contacts' addresses, and dashed.
struct DomainChip: View {
    let domain: String
    var listed = true

    var body: some View {
        Text("@\(domain)")
            .font(.caption.weight(.semibold).monospaced())
            .foregroundStyle(listed ? Color.clay : Color.inkMuted)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background {
                if listed {
                    Capsule().fill(Color.clay.opacity(0.12))
                } else {
                    Capsule().strokeBorder(Color.inkFaint.opacity(0.6),
                                           style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
            }
            .contentShape(.capsule)
            .accessibilityLabel(listed ? domain : "\(domain), from contacts")
    }
}
