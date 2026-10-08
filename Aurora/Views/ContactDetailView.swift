import SwiftUI

/// A contact's details: contact fields (read-only until you tap the pencil,
/// then saved upstream to the shared database) plus this user's send history —
/// tapping a history entry opens that sent mail.
///
/// This is also where a contact is ruled in or out. Marking invalid lives beside
/// the address rather than only in the list, because the two things you want to
/// do about a bounced mail — fix the address, or give up on it — belong on the
/// same screen.
struct ContactDetailView: View {
    let contact: Contact
    let company: String
    /// Write to this person. The presenter closes this sheet and opens the
    /// compose sheet in its place — two can't be up at once.
    var onCompose: (() -> Void)? = nil
    let onSetValidity: (Bool) -> Void
    let onSave: (Contact) -> Void

    @Environment(JobStore.self) private var jobStore
    @Environment(ReplySync.self) private var replySync
    @Environment(\.dismiss) private var dismiss

    @State private var isEditing = false
    @State private var email: String
    @State private var name: String
    @State private var phone: String
    @State private var position: String
    @State private var greetingName: String
    /// The last-saved values, so Cancel reverts correctly even after a save.
    @State private var committed: Contact
    /// Mirrors the contact's shared valid/invalid flag so the sheet updates the
    /// moment you tap, without waiting for the round-trip and reload behind it.
    @State private var isContactValid: Bool
    /// The rule-in/rule-out tap, held until it's confirmed.
    @State private var pendingValidity: ValidityChange?

    @State private var history: [MailSend] = []
    @State private var isLoadingHistory = true
    @State private var selectedSend: MailSend?
    @State private var confirmingDiscard = false
    /// Flips the Copy button to "Copied" for a moment after it's used.
    @State private var copied = false

    init(contact: Contact, company: String,
         onCompose: (() -> Void)? = nil,
         onSetValidity: @escaping (Bool) -> Void,
         onSave: @escaping (Contact) -> Void) {
        self.contact = contact
        self.company = company
        self.onCompose = onCompose
        self.onSetValidity = onSetValidity
        self.onSave = onSave
        _email = State(initialValue: contact.email)
        _name = State(initialValue: contact.name)
        _phone = State(initialValue: contact.phone ?? "")
        _position = State(initialValue: contact.position)
        _greetingName = State(initialValue: contact.greetingName ?? "")
        _committed = State(initialValue: contact)
        _isContactValid = State(initialValue: contact.isValid)
    }

    /// The address's bounce, while there's one to deal with. Gone as soon as the
    /// address is corrected, the contact is ruled out, or it's dismissed.
    private var bounce: Bounce? {
        guard replySync.bounces[contact.id] != nil else { return nil }
        return jobStore.bouncedContacts(from: replySync).first { $0.contact.id == contact.id }?.bounce
    }

    /// Whether the edited fields are complete enough to save. (Not to be confused
    /// with `isContactValid`, which is whether the *person* is still worth mailing.)
    private var canSave: Bool {
        ContactFields.isValid(email: email, name: name)
    }

    /// True when at least one field differs from the last-saved state. Compared
    /// the way `save()` would store it, so a field that only differs in what
    /// saving normalizes away (an address's case) doesn't count as an edit.
    private var hasChanges: Bool {
        Self.editableFields(of: draft) != Self.editableFields(of: committed)
    }

    /// The form as `save()` would store it.
    private var draft: Contact {
        Contact(id: contact.id, email: email.lowercased(), name: name,
                phone: phone.isEmpty ? nil : phone, position: position,
                greetingName: greetingName.isEmpty ? nil : greetingName,
                isValid: isContactValid)
    }

    nonisolated private static func editableFields(of contact: Contact) -> [String?] {
        [contact.email.lowercased(), contact.name, contact.phone, contact.position, contact.greetingName]
    }

