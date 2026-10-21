import Foundation
import CryptoKit
import Observation

/// Everything about this account's keys: setting them up at the first sign-in,
/// unlocking on each launch, the contacts imported from other people's codes,
/// and changing the code or the private key.
///
/// Three secrets are involved, and they're kept apart on purpose:
/// - **The public code** ("AURORA") names a vault. Not a secret on its own.
/// - **The private key** opens the vault. It's what the owner gives anyone they
///   want to share their contacts with, so it opens *only* the contacts.
/// - **The account key** is random and never typed. It holds the account's way
///   into each vault (its own and every import) and seals its mail history,
///   templates and profile. It lives in iCloud Keychain, with a recovery phrase
///   as its backup — so someone given the private key can't reach anything
///   but the contacts it shares.
///
/// Whatever was stored before (the plain rows of the first sign-in after the
/// migration) is sealed in place on unlock, a page at a time; a run cut short
/// picks up where it left off at the next launch. A private-key change is
/// resumable the same way.
@Observable
final class VaultStore {
    enum Phase: Equatable {
        case signedOut
        case checking
        /// No keys yet. `existing` is a vault made ahead of time (AURORA) whose
        /// owner hasn't chosen its private key.
        case setUp(existing: VaultRow?)
        /// Set up, but this phone has no account key.
        case unlock(VaultRow)
        /// Shown once, after it's made. Continue finishes unlocking.
        case recoveryPhrase(String)
        case working(String)
        case ready
        case failed(String)
    }

    /// Someone else's vault this account reads.
    struct Import: Identifiable, Equatable {
        let id: String
        var code: String
        /// False once its owner has changed the private key: the contacts are
        /// shut until the new one is entered.
        var isCurrent: Bool
        var contactCount: Int?
    }

    /// A vault whose private key has been checked, not yet added to the account.
    struct PendingImport: Identifiable, Equatable {
        static func == (a: PendingImport, b: PendingImport) -> Bool { a.id == b.id }
        var id: String { vault.id }
        let vault: VaultRow
        let key: SymmetricKey
        var contactCount: Int?
    }

    private(set) var phase: Phase = .signedOut
    /// How far a long job is, 0...1, with what it's on ("4,000 of 17,817").
    private(set) var progress: Double?
    private(set) var progressDetail: String?
    /// What a long job is doing ("Re-encrypting your contacts…"), for a
    /// screen that shows it in place: Settings, during a key change.
    private(set) var workLabel: String?
    private(set) var email: String?
    private(set) var ownVault: VaultRow?
    private(set) var ownContactCount: Int?
    private(set) var imports: [Import] = []

    /// Told when the vaults this account reads change (an import added or
    /// removed, a key changed), so the app's lists reload.
    @ObservationIgnored var onAccessChanged: (() async -> Void)?

    var isReady: Bool { phase == .ready }

    // MARK: - Launch

    /// Find this account's vault and unlock it if this phone can.
    func start(email: String) async {
        self.email = email
        KeyRing.shared.clear()
        phase = .checking
        do {
            guard let vault = try await VaultAPI.vault(ownerEmail: email) else {
                ownVault = nil
                phase = .setUp(existing: nil)
                return
            }
            ownVault = vault
            guard vault.hasKey else {
                phase = .setUp(existing: vault)
                return
            }
            guard let accountKey = AccountKeychain.load(email: email) else {
                phase = .unlock(vault)
                return
            }
            try await open(with: accountKey, vault: vault)
        } catch {
            fail(error)
        }
    }

    func retry() async {
        guard let email else { return }
        await start(email: email)
    }

    func signOut() {
        KeyRing.shared.clear()
        email = nil
        ownVault = nil
        imports = []
        ownContactCount = nil
        phase = .signedOut
    }

    /// Unlock with the account key: open every grant, finish anything left half
    /// done, then hand over to the app. Without a way into its own vault (the
    /// key in this keychain is an old one) it asks to be unlocked instead.
    private func open(with accountKey: SymmetricKey, vault: VaultRow) async throws {
        guard let email, let keyID = vault.keyID else { throw VaultError.notSetUp }
        KeyRing.shared.set(accountKey: accountKey)
        let grants = try await VaultAPI.grants(email: email)
        holdKeys(from: grants, accountKey: accountKey)
        guard KeyRing.shared.vaultKey(keyID) != nil else {
            KeyRing.shared.clear()
            phase = .unlock(vault)
            return
        }
        KeyRing.shared.setOwnVault(id: vault.id, keyID: keyID)
        try await finishOpening(vault: vault, grants: grants)
    }

