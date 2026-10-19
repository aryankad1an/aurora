import SwiftUI

/// A company as a card in a list. Home's tracked companies and the Companies
/// catalog share it, so one company reads the same way on both screens, with
/// the company screen's own counts (`OutreachStats`).
///
/// Just what tells you where you are with a company: its name and when mail
/// last went out, how many of its people you've reached and how many replied,
/// and the same as a slim bar. The sector, invalid addresses and the rest are
/// on the company's screen, a tap away.
struct CompanyCard: View {
    let job: Job
    /// Whether the company is on Home. Home lists only tracked companies, so
    /// it leaves this off.
    var isTracked = false
    /// Tracks or untracks it from the card — the catalog's one-tap way onto
    /// Home, in place of the chevron. Without it the card shows the chevron
    /// and, when tracked, a small pin by the name.
    var onToggleTrack: (() -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var typeSize

    /// At accessibility sizes the name gets the whole line and wraps; the
    /// last-sent time moves under it.
    private var wide: Bool { typeSize.isAccessibilitySize }

    var body: some View {
        // Counted exactly as the company screen counts them: valid people only,
        // replies from anyone.
        let contacted = job.contactedContacts.count
        let total = contacted + job.uncontactedContacts.count
        let replied = job.repliedContacts.count

        HStack(alignment: .center, spacing: 12) {
            CompanyLogo(job: job, size: Theme.Avatar.small)
                .fresherBadge(for: job, size: 15)

            VStack(alignment: .leading, spacing: 5) {
                (wide ? AnyLayout(VStackLayout(alignment: .leading, spacing: 3))
                      : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))) {
                    HStack(spacing: 5) {
                        Text(job.company)
                            .font(.headline)
                            .foregroundStyle(.ink)
                            .lineLimit(wide ? 3 : 1)
                            .fixedSize(horizontal: false, vertical: wide)
                        if isTracked && onToggleTrack == nil {
                            Image(systemName: "pin.fill")
                                .font(.caption2)
                                .foregroundStyle(.tint)
                                // The pin springs in the moment a swipe tracks
                                // the company, on the row the swipe happened on.
                                .transition(.scale(scale: 0.2).combined(with: .opacity))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if let last = job.lastSentAt {
                        Text(last.agoLabel)
                            .font(.caption)
                            .foregroundStyle(.inkFaint)
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize()
                            .accessibilityLabel("Last sent \(last.agoLabel)")
                    }
                }

                status(contacted: contacted, total: total, replied: replied)

                if total > 0 {
                    // Replies count invalid contacts too; the bar is valid people
                    // only, so its green never runs past the contacted part. The
                    // contacted part is a quiet accent: a list of cards each
                    // with a full bar of it would be all orange.
                    let repliedShare = min(replied, contacted)
                    SegmentMeter(segments: [(contacted - repliedShare, Color.clay.opacity(0.5)),
                                            (repliedShare, .statusDone)],
                                 total: total, height: 3)
                        .padding(.top, 2)
                }
            }

            if let onToggleTrack {
                // Filled once tracked, so the catalog shows at a glance what's
                // already on Home. The card itself still opens the company.
                CircleIconButton(
                    systemImage: isTracked ? "pin.fill" : "pin",
                    isOn: isTracked,
                    accessibilityLabel: isTracked ? "Untrack \(job.company)" : "Track \(job.company)",
                    action: onToggleTrack
                )
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.inkFaint)
            }
        }
        .padding(14)
        .panel()
        .accessibilityElement(children: .combine)
        .animation(Theme.Motion.pop, value: isTracked)
        .animation(Theme.Motion.pop, value: job.isFresher)
    }

    /// One line: how far outreach has got, and the replies when there are any.
    private func status(contacted: Int, total: Int, replied: Int) -> some View {
        let reach: Text
        if total == 0 {
            reach = Text(job.contacts.isEmpty ? "No contacts yet" : "No one to contact")
        } else if contacted == 0 {
            reach = Text("\(total) to contact")
        } else {
            reach = Text("\(contacted) of \(total) contacted")
        }
        let line = replied > 0
            ? Text("\(reach)  ·  \(Text("\(replied) replied").foregroundStyle(.statusDone))")
            : reach
        return line
            .font(.subheadline)
            .foregroundStyle(.inkMuted)
            .monospacedDigit()
            .lineLimit(wide ? 3 : 1)
            .fixedSize(horizontal: false, vertical: wide)
            .contentTransition(.numericText())
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
/// screen's header; the Home and Companies cards show the same counts in a line.
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