    var body: some View {
        NavigationStack {
            PaperForm {
                if !isEditing { header }

                if !isContactValid { invalidBanner }

                // A bounced address is the one thing about this contact that
                // needs deciding, so it comes before the fields.
                if let bounce, isContactValid, !isEditing {
                    BounceSection(bounce: bounce) {
                        pendingValidity = ValidityChange([committed], isValid: false)
                    } onFixAddress: {
                        Haptics.tap()
                        withAnimation(Theme.Motion.bouncy) { isEditing = true }
                    } onDismiss: {
                        Haptics.tap(0.5)
                        withAnimation(Theme.Motion.snappy) { replySync.dismissBounce(contact.id) }
                    }
                }

                // No company header: the card above already names it.
                ContactFields(email: $email, name: $name, position: $position, phone: $phone,
                              greetingName: $greetingName, isEditing: isEditing)

                // The bounce section above has its own Mark as Invalid.
                if bounce == nil || !isContactValid { validitySection }

                Section("Sent History") {
                    if isLoadingHistory {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Loading history…").foregroundStyle(.inkMuted)
                        }
                    } else if history.isEmpty {
                        Text("No mail sent to this contact yet.")
                            .foregroundStyle(.inkMuted)
                    } else {
                        ForEach(history) { send in
                            Button {
                                Haptics.tap()
                                selectedSend = send
                            } label: {
                                historyRow(send)
                            }
                            .tint(.ink)
                        }
                    }
                }
            }
            // The header carries the name, as a Contacts card does; the bar only
            // says so while the fields are open for editing.
            .navigationTitle(isEditing ? "Edit Contact" : "")
            .navigationBarTitleDisplayMode(.inline)
            // Laid out as Contacts lays out a card: Edit on the trailing side,
            // and while editing, Cancel and Save where Done and Edit were.
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isEditing {
                        Button("Cancel") {
                            if hasChanges {
                                Haptics.warning()
                                confirmingDiscard = true
                            } else {
                                Haptics.tap(0.5)
                                withAnimation(Theme.Motion.bouncy) { cancelEdit() }
                            }
                        }
                    } else {
                        Button("Done") {
                            Haptics.tap(0.5)
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isEditing {
                        Button("Save") { save() }.disabled(!canSave || !hasChanges)
                    } else {
                        Button("Edit") {
                            Haptics.tap()
                            withAnimation(Theme.Motion.bouncy) { isEditing = true }
                        }
                    }
                }
            }
            .interactiveDismissDisabled(isEditing && hasChanges)
            .alert("Discard your changes?", isPresented: $confirmingDiscard) {
                Button("Keep Editing", role: .cancel) {}
                Button("Discard Changes", role: .destructive) {
                    withAnimation(Theme.Motion.bouncy) { cancelEdit() }
                }
            } message: {
                Text("Your edits to this contact won't be saved.")
            }
            .task { await loadHistory() }
            .validityAlert($pendingValidity) { change in
                withAnimation(Theme.Motion.bouncy) { isContactValid = change.isValid }
                onSetValidity(change.isValid)
            }
            // An Undo tapped in the banner below reverts the stored contact; the
            // form follows it, unless it's mid-edit and the typing is the user's.
            .onChange(of: stored.map(Self.editableFields)) { _, _ in
                guard let stored, !isEditing else { return }
                committed = stored
                cancelEdit()
            }
            .undoBanner()
            .sheet(item: $selectedSend) { send in
                MailSummaryView(contact: contact(for: send), company: company, sendID: send.id)
            }
        }
    }

    /// Who this is, and the two things you open a contact to do: write to them,
    /// or take their address somewhere else. Drawn the way a Contacts card
    /// opens — the face, the name, the role — rather than as the first rows of
    /// a form.
    private var header: some View {
        Section {
            VStack(spacing: 12) {
                MonogramAvatar(text: committed.displayName, size: 76)
                    .grayscale(isContactValid ? 0 : 1)
                VStack(spacing: 3) {
                    Text(committed.displayName)
                        .font(.display(24))
                        .foregroundStyle(.ink)
                        .multilineTextAlignment(.center)
                    Text([committed.position, company].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.inkMuted)
                        .multilineTextAlignment(.center)
                }
                HStack(spacing: 10) {
                    actionTile("Mail", systemImage: "paperplane.fill",
                               isEnabled: onCompose != nil && isContactValid && committed.isMailable) {
                        Haptics.press()
                        onCompose?()
                    }
                    actionTile(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc",
                               isEnabled: !committed.email.isEmpty) {
                        UIPasteboard.general.string = committed.email
                        Haptics.success()
                        withAnimation(Theme.Motion.pop) { copied = true }
                        Task {
                            try? await Task.sleep(for: .seconds(1.6))
                            withAnimation(Theme.Motion.pop) { copied = false }
                        }
                    }
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        }
    }

    /// One of the card's action buttons: glyph over label in a small tile, the
    /// shape Contacts uses for Message, Call and Mail.
    private func actionTile(_ title: String, systemImage: String, isEnabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(height: 20)
                Text(title)
                    .font(.caption.weight(.medium))
                    .contentTransition(.opacity)
            }
            .foregroundStyle(isEnabled ? Color.clay : Color.inkFaint)
            .frame(width: 84, height: 58)
            .background(Color.paperRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Color.hairline, lineWidth: 1))
        }
        .buttonStyle(BouncyPress(scale: 0.92))
        .disabled(!isEnabled)
    }

    /// Says the state plainly at the top of the sheet, so an invalid contact is
    /// obvious the moment it opens — the dimmed row in the list is a hint, this is
    /// the answer.
    private var invalidBanner: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Marked invalid")
                        .font(.subheadline.weight(.semibold))
                    Text("Not suggested to anyone, and can't be mailed.")
                        .font(.caption)
                        .foregroundStyle(.inkMuted)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.statusInvalid)
                    .symbolEffect(.bounce, value: isContactValid)
            }
        }
        .popIn(anchor: .top)
    }

    /// The rule-in/rule-out control. Its own section under the fields: it isn't an
    /// edit to the contact's details (it applies once confirmed, with no Save),
    /// and the footer spells out that it lands for every user.
    private var validitySection: some View {
        Section {
            // It changes the shared row for every user, so it asks first; the
            // confirm plays the haptic for whichever of the two opposite acts
            // it was, since the banner above changing is ambiguous on its own.
            Button {
                pendingValidity = ValidityChange([committed], isValid: !isContactValid)
            } label: {
                // Icon and text are coloured explicitly rather than via `.tint`:
                // inside a Form the row keeps painting a button's icon with the
                // app accent, so the label came out half green, half blue.
                let colour = isContactValid ? Color.statusInvalid : Color.statusDone
                Label {
                    Text(isContactValid ? "Mark as Invalid" : "Mark as Valid")
                        .foregroundStyle(colour)
                } icon: {
                    Image(systemName: isContactValid
                          ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(colour)
                }
            }
        } footer: {
            Text(isContactValid
                 ? "For a bounced address or someone who has left. They stay on the company page for the record, but drop out of Suggested and can no longer be mailed — for every user."
                 : "Ruled out for every user. Fix the address above if it was wrong, then mark them valid to put them back in Suggested.")
        }
    }

    private func historyRow(_ send: MailSend) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "paperplane.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(send.sentAt?.formatted(date: .abbreviated, time: .shortened) ?? "Sent")
                    .font(.subheadline)
                    .lineLimit(1)
                // Always a second line, so the history rows are one height.
                let subject = send.subject.flatMap { $0.isEmpty ? nil : $0 }
                Text(subject ?? "No subject recorded")
                    .font(.caption)
                    .foregroundStyle(subject == nil ? Color.inkFaint : Color.inkMuted)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.inkFaint)
        }
        .padding(.vertical, 2)
    }

    /// A contact carrying this specific send's mail, for the summary drawer.
    private func contact(for send: MailSend) -> Contact {
        var c = Contact(id: contact.id, email: email, name: name,
                        phone: phone.isEmpty ? nil : phone, position: position,
                        greetingName: greetingName.isEmpty ? nil : greetingName)
        c.sentAt = send.sentAt
        c.sentSubject = send.subject
        c.sentBody = send.body
        return c
    }

    private func cancelEdit() {
        email = committed.email
        name = committed.name
        phone = committed.phone ?? ""
        position = committed.position
        greetingName = committed.greetingName ?? ""
        isEditing = false
    }

    private func loadHistory() async {
        defer { isLoadingHistory = false }
        guard let email = jobStore.userEmail else { return }
        history = (try? await SupabaseAPI.fetchSendHistory(userEmail: email, contactID: contact.id)) ?? []
    }

    /// This contact as the store currently holds it.
    private var stored: Contact? { jobStore.contact(id: contact.id) }

    private func save() {
        let updated = draft
        committed = updated
        email = updated.email      // reflect the lowercased email back in the field
        Haptics.success()
        onSave(updated)
        withAnimation(Theme.Motion.bouncy) { isEditing = false }
    }
}
