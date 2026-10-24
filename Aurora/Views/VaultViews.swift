import SwiftUI

/// What stands between signing in and the app until this account's keys are
/// open: setting them up the first time, unlocking on a new phone, the
/// recovery phrase, and the one-time encryption of what was stored before.
struct VaultGateView: View {
    @Environment(VaultStore.self) private var vaults

    var body: some View {
        Group {
            switch vaults.phase {
            case .signedOut, .checking, .ready:
                SplashView(progress: 0)
            case .setUp(let existing):
                VaultSetupView(existing: existing)
            case .unlock(let vault):
                VaultUnlockView(vault: vault)
            case .recoveryPhrase(let phrase):
                RecoveryPhraseView(phrase: phrase, continueTitle: "Continue") {
                    Task { await vaults.continueAfterRecoveryPhrase() }
                }
            case .working(let label):
                VaultWorkingView(label: label, progress: vaults.progress, detail: vaults.progressDetail)
            case .failed(let message):
                VaultFailedView(message: message)
            }
        }
        .transition(.opacity)
        .animation(Theme.Motion.snappy, value: vaults.phase)
    }
}

// MARK: - Setup

/// The first sign-in: choose this account's code and private key, and
/// optionally bring in contacts someone has shared.
private struct VaultSetupView: View {
    /// A vault made ahead of time (AURORA): its code is already chosen.
    let existing: VaultRow?

    @Environment(VaultStore.self) private var vaults
    @Environment(GmailAuthStore.self) private var gmail

    @State private var code: String
    @State private var privateKey = ""
    @State private var confirmation = ""
    @State private var pending: [VaultStore.PendingImport] = []
    @State private var isAddingImport = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(existing: VaultRow?) {
        self.existing = existing
        _code = State(initialValue: existing?.code ?? Self.suggestedCode())
    }

