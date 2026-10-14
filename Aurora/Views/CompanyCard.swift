import SwiftUI

/// A company as a card in a list. Home's tracked companies and the Companies
/// catalog share it, so one company reads the same way on both screens — and
/// its figures are `OutreachStats`, the same strip the company screen shows.
///
/// A header — logo (or monogram), name, head count and sector — over a strip of outreach
/// figures. The strip runs the card's full width, under the avatar too:
/// indented beside it, it lost a fifth of the card to empty space.
///
/// Always the same two parts whatever state the company is in, so every card
/// in a list is the same height and the list scrolls as an even column.
struct CompanyCard: View {
    let job: Job
    /// Shows the tracked pin — the catalog's cue. Home lists only tracked
    /// companies, so it leaves this off.
    var isTracked = false

    private var subtitle: String {
        var parts = [job.contacts.isEmpty
                     ? "No contacts yet"
                     : "\(job.contacts.count) contact\(job.contacts.count == 1 ? "" : "s")"]
        let invalid = job.invalidContacts.count
        if invalid > 0 { parts.append("\(invalid) invalid") }
        // An open fresher posting is the one fact worth the room before the
        // sector; that the company hires freshers at all, the badge says.
        if job.isFresher && job.isOpenNow { parts.append("Hiring freshers now") }
        if let sector = job.sector, !sector.isEmpty {
            parts.append(sector)
        } else if job.isFresher, let type = job.companyType, !type.isEmpty {
            parts.append(type)
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                CompanyLogo(job: job, size: Theme.Avatar.small)
                    .fresherBadge(for: job, size: 15)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(job.company)
                            .font(.headline)
                            .foregroundStyle(.ink)
                            .lineLimit(1)
                        if isTracked {
                            Image(systemName: "pin.fill")
                                .font(.caption2)
                                .foregroundStyle(.tint)
                                // The pin springs in the moment a swipe tracks
                                // the company, on the row the swipe happened on.
                                .transition(.scale(scale: 0.2).combined(with: .opacity))
                        }
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.inkMuted)
                        .lineLimit(1)
                }
                // Fills the row, so the name only truncates when it really
                // doesn't fit — not to share the room with a Spacer.
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.inkFaint)
            }

            Divider().overlay(Color.hairline)

            OutreachStats(job: job)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .panel()
        .animation(Theme.Motion.pop, value: isTracked)
        .animation(Theme.Motion.pop, value: job.isFresher)
    }
}

/// Where outreach at a company stands, as four figures: valid people mailed,
/// valid people not mailed yet, replies, and when the latest valid mail went
/// out. Invalid contacts are left out of all but the replies — a bounced mail
/// reached nobody, so it neither counts as contact nor starts a wait.
///
/// One row of four columns; two rows of two from the largest standard text
/// size up, rather than shrinking the captions into each other. Decided by
/// text size, not `ViewThatFits`: the row's total width still fit there, but
/// split into equal columns "To contact" overran its own.
///
/// The one place these figures are worked out and laid out: the Home and
/// Companies cards and the company screen's header all show this view.
struct OutreachStats: View {
    let job: Job
    /// Figure size: the cards' 20, the company screen's larger 22.
    var size: CGFloat = 20
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let contacted = job.contactedContacts.count
        let uncontacted = job.uncontactedContacts.count
        let replied = job.repliedContacts.count
        let last = job.lastSentAt

        let contactedMetric = Metric(value: contacted, caption: "Contacted",
                                     tint: contacted == 0 ? .inkFaint : .ink, size: size)
        let uncontactedMetric = Metric(value: uncontacted, caption: "To contact",
                                       tint: uncontacted == 0 ? .inkFaint : .ink, size: size)
        let repliedMetric = Metric(value: replied, caption: "Replied",
                                   tint: replied == 0 ? .inkFaint : .statusDone, size: size)
        let lastMetric = Metric(text: last?.agoLabel ?? "—", caption: "Last sent",
                                tint: last == nil ? .inkFaint : .ink, size: size)

        Group {
            if typeSize < .xxxLarge {
                HStack(spacing: 0) {
                    contactedMetric
                    MetricDivider()
                    uncontactedMetric
                    MetricDivider()
                    repliedMetric
                    MetricDivider()
                    lastMetric
                }
            } else {
                Grid(horizontalSpacing: 0, verticalSpacing: 10) {
                    GridRow {
                        contactedMetric
                        uncontactedMetric
                    }
                    GridRow {
                        repliedMetric
                        lastMetric
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