    /// Open this account's keys for a check the phone runs with the app
    /// closed (`BackgroundCheck`): what `start` does when the keychain holds
    /// the account key, without its screens or upkeep. Keys already open are
    /// left as they are. Says whether the account's own vault is readable.
    static func openKeysQuietly(email: String) async -> Bool {
        if KeyRing.shared.accountKey != nil, KeyRing.shared.ownVaultID != nil { return true }
        guard let accountKey = AccountKeychain.load(email: email),
              let vault = try? await VaultAPI.vault(ownerEmail: email), let keyID = vault.keyID,
              let grants = try? await VaultAPI.grants(email: email) else { return false }
        KeyRing.shared.set(accountKey: accountKey)
        holdKeys(from: grants, email: email, accountKey: accountKey)
        guard KeyRing.shared.vaultKey(keyID) != nil else {
            KeyRing.shared.clear()
            return false
        }
        KeyRing.shared.setOwnVault(id: vault.id, keyID: keyID)
        return true
    }

    /// Put every vault key the grants hold on the key ring.
    private func holdKeys(from grants: [VaultGrant], accountKey: SymmetricKey) {
        guard let email else { return }
        Self.holdKeys(from: grants, email: email, accountKey: accountKey)
    }

    private static func holdKeys(from grants: [VaultGrant], email: String, accountKey: SymmetricKey) {
        for grant in grants {
            let context = Sealing.grantContext(email: email, vaultID: grant.vaultID, keyID: grant.keyID)
            if let key = try? Sealing.unwrap(grant.sealedKey, with: accountKey, context: context) {
                KeyRing.shared.add(vaultKey: key, keyID: grant.keyID, vaultID: grant.vaultID)
            }
        }
    }

    private func finishOpening(vault: VaultRow, grants: [VaultGrant]) async throws {
        if vault.pendingKeyID != nil { try await finishKeyChange(vault) }
        try await sealPlainRows()
        await refreshImports()
        progress = nil
        progressDetail = nil
        phase = .ready
    }

    private func fail(_ error: Error) {
        guard !error.isCancellation else { return }
        progress = nil
        progressDetail = nil
        workLabel = nil
        phase = .failed(error.localizedDescription)
    }

    // MARK: - First sign-in

    /// Check an import before it's added: the code exists, isn't this
    /// account's own, and `privateKey` opens it.
    func verifyImport(code: String, privateKey: String) async throws -> PendingImport {
        guard let vault = try await VaultAPI.vault(code: code) else { throw VaultError.noSuchCode }
        if vault.ownerEmail.lowercased() == email?.lowercased() { throw VaultError.ownCode }
        guard vault.hasKey, let keyID = vault.keyID, let sealedKey = vault.sealedKey,
              let salt = vault.kdfSalt else { throw VaultError.noSuchCode }
        let unlocking = await Self.derive(privateKey, salt: salt, rounds: vault.kdfRounds)
        guard let unlocking,
              let key = try? Sealing.unwrap(sealedKey, with: unlocking,
                                            context: Sealing.vaultKeyContext(vaultID: vault.id, keyID: keyID))
        else { throw VaultError.wrongPrivateKey }
        let count = try? await VaultAPI.contactCount(vaultID: vault.id)
        return PendingImport(vault: vault, key: key, contactCount: count)
    }

