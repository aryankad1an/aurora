import SwiftUI

/// A company as a card in a list. Home's tracked companies and the Companies
/// catalog share it, so one company reads the same way on both screens — and
/// its figures are the company screen's `OutreachStats`, set compactly as an
/// `OutreachMeter`.
///
/// One column beside the logo: name and when mail last went out, the
/// subtitle, then how far outreach has got as a bar with its legend. Half
/// the height of the old four-column strip, so a screen holds twice the
/// companies, and every card is the same height whatever the company's state.
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
        HStack(alignment: .top, spacing: 12) {
            CompanyLogo(job: job, size: Theme.Avatar.small)
                .fresherBadge(for: job, size: 15)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
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
                    // Fills the row, so the name only truncates when it really
                    // doesn't fit — not to share the room with a Spacer.
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if let last = job.lastSentAt {
                        Label(last.agoLabel, systemImage: "paperplane")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                            .foregroundStyle(.inkMuted)
                            .lineLimit(1)
                            .fixedSize()
                            .accessibilityLabel("Last sent \(last.agoLabel)")
                    }
                }

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.inkMuted)
                    .lineLimit(1)

                OutreachMeter(job: job)
                    .padding(.top, 6)
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.inkFaint)
                // Level with the name, not centred on the whole card.
                .padding(.top, 4)
        }
        .padding(12)
        .panel()
        .animation(Theme.Motion.pop, value: isTracked)
        .animation(Theme.Motion.pop, value: job.isFresher)
    }
}

/// `OutreachStats`' figures set small, for a card: one bar of the company's
/// valid people — contacted, the replied among them, and the rest still to
/// contact — over a legend naming each part. Counted exactly as the strip
/// counts them, so a card and its company screen always agree.
struct OutreachMeter: View {
    let job: Job

    var body: some View {
        let contacted = job.contactedContacts.count
        let uncontacted = job.uncontactedContacts.count
        let replied = job.repliedContacts.count
        // Replies count invalid contacts too; the bar is valid people only, so
        // its green never runs past the contacted part it's a share of.
        let repliedShare = min(replied, contacted)

        VStack(alignment: .leading, spacing: 6) {
            SegmentMeter(segments: [(contacted - repliedShare, .clay), (repliedShare, .statusDone)],
                         total: contacted + uncontacted, height: 5)

            if contacted + uncontacted == 0 {
                Text("No one to contact yet")
                    .font(.caption)
                    .foregroundStyle(.inkFaint)
            } else {
                WrappingHStack(spacing: 12, lineSpacing: 3) {
                    if contacted > 0 { item(contacted, "contacted", .clay) }
                    if replied > 0 { item(replied, "replied", .statusDone) }
                    if uncontacted > 0 { item(uncontacted, "to contact", .inkFaint) }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func item(_ count: Int, _ caption: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            let figure = Text(count.formatted()).foregroundStyle(.ink).fontWeight(.semibold)
            Text("\(figure) \(caption)")
                .font(.caption)
                .foregroundStyle(.inkMuted)
                .monospacedDigit()
                .lineLimit(1)
                .contentTransition(.numericText())
        }
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
/// The one place these figures are worked out and laid out for the company
/// screen's header; the Home and Companies cards show the same counts as an
/// `OutreachMeter`.
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
