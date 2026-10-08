import SwiftUI

/// Add or edit a mail template.
///
/// The editor is built around one idea: a template is never wrong on its own —
/// it's wrong against *your* profile and *your* contacts, and you only find out
/// after the mail has gone to a hundred contacts. So the two halves of the
/// screen answer that directly. **Write** is a full-height composer with the
/// placeholder chips on the keyboard, where a status strip flags tokens that
/// aren't real, tokens your profile can't fill, and tokens your contacts are
/// missing. **Preview** renders the mail against a real contact, marking every
/// substitution — and every hole a substitution leaves behind.
struct TemplateEditorView: View {
    let existing: MailTemplate?
    let onSave: (MailTemplate) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(JobStore.self) private var jobStore
    @Environment(ProfileStore.self) private var profileStore
    @Environment(GmailAuthStore.self) private var gmail

    @State private var name: String
    @State private var subject: String
    @State private var content: String
    @State private var contentSelection: TextSelection?
    @State private var subjectSelection: TextSelection?
    @State private var mode: Mode = .write
    @State private var showingIssues = false
    /// Every contact in the catalog with their company, gathered once when the
    /// editor opens: Preview's random sample draws from it and the checks count
    /// against it. Rebuilt on each keystroke — several times per keystroke — it
    /// was the slowest thing on the screen.
    @State private var catalog: [(contact: Contact, company: String)] = []
    @State private var coverage = RecipientCoverage.none
    /// The contact Preview renders for, once one has been picked.
    @State private var pickedSample: (contact: Contact, company: String)?
    @State private var confirmingTestSend = false
    @State private var confirmingSaveWithErrors = false
    @State private var testSendResult: String?
    @State private var isTestSending = false
    @FocusState private var focus: Field?

    private enum Mode: Hashable { case write, preview }
    private enum Field: Hashable { case name, subject, content }

    init(existing: MailTemplate?, onSave: @escaping (MailTemplate) -> Void) {
        self.existing = existing
        self.onSave = onSave
        let t = existing ?? MailTemplate(name: "", subject: "", content: "")
        _name = State(initialValue: t.name)
        _subject = State(initialValue: t.subject)
        _content = State(initialValue: t.content)
    }