    /// Make this account's keys: its vault under `code` and `privateKey`, a new
    /// account key with its recovery phrase, and a way into each import. Ends
    /// on the recovery phrase; `continueAfterRecoveryPhrase` finishes.
    func setUp(code: String, privateKey: String, imports pending: [PendingImport]) async throws {
        guard let email else { throw VaultError.notSetUp }
        let code = VaultCode.normalized(code)
        let existing = ownVault
        let vaultID = existing?.id ?? UUID().uuidString.lowercased()
        let keyID = UUID().uuidString.lowercased()
        let vaultKey = Sealing.newKey()
        let accountKey = Sealing.newKey()
        let phrase = RecoveryPhrase.make()

        let (keyBody, recoveryBody) = await Self.sealing(vaultKey, under: privateKey, vaultID: vaultID, keyID: keyID,
                                                         accountKey: accountKey, phrase: phrase, email: email)
        var body = keyBody.merging(recoveryBody) { a, _ in a }
        body["code"] = code

        // The account key is kept before the vault is written: a launch cut
        // off after the write still finds it, rather than a vault no phone
        // can open but by its private key.
        AccountKeychain.save(accountKey, email: email)
        if let existing {
            // Only on a vault with no key yet, so a second phone setting one at
            // the same moment can't replace the first.
            try await VaultAPI.updateVault(id: existing.id, body,
                                           onlyIf: [URLQueryItem(name: "sealed_key", value: "is.null")])
        } else {
            body["id"] = vaultID
            body["owner_email"] = email.lowercased()
            try await VaultAPI.createVault(body)
        }
        guard let vault = try await VaultAPI.vault(ownerEmail: email), vault.keyID == keyID else {
            // Another phone got there first: unlock with what it made.
            await start(email: email)
            return
        }
        ownVault = vault

        try await grant(vaultKey, vaultID: vaultID, keyID: keyID, accountKey: accountKey)
        for item in pending {
            guard let importKeyID = item.vault.keyID else { continue }
            try await grant(item.key, vaultID: item.vault.id, keyID: importKeyID, accountKey: accountKey)
            KeyRing.shared.add(vaultKey: item.key, keyID: importKeyID, vaultID: item.vault.id)
        }
        KeyRing.shared.set(accountKey: accountKey)
        KeyRing.shared.add(vaultKey: vaultKey, keyID: keyID, vaultID: vaultID)
        KeyRing.shared.setOwnVault(id: vaultID, keyID: keyID)
        phase = .recoveryPhrase(phrase)
    }

    /// The recovery phrase has been seen: seal what's still plain and open the app.
    func continueAfterRecoveryPhrase() async {
        guard let vault = ownVault, let email else { return }
        do {
            try await finishOpening(vault: vault, grants: try await VaultAPI.grants(email: email))
        } catch {
            fail(error)
        }
    }

    // MARK: - Unlocking on a new phone

    /// Unlock with the recovery phrase: everything comes back.
    func unlock(recoveryPhrase typed: String) async throws {
        guard let email, let vault = ownVault else { throw VaultError.notSetUp }
        guard let phrase = RecoveryPhrase.normalized(typed), let salt = vault.recoverySalt,
              let sealed = vault.sealedAccountKey,
              let unlocking = await Self.derive(phrase, salt: salt, rounds: vault.recoveryRounds),
              let accountKey = try? Sealing.unwrap(sealed, with: unlocking, context: Sealing.accountContext(email: email))
        else { throw VaultError.wrongRecoveryPhrase }
        AccountKeychain.save(accountKey, email: email)
        phase = .working("Unlocking…")
        do {
            try await open(with: accountKey, vault: vault)
        } catch {
            fail(error)
        }
    }

    /// Unlock with the private key alone, when the recovery phrase is lost. The
    /// contacts open; a new account key is made, so mail text, templates, the
    /// profile and imports sealed under the old one can't be read again (when
    /// each was sent still counts). An account key already on this phone that
    /// still fits is kept instead, and nothing is lost.
    func unlock(privateKey: String) async throws {
        guard let email, let vault = ownVault, let keyID = vault.keyID, let sealedKey = vault.sealedKey,
              let salt = vault.kdfSalt else { throw VaultError.notSetUp }
        guard let unlocking = await Self.derive(privateKey, salt: salt, rounds: vault.kdfRounds),
              let vaultKey = try? Sealing.unwrap(sealedKey, with: unlocking,
                                                 context: Sealing.vaultKeyContext(vaultID: vault.id, keyID: keyID))
        else { throw VaultError.wrongPrivateKey }
        phase = .working("Unlocking…")
        do {
            let grants = try await VaultAPI.grants(email: email)
            if let held = AccountKeychain.load(email: email), grants.isEmpty || grants.contains(where: { grant in
                (try? Sealing.unwrap(grant.sealedKey, with: held, context: Sealing.grantContext(
                    email: email, vaultID: grant.vaultID, keyID: grant.keyID))) != nil
            }) {
                // The account key here is the right one; only the way into the
                // vault was missing.
                try await grant(vaultKey, vaultID: vault.id, keyID: keyID, accountKey: held)
                try await open(with: held, vault: vault)
                return
            }
            let accountKey = Sealing.newKey()
            let phrase = RecoveryPhrase.make()
            let recovery = await Self.recoveryBody(accountKey, phrase: phrase, email: email)
            AccountKeychain.save(accountKey, email: email)
            try await VaultAPI.updateVault(id: vault.id, recovery)
            // Every old grant was sealed under the lost key.
            for vaultID in Set(grants.map(\.vaultID)) {
                try await VaultAPI.deleteGrants(email: email, vaultID: vaultID)
            }
            try await grant(vaultKey, vaultID: vault.id, keyID: keyID, accountKey: accountKey)
            KeyRing.shared.set(accountKey: accountKey)
            KeyRing.shared.add(vaultKey: vaultKey, keyID: keyID, vaultID: vault.id)
            KeyRing.shared.setOwnVault(id: vault.id, keyID: keyID)
            ownVault = try await VaultAPI.vault(ownerEmail: email)
            phase = .recoveryPhrase(phrase)
        } catch {
            fail(error)
        }
    }