    var body: some View {
        NavigationStack {
            PaperForm {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        IconTile(systemImage: "lock.shield", tint: .clay)
                        Text(existing == nil
                             ? "Your contacts are encrypted on this phone before they're stored. Only you, and people you give your private key to, can read them."
                             : "The contacts already on file are yours. Choose a private key to encrypt them — only you, and people you give it to, will be able to read them.")
                            .font(.subheadline)
                            .foregroundStyle(.inkMuted)
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    if existing == nil {
                        TextField("Code", text: $code)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                    } else {
                        LabeledContent("Code") {
                            Text(code).font(.body.monospaced()).foregroundStyle(.ink)
                        }
                    }
                } header: {
                    Text("Your Code")
                } footer: {
                    Text(codeProblem ?? "Public. Others type it, with your private key, to import your contacts. You can change it in Settings.")
                }

                Section {
                    SecureField("Private key", text: $privateKey)
                        .textContentType(.newPassword)
                    SecureField("Private key again", text: $confirmation)
                        .textContentType(.newPassword)
                } header: {
                    Text("Private Key")
                } footer: {
                    Text(keyProblem ?? "Opens your contacts. Give it only to people you share them with. Aurora can't recover it for you.")
                }

                Section {
                    ForEach(pending) { item in
                        ImportRow(code: item.vault.code, count: item.contactCount, isCurrent: true)
                            .swipeActions {
                                Button("Remove", role: .destructive) {
                                    pending.removeAll { $0.id == item.id }
                                }
                            }
                    }
                    Button {
                        Haptics.tap()
                        isAddingImport = true
                    } label: {
                        Label("Import Someone's Contacts", systemImage: "person.2.badge.key")
                    }
                } header: {
                    Text("Import (Optional)")
                } footer: {
                    Text("Have a code and private key from someone? Their contacts appear beside yours. You can mail them and mark them invalid, but only they can edit or share them.")
                }

                Section {
                    Button { save() } label: {
                        HStack {
                            Spacer()
                            if isSaving {
                                ProgressView().tint(.white)
                            } else {
                                Text("Continue").fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(!canSave)
                } footer: {
                    Button("Sign Out") { gmail.disconnect() }
                        .font(.footnote)
                        .foregroundStyle(.inkMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                }
            }
            .navigationTitle("Private Contacts")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $isAddingImport) {
                ImportCodeSheet { item in
                    guard !pending.contains(where: { $0.id == item.id }) else { return }
                    pending.append(item)
                }
            }
            .messageAlert("Couldn't set up", message: errorMessage) { errorMessage = nil }
        }
    }

    /// Only said once something's been typed, so the form doesn't open on errors.
    private var codeProblem: String? {
        guard existing == nil, !code.isEmpty else { return nil }
        return VaultCode.problem(with: code)
    }

    private var keyProblem: String? {
        guard !privateKey.isEmpty, !confirmation.isEmpty else { return nil }
        return PrivateKeyRule.problem(with: privateKey, confirmation: confirmation)
    }

    private var canSave: Bool {
        !isSaving && VaultCode.problem(with: code) == nil
            && PrivateKeyRule.problem(with: privateKey, confirmation: confirmation) == nil
    }

    private func save() {
        Haptics.press()
        isSaving = true
        Task {
            do {
                try await vaults.setUp(code: code, privateKey: privateKey, imports: pending)
                Haptics.success()
            } catch {
                Haptics.failure()
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }

    /// Six letters and digits nobody's likely to have taken, as a start.
    private static func suggestedCode() -> String {
        let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
        return String((0..<6).map { _ in alphabet.randomElement()! })
    }
}

// MARK: - Unlock

/// Set up on another phone, but no account key here (iCloud Keychain hasn't
/// brought it, or isn't on): the recovery phrase brings everything back, the
/// private key just the contacts.
private struct VaultUnlockView: View {
    let vault: VaultRow

    private enum Method: Hashable { case phrase, privateKey }

    @Environment(VaultStore.self) private var vaults
    @Environment(GmailAuthStore.self) private var gmail

    @State private var method = Method.phrase
    @State private var phrase = ""
    @State private var privateKey = ""
    @State private var isUnlocking = false
    @State private var confirmingKeyOnly = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            PaperForm {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        IconTile(systemImage: "key.horizontal", tint: .clay)
                        Text("Your contacts and mail history are encrypted. Unlock them on this phone with your recovery phrase.")
                            .font(.subheadline)
                            .foregroundStyle(.inkMuted)
                    }
                    .padding(.vertical, 4)
                    LabeledContent("Your code") {
                        Text(vault.code).font(.body.monospaced()).foregroundStyle(.ink)
                    }
                }

                Section {
                    SegmentedSelector(segments: [(Method.phrase, "Recovery Phrase"), (Method.privateKey, "Private Key")],
                                      selection: $method)
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }

                if method == .phrase {
                    Section {
                        TextField("Recovery phrase", text: $phrase, axis: .vertical)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                    } header: {
                        Text("Recovery Phrase")
                    } footer: {
                        Text("The 24 characters shown when you set up. Dashes and spaces don't matter.")
                    }
                } else {
                    Section {
                        SecureField("Private key", text: $privateKey)
                            .textContentType(.password)
                    } header: {
                        Text("Private Key")
                    } footer: {
                        Text("Lost your recovery phrase? Your private key opens your contacts, but your sent mails' text, your templates and your imports can't be read again. Which contacts you've mailed is kept.")
                    }
                }

                Section {
                    Button { unlockTapped() } label: {
                        HStack {
                            Spacer()
                            if isUnlocking {
                                ProgressView().tint(.white)
                            } else {
                                Text("Unlock").fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(isUnlocking || (method == .phrase ? RecoveryPhrase.normalized(phrase) == nil : privateKey.isEmpty))
                } footer: {
                    Button("Sign Out") { gmail.disconnect() }
                        .font(.footnote)
                        .foregroundStyle(.inkMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                }
            }
            .navigationTitle("Unlock")
            .navigationBarTitleDisplayMode(.inline)
            .confirmAlert("Unlock with your private key?",
                          message: "If a phone of yours still has your keys, this one picks them up and nothing is lost. Otherwise your sent mails' text, templates and imports from before can't be read again, and you'll get a new recovery phrase.",
                          confirmLabel: "Unlock", role: .destructive,
                          isPresented: $confirmingKeyOnly) { unlock() }
            .messageAlert("Couldn't unlock", message: errorMessage) { errorMessage = nil }
        }
    }

    private func unlockTapped() {
        if method == .privateKey { confirmingKeyOnly = true } else { unlock() }
    }

    private func unlock() {
        Haptics.press()
        isUnlocking = true
        Task {
            do {
                if method == .phrase {
                    try await vaults.unlock(recoveryPhrase: phrase)
                } else {
                    try await vaults.unlock(privateKey: privateKey)
                }
                Haptics.success()
            } catch {
                Haptics.failure()
                errorMessage = error.localizedDescription
            }
            isUnlocking = false
        }
    }
}

// MARK: - Recovery phrase

/// The account key's backup, shown once. Continue waits until it's been
/// acknowledged as saved.
struct RecoveryPhraseView: View {
    let phrase: String
    let continueTitle: String
    let onContinue: () -> Void

    @State private var hasSaved = false
    @State private var copied = false

    private static func lines(_ phrase: String) -> String {
        let groups = phrase.split(separator: "-")
        let half = (groups.count + 1) / 2
        return [groups.prefix(half), groups.dropFirst(half)].map { $0.joined(separator: "-") }.joined(separator: "\n")
    }

    var body: some View {
        NavigationStack {
            PaperForm {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        IconTile(systemImage: "text.badge.checkmark", tint: .kraft)
                        Text("If this phone is lost and iCloud Keychain doesn't bring your keys back, this phrase is the only way to read your mail history, templates and imports again. Write it down or keep it in a password manager.")
                            .font(.subheadline)
                            .foregroundStyle(.inkMuted)
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    // Three groups to a line, so a large text size never
                    // breaks one across lines.
                    Text(Self.lines(phrase))
                        .font(.title3.monospaced().weight(.semibold))
                        .foregroundStyle(.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 10)
                    Button {
                        Haptics.tap()
                        // Kept off other devices, and gone after a few minutes.
                        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: phrase]],
                                                      options: [.localOnly: true,
                                                                .expirationDate: Date().addingTimeInterval(180)])
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                } header: {
                    Text("Recovery Phrase")
                } footer: {
                    Text("Aurora never shows it again. A copy leaves the clipboard after three minutes.")
                }

                Section {
                    Toggle("I've saved my recovery phrase", isOn: $hasSaved)
                    Button {
                        Haptics.press()
                        onContinue()
                    } label: {
                        HStack {
                            Spacer()
                            Text(continueTitle).fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(!hasSaved)
                }
            }
            .navigationTitle("Recovery Phrase")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
        }
    }
}

// MARK: - Working

/// A long one-time job before the app opens: encrypting what was stored
/// before, or re-encrypting after a key change.
private struct VaultWorkingView: View {
    let label: String
    let progress: Double?
    let detail: String?

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            IconTile(systemImage: "lock.rotation", tint: .clay, size: 64)
            Text(label)
                .displayFont(20)
                .foregroundStyle(.ink)
                .multilineTextAlignment(.center)
            if let progress {
                ProgressView(value: progress)
                    .tint(.clay)
                    .frame(maxWidth: 280)
            } else {
                ProgressView()
            }
            if let detail {
                Text(detail)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.inkMuted)
            }
            Spacer()
            Text("Keep Aurora open. If it's closed, it carries on from here next time.")
                .font(.footnote)
                .foregroundStyle(.inkFaint)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .paperScreen()
    }
}

// MARK: - Failed

private struct VaultFailedView: View {
    let message: String