    /// Anything typed that the sheet would lose on Cancel.
    private var hasChanges: Bool {
        let original = existing ?? MailTemplate(name: "", subject: "", content: "")
        return name != original.name || subject != original.subject || content != original.content
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !subject.trimmingCharacters(in: .whitespaces).isEmpty
            && !content.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Diagnostics

    /// Run once per render, and handed to everything that shows a part of it.
    private func diagnose() -> [TemplateFinding] {
        TemplateDiagnostics.analyze(subject: subject, content: content,
                                    profile: profileStore.profile, recipients: coverage)
    }

    // MARK: - Preview subject

    /// A stand-in when the account has no contacts yet, so Preview is never a
    /// blank screen — you can still see the shape of the mail before your first
    /// company is tracked.
    private static let demoContact = (
        contact: Contact(id: "preview-demo", email: "priya.raghavan@example.com",
                         name: "Priya Raghavan", position: "University Recruiter"),
        company: "Acme Robotics"
    )

    private var sample: (contact: Contact, company: String) {
        pickedSample ?? catalog.first ?? Self.demoContact
    }

    private var sampleContext: MailContext {
        MailContext.make(contact: sample.contact, company: sample.company,
                         profile: profileStore.profile)
    }

    var body: some View {
        let findings = diagnose()
        let errorCount = findings.count { $0.severity == .error }
        NavigationStack {
            VStack(spacing: 0) {
                modePicker
                Divider()
                statusStrip(findings, errorCount: errorCount)

                switch mode {
                case .write: writePane
                case .preview: previewPane
                }
            }
            .paperScreen()
            .navigationTitle(existing == nil ? "New Template" : "Edit Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent(errorCount: errorCount) }
            .confirmAlert("Send a test to yourself?",
                          message: "One real mail goes to \(gmail.connectedEmail ?? "your inbox"), written as \(sample.contact.displayName) would get it.",
                          confirmLabel: "Send Test",
                          isPresented: $confirmingTestSend) { Task { await sendTest() } }
            .alert("Save with \(errorCount) unresolved \(errorCount == 1 ? "issue" : "issues")?",
                   isPresented: $confirmingSaveWithErrors) {
                Button("Keep Editing", role: .cancel) { showingIssues = true }
                Button("Save Anyway") { commit() }
            } message: {
                Text("Text that isn't a real placeholder is sent to contacts exactly as written.")
            }
            .discardableEdits(hasChanges, message: "What you've written in this template won't be saved.")
            .messageAlert("Test Mail", message: testSendResult) { testSendResult = nil }
            // A test send goes out to Gmail and back; the result lands after the
            // user has stopped watching the button.
            .sensoryFeedback(trigger: testSendResult != nil) { _, landed in
                landed ? .success : nil
            }
            // Preview re-renders whenever the sample or the text changes, and the
            // pane it swaps into is a different height.
            .animation(Theme.Motion.bouncy, value: mode)
            .animation(Theme.Motion.bouncy, value: showingIssues)
            .onAppear(perform: gatherCatalog)
        }
    }

    /// Take the catalog in once, and start Preview on someone from Home — the
    /// people this template is most likely about to go to.
    private func gatherCatalog() {
        guard catalog.isEmpty else { return }
        catalog = jobStore.allCompanies.flatMap { company in
            company.contacts.map { (contact: $0, company: company.company) }
        }
        coverage = RecipientCoverage(catalog.lazy.map(\.contact))
        if pickedSample == nil,
           let job = jobStore.jobs.first(where: { $0.validContacts.contains { !$0.position.isEmpty } }),
           let contact = job.validContacts.first(where: { !$0.position.isEmpty }) {
            pickedSample = (contact, job.company)
        }
    }

    private var modePicker: some View {
        SegmentedSelector(segments: [
            (Mode.write, "Write"),
            (Mode.preview, "Preview")
        ], selection: $mode)
            .padding(.horizontal)
            .padding(.bottom, 10)
    }

    @ToolbarContentBuilder
    private func toolbarContent(errorCount: Int) -> some ToolbarContent {
        // Cancel (from `discardableEdits`) and Save are the only bar items: with a third, the glass pills
        // squeeze the title until "Edit Template" truncates to "Edit Tem…". The
        // test send moved into Preview, where it reads better anyway — you look
        // at the render, then mail it to yourself.
        ToolbarItem(placement: .confirmationAction) {
            Button("Save") {
                if errorCount > 0 {
                    // Saving over unresolved issues opens a dialog rather than a
                    // save, and it should feel like a stop rather than a commit.
                    Haptics.warning()
                    confirmingSaveWithErrors = true
                } else {
                    Haptics.success()
                    commit()
                }
            }
            .disabled(!isValid)
        }
        // Placeholder chips live on the keyboard, so they're present exactly when
        // you're typing and cost no layout when you aren't.
        ToolbarItemGroup(placement: .keyboard) {
            if focus == .subject || focus == .content {
                placeholderBar
            }
        }
    }

    // MARK: - Write

    private var writePane: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                fieldRow("Name") {
                    TextField("e.g. Cold Outreach", text: $name)
                        .focused($focus, equals: .name)
                }
                Divider().padding(.leading, 14)
                fieldRow("Subject") {
                    // Vertical axis so a long subject wraps instead of scrolling
                    // out of sight — a mail's subject carries the credentials
                    // and you need to read all of it while editing.
                    TextField("Subject", text: $subject, selection: $subjectSelection,
                              axis: .vertical)
                        .focused($focus, equals: .subject)
                        .lineLimit(1...4)
                }
            }
            .panel()
            .padding(.horizontal)
            .padding(.top, 12)

            TextEditor(text: $content, selection: $contentSelection)
                .focused($focus, equals: .content)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .overlay(alignment: .topLeading) {
                    if content.isEmpty {
                        Text("Write your mail. Tap a placeholder below the keyboard to drop in a name, company, or your resume link.")
                            .font(.callout)
                            .foregroundStyle(.inkFaint)
                            .padding(.horizontal, 17)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 6)
        }
    }