    // MARK: - Imports

    /// Read another vault's contacts from now on. Replaces any older way into
    /// the same vault (one whose key has since changed).
    func addImport(_ pending: PendingImport) async throws {
        guard let email, let accountKey = KeyRing.shared.accountKey, let keyID = pending.vault.keyID
        else { throw VaultError.notSetUp }
        try await grant(pending.key, vaultID: pending.vault.id, keyID: keyID, accountKey: accountKey)
        try await VaultAPI.deleteGrants(email: email, vaultID: pending.vault.id, keeping: keyID)
        KeyRing.shared.add(vaultKey: pending.key, keyID: keyID, vaultID: pending.vault.id)
        await refreshImports()
        await onAccessChanged?()
    }

    /// Stop reading an imported vault. Its contacts leave every list.
    func removeImport(_ item: Import) async throws {
        guard let email else { return }
        let held = try await VaultAPI.grants(email: email).filter { $0.vaultID == item.id }
        try await VaultAPI.deleteGrants(email: email, vaultID: item.id)
        KeyRing.shared.remove(vaultID: item.id, keyIDs: held.map(\.keyID))
        imports.removeAll { $0.id == item.id }
        await onAccessChanged?()
    }

    /// The imported vaults as they stand: their codes now, and whether each
    /// one's key is still the one this account holds.
    func refreshImports() async {
        guard let email, let grants = try? await VaultAPI.grants(email: email) else { return }
        let ownID = ownVault?.id
        let ids = Set(grants.map(\.vaultID)).filter { $0 != ownID }.sorted()
        guard let vaults = try? await VaultAPI.vaults(ids: ids) else { return }
        var list = vaults.map { vault in
            Import(id: vault.id, code: vault.code,
                   isCurrent: grants.contains { $0.vaultID == vault.id && $0.keyID == vault.keyID },
                   contactCount: imports.first { $0.id == vault.id }?.contactCount)
        }
        list.sort { $0.code < $1.code }
        imports = list
        // Counts are a nicety, fetched after the list is up.
        if let ownID { ownContactCount = try? await VaultAPI.contactCount(vaultID: ownID) }
        var counted = list
        for index in counted.indices {
            counted[index].contactCount = try? await VaultAPI.contactCount(vaultID: counted[index].id)
        }
        if imports.map(\.id) == counted.map(\.id) { imports = counted }
    }

    // MARK: - Settings

    /// Give this account's vault a new public code. Anyone who already imported
    /// it keeps reading it; new imports need the new code.
    func changeCode(to typed: String) async throws {
        guard let vault = ownVault, let email else { throw VaultError.notSetUp }
        let code = VaultCode.normalized(typed)
        guard code != vault.code else { return }
        try await VaultAPI.updateVault(id: vault.id, ["code": code])
        ownVault = try await VaultAPI.vault(ownerEmail: email)
    }