    @Environment(VaultStore.self) private var vaults
    @Environment(GmailAuthStore.self) private var gmail

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            InlineEmptyState(title: "Couldn't open your contacts", systemImage: "exclamationmark.lock",
                             message: message, tint: .statusInvalid, actionTitle: "Try Again") {
                Task { await vaults.retry() }
            }
            Spacer()
            Button("Sign Out") { gmail.disconnect() }
                .font(.footnote)
                .foregroundStyle(.inkMuted)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .paperScreen()
    }
}

// MARK: - Import

/// Enter someone's code and private key. The key is checked against the code
/// before anything is added; `onVerified` takes it from there.
struct ImportCodeSheet: View {
    var initialCode = ""
    let onVerified: (VaultStore.PendingImport) async throws -> Void

    @Environment(VaultStore.self) private var vaults
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var privateKey = ""
    @State private var isChecking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            PaperForm {
                Section {
                    TextField("Code", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                } header: {
                    Text("Their Code")
                }
                Section {
                    SecureField("Private key", text: $privateKey)
                        .textContentType(.password)
                } header: {
                    Text("Their Private Key")
                } footer: {
                    Text("Ask the person sharing for both. The key is checked on this phone and never stored as typed.")
                }
            }
            .navigationTitle("Import Contacts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isChecking {
                        ProgressView()
                    } else {
                        Button("Import") { check() }
                            .fontWeight(.semibold)
                            .disabled(VaultCode.problem(with: code) != nil || privateKey.isEmpty)
                    }
                }
            }
            .onAppear { if code.isEmpty { code = initialCode } }
            .interactiveDismissDisabled(isChecking)
            .messageAlert("Couldn't import", message: errorMessage) { errorMessage = nil }
        }
    }

    private func check() {
        Haptics.press()
        isChecking = true
        Task {
            do {
                let item = try await vaults.verifyImport(code: code, privateKey: privateKey)
                try await onVerified(item)
                Haptics.success()
                dismiss()
            } catch {
                Haptics.failure()
                errorMessage = error.localizedDescription
            }
            isChecking = false
        }
    }
}