    /// Label above the field rather than beside it. A side label needs a fixed
    /// column, which both steals width from the value and breaks down at larger
    /// Dynamic Type sizes; stacked, the value always gets the full card width and
    /// nothing has to truncate.
    private func fieldRow<Content: View>(_ label: String,
                                         @ViewBuilder field: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(.inkMuted)
            field()
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// The placeholder chips, sitting on the keyboard accessory bar.
    private var placeholderBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(MailPlaceholder.allCases) { placeholder in
                        Button {
                            // A placeholder lands in text the user can't see the
                            // caret of while the keyboard is up, so the knock is
                            // the confirmation that it went in.
                            Haptics.tap()
                            insert(placeholder.token)
                        } label: {
                            Text(placeholder.shortLabel)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10)
                                .frame(height: 30)
                                .background(Color.accentColor.opacity(0.14), in: Capsule())
                                .foregroundStyle(.tint)
                        }
                        .buttonStyle(BouncyPress(scale: 0.9))
                    }
                }
            }
            .scrollIndicators(.hidden)

            Button("Done") { focus = nil }
                .font(.subheadline.weight(.semibold))
                .padding(.leading, 12)
        }
    }

    // MARK: - Preview

    private var previewPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                samplePicker

                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        MonogramAvatar(text: sample.contact.displayName,
                                       size: Theme.Avatar.small)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sample.contact.displayName)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(sample.contact.email)
                                .font(.caption)
                                .foregroundStyle(.inkMuted)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("SUBJECT")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.inkMuted)
                        Text(rendered(subject))
                            .font(.subheadline.weight(.semibold))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("MESSAGE")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.inkMuted)
                        Text(rendered(content))
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
                .panel(radius: Theme.Radius.hero)

                legend
                testSendButton
            }
            .padding()
        }
    }

    /// Moved here from the toolbar: it belongs beside the thing it sends, and it
    /// keeps the nav bar down to two items so the title has room.
    @ViewBuilder
    private var testSendButton: some View {
        VStack(spacing: 6) {
            Button {
                Haptics.press()
                confirmingTestSend = true
            } label: {
                HStack(spacing: 6) {
                    if isTestSending {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                    Text(isTestSending ? "Sending…" : "Send a test to myself")
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
            }
            .secondaryButton()
            .controlSize(.large)
            .disabled(!gmail.isConnected || !isValid || isTestSending)

            Text(gmail.isConnected
                 ? "Goes to your own inbox — the only way to see how it really lands."
                 : "Connect Gmail in Profile to send a test.")
                .font(.caption2)
                .foregroundStyle(.inkMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(.top, 4)
    }

    /// People from Home, company by company — the ones a template is written
    /// for — and a Random pick from the whole catalog, which is the quick way to
    /// meet the rows with gaps. It used to list every contact in the catalog in
    /// one flat menu, hundreds deep.
    private var samplePicker: some View {
        Menu {
            Button("Random Contact", systemImage: "shuffle") {
                Haptics.select()
                pickedSample = catalog.randomElement()
            }
            Section("On Home") {
                // A submenu per company keeps the menu one line per company,
                // however many people each has on file.
                ForEach(jobStore.jobs.filter { !$0.validContacts.isEmpty }.prefix(25)) { job in
                    Menu(job.company) {
                        ForEach(job.validContacts.sortedByName()) { contact in
                            Button(contact.displayName) {
                                Haptics.select()
                                pickedSample = (contact, job.company)
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle")
                // Two lines rather than one: contact names run long, and at
                // larger text sizes a single line clips the very name it's
                // telling you about.
                Text("Previewing as \(sample.contact.displayName)")
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .font(.subheadline.weight(.medium))
        }
        .disabled(catalog.isEmpty)
    }

    /// Side by side when there's room, stacked when there isn't — at larger text
    /// sizes the two labels can't share a line, and truncating a legend defeats
    /// the point of having one.
    private var legend: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                legendItem(color: .accentColor, text: "Filled in")
                legendItem(color: .danger, text: "Blank or not a placeholder")
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 5) {
                legendItem(color: .accentColor, text: "Filled in")
                legendItem(color: .danger, text: "Blank or not a placeholder")
            }
        }
        .font(.caption2)
        .foregroundStyle(.inkMuted)
    }

    private func legendItem(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.3)).frame(width: 14, height: 10)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Render a template string the way the contact will receive it, but with
    /// the seams left visible: substituted values are tinted, and anything that
    /// resolves to nothing becomes a labelled red marker instead of collapsing
    /// into an invisible gap. The marker is the whole point — an empty position
    /// silently turns "as a {Receiver-Position} at Acme" into "as a  at Acme",
    /// which is impossible to notice in a plain render.
    private func rendered(_ text: String) -> AttributedString {
        let context = sampleContext
        let ns = text as NSString
        var out = AttributedString()
        var cursor = 0

        for match in TemplateDiagnostics.bracedRun.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let before = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let literal = ns.substring(with: match.range)
            let placeholder = MailPlaceholder(rawValue: literal)
            let value = placeholder.flatMap { context.values[$0] } ?? ""

            // No name it can trust isn't a gap: the mail goes out as "Hi,", so
            // show exactly that.
            if placeholder == .receiverName, value.isEmpty {
                out += AttributedString(String(before.reversed().drop { $0 == " " || $0 == "\t" }.reversed()))
                cursor = match.range.location + match.range.length
                continue
            }
            out += AttributedString(before)

            if let placeholder {
                if value.trimmingCharacters(in: .whitespaces).isEmpty {
                    out += marker("⟨\(placeholder.blankLabel) missing⟩")
                } else {
                    var filled = AttributedString(value)
                    filled.backgroundColor = .accentColor.opacity(0.18)
                    out += filled
                }
            } else {
                out += marker(literal)
            }
            cursor = match.range.location + match.range.length
        }

        out += AttributedString(ns.substring(from: cursor))
        return out
    }

    private func marker(_ text: String) -> AttributedString {
        var chunk = AttributedString(text)
        chunk.backgroundColor = .danger.opacity(0.18)
        chunk.foregroundColor = .danger
        return chunk
    }

    // MARK: - Status strip

    /// Sits directly under the mode picker, and only when there's something wrong
    /// — a clean template says nothing rather than spending a row to say so. It
    /// expands downward in place instead of opening a modal over the text you'd
    /// need to edit to fix the problem.
    @ViewBuilder
    private func statusStrip(_ findings: [TemplateFinding], errorCount: Int) -> some View {
        if !findings.isEmpty {
            VStack(spacing: 0) {
                Button {
                    Haptics.tap()
                    withAnimation(Theme.Motion.bouncy) { showingIssues.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: errorCount > 0 ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(errorCount > 0 ? Color.danger : Color.kraft)
                        Text("\(findings.count) \(findings.count == 1 ? "issue" : "issues") to check")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.ink)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.inkMuted)
                            .rotationEffect(.degrees(showingIssues ? 180 : 0))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showingIssues {
                    Divider()
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(findings) { finding in
                                findingRow(finding)
                                if finding.id != findings.last?.id {
                                    Divider().padding(.leading, 44)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 210)
                    .background(Color.paperRaised)
                }

                Divider()
            }
            .background(Color.paperRaised)
            .overlay(alignment: .top) { Divider().overlay(Color.hairline) }
        }
    }

    private func findingRow(_ finding: TemplateFinding) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: finding.severity == .error
                  ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(finding.severity == .error ? Color.danger : Color.kraft)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(finding.title)
                    .font(.subheadline.weight(.semibold))
                Text(finding.detail)
                    .font(.caption)
                    .foregroundStyle(.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            if let token = finding.token, let suggestion = finding.suggestion {
                Button("Fix") { replace(token, with: suggestion) }
                    .font(.caption.weight(.semibold))
                    .primaryButton()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Editing

    /// Insert a token at the caret of whichever field is focused. Both fields go
    /// through the same path, so the subject no longer appends blindly to the end
    /// while the body inserts properly.
    private func insert(_ token: String) {
        switch focus {
        case .subject:
            subject = inserting(token, into: subject, at: subjectSelection)
            subjectSelection = caret(after: token, in: subject, from: subjectSelection)
        case .content:
            content = inserting(token, into: content, at: contentSelection)
            contentSelection = caret(after: token, in: content, from: contentSelection)
        default:
            break
        }
    }

    private func inserting(_ token: String, into text: String, at selection: TextSelection?) -> String {
        guard let selection, case .selection(let range) = selection.indices else {
            return text + token
        }
        var copy = text
        copy.replaceSubrange(range, with: token)
        return copy
    }

    /// Where the caret should land after an insert: just past the token that was
    /// dropped in, so you can keep typing.
    private func caret(after token: String, in text: String, from selection: TextSelection?) -> TextSelection? {
        guard let selection, case .selection(let range) = selection.indices else { return nil }
        // `range` indexes the pre-edit string; its offset is still valid because
        // everything before the insertion point is unchanged.
        let offset = min(text.distance(from: text.startIndex, to: range.lowerBound) + token.count,
                         text.count)
        guard let position = text.index(text.startIndex, offsetBy: offset, limitedBy: text.endIndex) else {
            return nil
        }
        return TextSelection(range: position..<position)
    }

    private func replace(_ token: String, with suggestion: String) {
        subject = subject.replacingOccurrences(of: token, with: suggestion)
        content = content.replacingOccurrences(of: token, with: suggestion)
    }

    private func commit() {
        onSave(MailTemplate(
            id: existing?.id ?? UUID(),
            name: name.sanitizedLineSeparators,
            subject: subject.sanitizedLineSeparators,
            content: content.sanitizedLineSeparators
        ))
        dismiss()
    }

    /// Send the previewed render to the signed-in account. Nothing else in the
    /// app shows what actually lands — line breaks, subject truncation, whether
    /// the resume link is clickable — until it's already gone to a contact.
    private func sendTest() async {
        guard let address = gmail.connectedEmail else { return }
        isTestSending = true
        defer { isTestSending = false }

        let context = sampleContext
        do {
            try await gmail.send(
                to: address,
                subject: "[Test] " + context.fill(subject),
                body: context.fill(content),
                fromName: profileStore.profile.name
            )
            testSendResult = "Sent to \(address). Open it on your phone to see exactly what a contact gets."
        } catch {
            testSendResult = error.localizedDescription
        }
    }
}

#Preview {
    TemplateEditorView(existing: nil) { _ in }
        .environment(JobStore())
        .environment(ProfileStore())
        .environment(GmailAuthStore())
}
