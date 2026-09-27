import SwiftUI

/// A mail that was sent, shown the way Mail shows a message: who it went to
/// and when, the subject set large, then the body exactly as it was delivered.
/// When they answered, the reply sits above it. Shown from Activity, Quick
/// Actions and a contact's send history.
///
/// It used to be a settings-style form — Name, Email, Company and Position as
/// four labelled rows, the subject and body as two more — which read as a
/// record about a mail rather than as the mail.
struct MailSummaryView: View {
    let contact: Contact
    let company: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// "Sent 17 Sep 2026 at 3:55 PM".
    private var sentStamp: String {
        guard let sentAt = contact.sentAt else { return "Date not recorded" }
        return "Sent " + sentAt.formatted(date: .long, time: .shortened)
    }

    /// How long they took to answer, in whole days.
    private var turnaround: String? {
        guard let sent = contact.sentAt, let replied = contact.repliedAt,
              let days = Calendar.current.dateComponents([.day], from: sent, to: replied).day else {
            return nil
        }
        return days == 0 ? "the same day" : "\(days) day\(days == 1 ? "" : "s")"
    }

    /// Who answered, when it wasn't the address the mail went to — the normal
    /// case for a shared inbox, so it's worth saying.
    private var otherReplier: String? {
        guard let from = contact.replyFrom, !from.isEmpty,
              !from.localizedCaseInsensitiveContains(contact.email) else { return nil }
        return from
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if contact.hasReplied { reply }
                    letter
                }
                .padding(.horizontal, Theme.Space.gutter)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .paperScreen()
            .navigationTitle(contact.hasReplied ? "Replied" : "Sent Mail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Haptics.tap(0.5)
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - The mail

    private var letter: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                MonogramAvatar(text: contact.displayName, size: Theme.Avatar.medium)
                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.displayName)
                        .font(.headline)
                        .foregroundStyle(.ink)
                        .lineLimit(1)
                    if !contact.email.isEmpty {
                        Text(contact.email)
                            .font(.subheadline)
                            .foregroundStyle(.inkMuted)
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }
                    let role = [contact.position, company].filter { !$0.isEmpty }.joined(separator: " · ")
                    if !role.isEmpty {
                        Text(role)
                            .font(.caption)
                            .foregroundStyle(.inkMuted)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)

            Divider().overlay(Color.hairline)

            VStack(alignment: .leading, spacing: 10) {
                let subject = contact.sentSubject.flatMap { $0.isEmpty ? nil : $0 }
                Text(subject ?? "No subject recorded")
                    .font(.display(20))
                    .foregroundStyle(subject == nil ? Color.inkFaint : Color.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(sentStamp)
                    .font(.caption)
                    .foregroundStyle(.inkFaint)

                if let body = contact.sentBody, !body.isEmpty {
                    Text(body)
                        .font(.callout)
                        .foregroundStyle(Color.ink.opacity(0.88))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                } else {
                    Text("The message itself wasn't recorded for this mail.")
                        .font(.callout)
                        .foregroundStyle(.inkFaint)
                        .padding(.top, 4)
                }
            }
            .padding(14)
        }
        .panel(radius: Theme.Radius.hero)
    }

    // MARK: - The answer

    /// Only the opening lines of a reply are stored — enough to recognise it and
    /// decide whether to open Gmail, without the app keeping a copy of someone
    /// else's mail.
    private var reply: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("They replied", systemImage: "arrowshape.turn.up.left.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.statusDone)
                Spacer(minLength: 8)
                if let repliedAt = contact.repliedAt {
                    Text(repliedAt.activityLabel)
                        .font(.caption)
                        .foregroundStyle(.statusDone)
                }
            }

            if let snippet = contact.replyPreview {
                Text(snippet)
                    .font(.callout)
                    .foregroundStyle(.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            let details = [turnaround.map { "After \($0)" }, otherReplier.map { "from \($0)" }]
                .compactMap { $0 }.joined(separator: " · ")
            if !details.isEmpty {
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.inkMuted)
            }

            Button {
                Haptics.tap()
                openGmail()
            } label: {
                Label("Open Gmail", systemImage: "arrow.up.forward.app")
                    .font(.subheadline.weight(.semibold))
            }
            .secondaryButton()
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(accent: .statusDone, radius: Theme.Radius.hero)
    }

    /// The Gmail app when it's installed, the web inbox when it isn't.
    private func openGmail() {
        guard let app = URL(string: "googlegmail://"),
              let web = URL(string: "https://mail.google.com/mail/") else { return }
        openURL(app) { opened in
            if !opened { openURL(web) }
        }
    }
}