    /// Change the private key, and cut off everyone who imported with the old
    /// one: every contact is sealed again under a new key, which only the new
    /// private key opens. They see the code's contacts go until they're given
    /// the new private key.
    func changePrivateKey(current: String, new: String) async throws {
        guard let email, let accountKey = KeyRing.shared.accountKey,
              let vault = try await VaultAPI.vault(ownerEmail: email),
              let keyID = vault.keyID, let sealedKey = vault.sealedKey, let salt = vault.kdfSalt
        else { throw VaultError.notSetUp }
        guard let unlocking = await Self.derive(current, salt: salt, rounds: vault.kdfRounds),
              (try? Sealing.unwrap(sealedKey, with: unlocking,
                                   context: Sealing.vaultKeyContext(vaultID: vault.id, keyID: keyID))) != nil
        else { throw VaultError.wrongPrivateKey }

        let newKeyID = UUID().uuidString.lowercased()
        let newKey = Sealing.newKey()
        let newSalt = Sealing.newSalt().base64EncodedString()
        let rounds = Sealing.defaultRounds
        guard let newUnlocking = await Self.derive(new, salt: newSalt, rounds: rounds) else { throw VaultError.notSetUp }
        let pendingSealed = try Sealing.wrap(newKey, with: newUnlocking,
                                             context: Sealing.vaultKeyContext(vaultID: vault.id, keyID: newKeyID))
        // The new key goes into the account first, then onto the vault as
        // pending: from here a crash leaves everything needed to finish.
        try await grant(newKey, vaultID: vault.id, keyID: newKeyID, accountKey: accountKey)
        try await VaultAPI.updateVault(id: vault.id, [
            "pending_key_id": newKeyID, "pending_kdf_salt": newSalt,
            "pending_kdf_rounds": rounds, "pending_sealed_key": pendingSealed
        ])
        KeyRing.shared.add(vaultKey: newKey, keyID: newKeyID, vaultID: vault.id)
        guard let pending = try await VaultAPI.vault(ownerEmail: email) else { throw VaultError.notSetUp }
        defer {
            progress = nil
            progressDetail = nil
            workLabel = nil
        }
        try await finishKeyChange(pending)
        await onAccessChanged?()
    }

    /// Seal every contact again under the pending key, then make it the
    /// vault's key and drop the old one. Resumable: rows already moved are
    /// skipped, and nothing about the new private key is needed.
    private func finishKeyChange(_ vault: VaultRow) async throws {
        guard let email, let newKeyID = vault.pendingKeyID else { return }
        guard KeyRing.shared.vaultKey(newKeyID) != nil, let pendingSealed = vault.pendingSealedKey,
              let pendingSalt = vault.pendingKdfSalt else {
            // The change never got as far as the account: forget it.
            try await VaultAPI.updateVault(id: vault.id, Self.clearedPending)
            return
        }
        // New contacts go in under the new key from now on.
        KeyRing.shared.setOwnVault(id: vault.id, keyID: newKeyID)
        let filters = [URLQueryItem(name: "vault_id", value: "eq.\(vault.id)"),
                       URLQueryItem(name: "or", value: "(key_id.is.null,key_id.neq.\(newKeyID))")]
        try await reseal(filters: filters, label: "Re-encrypting your contacts…") { row in
            guard let id = row["id"] as? String else { return nil }
            let fields: KeyRing.ContactFields
            if let sealed = row["sealed"] as? String, let keyID = row["key_id"] as? String {
                guard let opened = try? KeyRing.shared.openContact(sealed, id: id, vaultID: vault.id, keyID: keyID)
                else { return nil }
                fields = opened
            } else {
                fields = Self.plainFields(row)
            }
            return try Self.contactRow(row, fields: fields)
        }
        // The vault's company links, the same way. A database without their
        // table has none to move.
        do {
            try await reseal(path: "company_links", filters: filters, label: "Re-encrypting your company links…") { row in
                guard let id = row["id"] as? String, let sealed = row["sealed"] as? String,
                      let keyID = row["key_id"] as? String,
                      let links = try? KeyRing.shared.openCompanyLinks(sealed, id: id, vaultID: vault.id, keyID: keyID)
                else { return nil }
                var out = row
                (out["sealed"], out["vault_id"], out["key_id"]) = try KeyRing.shared.sealOwnCompanyLinks(links, id: id)
                return out
            }
        } catch SupabaseError.schemaOutOfDate {}
        try await VaultAPI.updateVault(id: vault.id, [
            "key_id": newKeyID, "kdf_salt": pendingSalt,
            "kdf_rounds": vault.pendingKdfRounds ?? Sealing.defaultRounds, "sealed_key": pendingSealed
        ].merging(Self.clearedPending) { a, _ in a })
        try await VaultAPI.deleteGrants(email: email, vaultID: vault.id, keeping: newKeyID)
        ownVault = try await VaultAPI.vault(ownerEmail: email)
    }