/// An imported code in a list: its contacts, or that its key has changed.
struct ImportRow: View {
    let code: String
    let count: Int?
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            IconTile(systemImage: isCurrent ? "person.2.fill" : "lock.slash", tint: isCurrent ? .olive : .statusInvalid,
                     size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(code)
                    .font(.body.monospaced().weight(.semibold))
                    .foregroundStyle(.ink)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(isCurrent ? Color.inkMuted : Color.statusInvalid)
            }
        }
    }

    private var subtitle: String {
        guard isCurrent else { return "Their private key changed — enter the new one" }
        guard let count else { return "Contacts" }
        return count == 1 ? "1 contact" : "\(count.formatted()) contacts"
    }
}

// MARK: - Settings

/// Settings › Sharing: this account's code, its private key and recovery
/// phrase, and the codes it imports.
struct SharingSettingsView: View {
    @Environment(VaultStore.self) private var vaults

    @State private var isChangingCode = false
    @State private var isChangingKey = false
    @State private var isAddingImport = false
    @State private var reimporting: VaultStore.Import?
    @State private var removing: VaultStore.Import?
    @State private var confirmingNewPhrase = false
    @State private var newPhrase: String?
    @State private var codeCopied = false
    @State private var errorMessage: String?

    var body: some View {
        PaperForm {
            ownSection
            keySection
            importsSection
        }
        .navigationTitle("Sharing & Keys")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vaults.refreshImports() }
        .sheet(isPresented: $isChangingCode) { ChangeCodeSheet(current: vaults.ownVault?.code ?? "") }
        .sheet(isPresented: $isChangingKey) { ChangePrivateKeySheet() }
        .sheet(isPresented: $isAddingImport) {
            ImportCodeSheet { try await vaults.addImport($0) }
        }
        .sheet(item: $reimporting) { item in
            ImportCodeSheet(initialCode: item.code) { try await vaults.addImport($0) }
        }
        .sheet(item: Binding(get: { newPhrase.map(ShownPhrase.init) }, set: { if $0 == nil { newPhrase = nil } })) { shown in
            RecoveryPhraseView(phrase: shown.phrase, continueTitle: "Done") { newPhrase = nil }
        }
        .confirmAlert("Stop importing \(removing?.code ?? "")?",
                      message: "Its contacts leave your lists. Your sent mails to them stay in your history. You'll need the code and private key to import it again.",
                      confirmLabel: "Remove", role: .destructive,
                      isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            guard let item = removing else { return }
            Task {
                do {
                    try await vaults.removeImport(item)
                    Haptics.success()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        .confirmAlert("Make a new recovery phrase?",
                      message: "Your current recovery phrase stops working.",
                      confirmLabel: "Make New Phrase", isPresented: $confirmingNewPhrase) {
            Task {
                do {
                    newPhrase = try await vaults.makeNewRecoveryPhrase()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        .messageAlert("Something went wrong", message: errorMessage) { errorMessage = nil }
    }

    private struct ShownPhrase: Identifiable {
        let phrase: String
        var id: String { phrase }
    }

    private var ownSection: some View {
        Section {
            if let code = vaults.ownVault?.code {
                HStack {
                    Text(code)
                        .font(.title2.monospaced().weight(.semibold))
                        .foregroundStyle(.ink)
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        Haptics.tap()
                        UIPasteboard.general.string = code
                        codeCopied = true
                    } label: {
                        Image(systemName: codeCopied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Copy code")
                    ShareLink(item: "Import my contacts in Aurora with the code \(code). I'll send you the private key separately.") {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                }
                if let count = vaults.ownContactCount {
                    LabeledContent("Your contacts", value: count.formatted())
                }
            }
            Button {
                Haptics.tap()
                isChangingCode = true
            } label: {
                Label("Change Code", systemImage: "character.cursor.ibeam")
            }
        } header: {
            Text("Your Code")
        } footer: {
            Text("Share your code and your private key to let someone import your contacts. They can mail them, but only you can edit or share them. Contacts you imported aren't shared on.")
        }
    }

    @ViewBuilder
    private var keySection: some View {
        Section {
            if let label = vaults.workLabel {
                VStack(alignment: .leading, spacing: 6) {
                    Text(label).foregroundStyle(.ink)
                    ProgressView(value: vaults.progress ?? 0).tint(.clay)
                    if let detail = vaults.progressDetail {
                        Text(detail).font(.caption.monospacedDigit()).foregroundStyle(.inkMuted)
                    }
                }
                .padding(.vertical, 4)
            }
            Button {
                Haptics.tap()
                isChangingKey = true
            } label: {
                Label("Change Private Key", systemImage: "key.horizontal")
            }
            .disabled(vaults.workLabel != nil)
            Button {
                Haptics.tap()
                confirmingNewPhrase = true
            } label: {
                Label("Make a New Recovery Phrase", systemImage: "text.badge.checkmark")
            }
        } header: {
            Text("Keys")
        } footer: {
            Text("Changing your private key cuts off everyone who imported your code until you give them the new one. Forgot it? Change it with your recovery phrase instead.")
        }
    }

    private var importsSection: some View {
        Section {
            ForEach(vaults.imports) { item in
                Button {
                    if !item.isCurrent {
                        Haptics.tap()
                        reimporting = item
                    }
                } label: {
                    ImportRow(code: item.code, count: item.contactCount, isCurrent: item.isCurrent)
                }
                .swipeActions {
                    Button("Remove", role: .destructive) { removing = item }
                }
                .contextMenu {
                    if !item.isCurrent {
                        Button { reimporting = item } label: { Label("Enter New Key", systemImage: "key.horizontal") }
                    }
                    Button(role: .destructive) { removing = item } label: { Label("Remove", systemImage: "trash") }
                }
            }
            Button {
                Haptics.tap()
                isAddingImport = true
            } label: {
                Label("Import Contacts", systemImage: "person.2.badge.key")
            }
        } header: {
            Text("Imported")
        } footer: {
            Text(vaults.imports.isEmpty
                 ? "Import someone's contacts with their code and private key."
                 : "Imported contacts can be mailed and marked invalid. Only their owner can edit, delete or share them.")
        }
    }
}

/// A new public code for this account's vault.
private struct ChangeCodeSheet: View {
    let current: String

    @Environment(VaultStore.self) private var vaults
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            PaperForm {
                Section {
                    TextField("Code", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                } header: {
                    Text("New Code")
                } footer: {
                    Text(code.isEmpty ? "People who already imported your contacts keep them. New imports use the new code."
                                      : (VaultCode.problem(with: code) ?? "People who already imported your contacts keep them. New imports use the new code."))
                }
            }
            .navigationTitle("Change Code")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { if code.isEmpty { code = current } }
            .discardableEdits(VaultCode.normalized(code) != current)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { save() }
                            .fontWeight(.semibold)
                            .disabled(VaultCode.problem(with: code) != nil || VaultCode.normalized(code) == current)
                    }
                }
            }
            .messageAlert("Couldn't change code", message: errorMessage) { errorMessage = nil }
        }
    }

    private func save() {
        isSaving = true
        Task {
            do {
                try await vaults.changeCode(to: code)
                Haptics.success()
                dismiss()
            } catch {
                Haptics.failure()
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}

/// A new private key: every contact is encrypted again under it. Proven by the
/// current key, or by the recovery phrase when the key is forgotten.
private struct ChangePrivateKeySheet: View {
    @Environment(VaultStore.self) private var vaults
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var phrase = ""
    @State private var usesPhrase = false
    @State private var new = ""
    @State private var confirmation = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            PaperForm {
                if usesPhrase {
                    Section {
                        TextField("Recovery phrase", text: $phrase, axis: .vertical)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                    } header: {
                        Text("Recovery Phrase")
                    } footer: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("The 24 characters shown when you set up, or the last new phrase you made. Dashes and spaces don't matter.")
                            Button("Use My Current Key Instead") { switchProof() }
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Color.clay)
                        }
                    }
                } else {
                    Section {
                        SecureField("Current key", text: $current)
                            .textContentType(.password)
                    } header: {
                        Text("Current Private Key")
                    } footer: {
                        Button("Forgot your private key? Use your recovery phrase.") { switchProof() }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.clay)
                    }
                }
                Section {
                    SecureField("New key", text: $new)
                        .textContentType(.newPassword)
                    SecureField("New key again", text: $confirmation)
                        .textContentType(.newPassword)
                } header: {
                    Text("New Private Key")
                } footer: {
                    Text(problem ?? "Everyone who imported your code loses your contacts until you give them the new key.")
                }
                if isSaving {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(vaults.workLabel ?? "Checking…").foregroundStyle(.ink)
                            ProgressView(value: vaults.progress ?? 0).tint(.clay)
                            if let detail = vaults.progressDetail {
                                Text(detail).font(.caption.monospacedDigit()).foregroundStyle(.inkMuted)
                            }
                        }
                        .padding(.vertical, 4)
                    } footer: {
                        Text("If Aurora is closed, it carries on next time it opens.")
                    }
                }
            }
            .navigationTitle(usesPhrase ? "Reset Private Key" : "Change Private Key")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Change") { save() }
                            .fontWeight(.semibold)
                            .disabled(!hasProof || PrivateKeyRule.problem(with: new, confirmation: confirmation) != nil)
                    }
                }
            }
            .messageAlert("Couldn't change key", message: errorMessage) { errorMessage = nil }
        }
    }

    private var hasProof: Bool {
        usesPhrase ? RecoveryPhrase.normalized(phrase) != nil : !current.isEmpty
    }

    private func switchProof() {
        Haptics.tap()
        withAnimation(Theme.Motion.snappy) { usesPhrase.toggle() }
    }

    private var problem: String? {
        guard !new.isEmpty, !confirmation.isEmpty else { return nil }
        return PrivateKeyRule.problem(with: new, confirmation: confirmation)
    }

    private func save() {
        Haptics.press()
        isSaving = true
        Task {
            do {
                try await vaults.changePrivateKey(proof: usesPhrase ? .recoveryPhrase(phrase) : .currentKey(current),
                                                  new: new)
                Haptics.success()
                dismiss()
            } catch {
                Haptics.failure()
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}