    private static let clearedPending: [String: Any] = [
        "pending_key_id": NSNull(), "pending_kdf_salt": NSNull(),
        "pending_kdf_rounds": NSNull(), "pending_sealed_key": NSNull()
    ]

    /// A new recovery phrase for the same account key. The old one stops working.
    func makeNewRecoveryPhrase() async throws -> String {
        guard let email, let vault = ownVault, let accountKey = KeyRing.shared.accountKey else { throw VaultError.notSetUp }
        let phrase = RecoveryPhrase.make()
        try await VaultAPI.updateVault(id: vault.id, await Self.recoveryBody(accountKey, phrase: phrase, email: email))
        ownVault = try await VaultAPI.vault(ownerEmail: email)
        return phrase
    }

    // MARK: - Sealing what's still plain

    /// Seal this account's plain rows: its vault's contacts, then its sends,
    /// templates and profile. Each table's query asks only for plain rows, so
    /// once done this is four empty reads.
    private func sealPlainRows() async throws {
        guard let email, let vault = ownVault else { return }
        try await reseal(filters: [URLQueryItem(name: "vault_id", value: "eq.\(vault.id)"),
                                   URLQueryItem(name: "sealed", value: "is.null")],
                         label: "Encrypting your contacts…") { row in
            try Self.contactRow(row, fields: Self.plainFields(row))
        }

        let mine = URLQueryItem(name: "user_email", value: "eq.\(email)")
        try await reseal(path: "mail_sends",
                         filters: [mine, URLQueryItem(name: "or", value: "(subject.not.is.null,body.not.is.null,reply_from.not.is.null,reply_snippet.not.is.null)")],
                         label: "Encrypting your mail history…") { row in
            guard let id = row["id"] as? String else { return nil }
            var out = row
            let subject = row["subject"] as? String, body = row["body"] as? String
            if subject != nil || body != nil {
                out["sealed"] = try KeyRing.shared.sealPersonal(SealedMail(subject: subject, body: body),
                                                                context: Sealing.sendContext(id: id))
            }
            let from = row["reply_from"] as? String, snippet = row["reply_snippet"] as? String
            if from != nil || snippet != nil {
                out["sealed_reply"] = try KeyRing.shared.sealPersonal(SealedReply(from: from, snippet: snippet),
                                                                      context: Sealing.replyContext(id: id))
            }
            for column in ["subject", "body", "reply_from", "reply_snippet"] { out[column] = NSNull() }
            return out
        }

        try await reseal(path: "templates", filters: [mine, URLQueryItem(name: "sealed", value: "is.null")],
                         label: "Encrypting your templates…") { row in
            guard let id = row["id"] as? String else { return nil }
            let template = SealedTemplate(name: row["name"] as? String ?? "", subject: row["subject"] as? String ?? "",
                                          content: row["content"] as? String ?? "")
            var out = row
            out["sealed"] = try KeyRing.shared.sealPersonal(template, context: Sealing.templateContext(id: id))
            for column in ["name", "subject", "content"] { out[column] = NSNull() }
            return out
        }

        let plainProfile = try await VaultAPI.count("profiles", [URLQueryItem(name: "email", value: "eq.\(email)"),
                                                                 URLQueryItem(name: "sealed", value: "is.null")],
                                                     column: "email")
        if plainProfile > 0, let profile = try await SupabaseAPI.fetchProfile(email: email) {
            try await SupabaseAPI.upsertProfile(email: email, profile: profile)
        }
    }

    /// Rewrite every row matching `filters`, a page at a time, as `transform`
    /// returns it (nil leaves a row as it is). Pages are read in id order and
    /// each starts after the last id seen, so rows left alone are never read
    /// twice and the loop always ends.
    private func reseal(path: String = "recruiters", filters: [URLQueryItem], label: String,
                        transform: ([String: Any]) throws -> [String: Any]?) async throws {
        let total = try await VaultAPI.count(path, filters)
        guard total > 0 else { return }
        // Inside the app (a key change from Settings) the app stays up and
        // Settings shows the progress; before it, this is the screen.
        if phase != .ready { phase = .working(label) }
        workLabel = label
        var done = 0
        var after: String?
        progress = 0
        while true {
            let page = try await VaultAPI.rows(path, select: "*",
                                               filters + (after.map { [URLQueryItem(name: "id", value: "gt.\($0)")] } ?? []),
                                               limit: 500)
            guard let last = page.last?["id"] as? String else { break }
            after = last
            let rewritten = try page.compactMap(transform)
            try await VaultAPI.overwrite(path, rows: rewritten)
            done += page.count
            progress = min(1, Double(done) / Double(total))
            progressDetail = "\(done.formatted()) of \(total.formatted())"
        }
        progressDetail = nil
        workLabel = nil
    }

    /// A contact row as it's written back: the columns the table requires,
    /// the fields sealed into the user's own vault, the plain ones emptied.
    private static func contactRow(_ row: [String: Any], fields: KeyRing.ContactFields) throws -> [String: Any]? {
        guard let id = row["id"] as? String, let companyID = row["company_id"] else { return nil }
        let (sealed, vaultID, keyID) = try KeyRing.shared.sealOwnContact(fields, id: id)
        return ["id": id, "company_id": companyID, "vault_id": vaultID, "key_id": keyID, "sealed": sealed,
                "name": NSNull(), "email": NSNull(), "position": NSNull(), "phone": NSNull(), "greeting_name": NSNull()]
    }

    private static func plainFields(_ row: [String: Any]) -> KeyRing.ContactFields {
        func text(_ key: String) -> String? {
            guard let value = row[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        return KeyRing.ContactFields(name: text("name"), email: text("email"), position: text("position"),
                                     phone: text("phone"), greetingName: text("greeting_name"))
    }

    // MARK: - Key plumbing

    /// Seal `key` into an account's grant row.
    private func grant(_ key: SymmetricKey, vaultID: String, keyID: String, accountKey: SymmetricKey) async throws {
        guard let email else { throw VaultError.notSetUp }
        let sealed = try Sealing.wrap(key, with: accountKey,
                                      context: Sealing.grantContext(email: email, vaultID: vaultID, keyID: keyID))
        try await VaultAPI.addGrant(email: email, vaultID: vaultID, keyID: keyID, sealedKey: sealed)
    }

    /// The vault row's key columns (`key` under `privateKey`) and recovery
    /// columns (`accountKey` under `phrase`), both derivations off the main actor.
    private static func sealing(_ key: SymmetricKey, under privateKey: String, vaultID: String, keyID: String,
                                accountKey: SymmetricKey, phrase: String,
                                email: String) async -> ([String: Any], [String: Any]) {
        let salt = Sealing.newSalt().base64EncodedString()
        async let unlocking = derive(privateKey, salt: salt, rounds: Sealing.defaultRounds)
        async let recovery = recoveryBody(accountKey, phrase: phrase, email: email)
        let wrapped = (await unlocking).flatMap {
            try? Sealing.wrap(key, with: $0, context: Sealing.vaultKeyContext(vaultID: vaultID, keyID: keyID))
        }
        return (["key_id": keyID, "kdf_salt": salt, "kdf_rounds": Sealing.defaultRounds,
                 "sealed_key": wrapped ?? NSNull()], await recovery)
    }

    private static func recoveryBody(_ accountKey: SymmetricKey, phrase: String, email: String) async -> [String: Any] {
        let salt = Sealing.newSalt().base64EncodedString()
        let normalized = RecoveryPhrase.normalized(phrase) ?? phrase
        guard let unlocking = await derive(normalized, salt: salt, rounds: Sealing.defaultRounds),
              let sealed = try? Sealing.wrap(accountKey, with: unlocking, context: Sealing.accountContext(email: email))
        else { return [:] }
        return ["recovery_salt": salt, "recovery_rounds": Sealing.defaultRounds, "sealed_account_key": sealed]
    }

    /// A key from something typed, worked out off the main actor (it takes a
    /// noticeable moment on purpose). Nil for a salt that isn't base-64.
    nonisolated private static func derive(_ secret: String, salt: String, rounds: Int?) async -> SymmetricKey? {
        guard let saltData = Data(base64Encoded: salt) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            Sealing.deriveKey(from: secret, salt: saltData, rounds: rounds ?? Sealing.defaultRounds)
        }.value
    }
}
