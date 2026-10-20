import Foundation
import CryptoKit
import Security

/// The keys this phone holds once the account is unlocked: the account key
/// (the user's own mail, templates and profile, and their way into each vault)
/// and the key of every vault it can read — the user's own, and each one
/// imported with a code and its private key.
///
/// One shared instance, because decoding a row anywhere in the app has to be
/// able to open it. Empty until `VaultStore` unlocks, and emptied on sign-out.
nonisolated final class KeyRing: @unchecked Sendable {
    static let shared = KeyRing()

    private let lock = NSLock()
    private var _accountKey: SymmetricKey?
    private var _ownVaultID: String?
    /// Every vault key held, by key id: a vault mid-rotation has two.
    private var _vaultKeys: [String: SymmetricKey] = [:]
    /// The vaults whose contacts this account can read.
    private var _readableVaults: Set<String> = []
    /// The key the user's own vault seals new contacts with.
    private var _ownKeyID: String?

    var accountKey: SymmetricKey? { lock.withLock { _accountKey } }
    var ownVaultID: String? { lock.withLock { _ownVaultID } }
    var ownKeyID: String? { lock.withLock { _ownKeyID } }
    var readableVaults: Set<String> { lock.withLock { _readableVaults } }

    func set(accountKey: SymmetricKey?) { lock.withLock { _accountKey = accountKey } }

    func setOwnVault(id: String, keyID: String) {
        lock.withLock {
            _ownVaultID = id.lowercased()
            _ownKeyID = keyID.lowercased()
            _readableVaults.insert(id.lowercased())
        }
    }

    func add(vaultKey: SymmetricKey, keyID: String, vaultID: String) {
        lock.withLock {
            _vaultKeys[keyID.lowercased()] = vaultKey
            _readableVaults.insert(vaultID.lowercased())
        }
    }

    /// Stop reading a vault (an import removed). Its keys go too.
    func remove(vaultID: String, keyIDs: [String]) {
        lock.withLock {
            _readableVaults.remove(vaultID.lowercased())
            for id in keyIDs { _vaultKeys[id.lowercased()] = nil }
        }
    }

    func vaultKey(_ keyID: String) -> SymmetricKey? { lock.withLock { _vaultKeys[keyID.lowercased()] } }

    func canRead(vault vaultID: String?) -> Bool {
        guard let vaultID else { return false }
        return lock.withLock { _readableVaults.contains(vaultID.lowercased()) }
    }

    func owns(vault vaultID: String?) -> Bool {
        guard let vaultID else { return false }
        return lock.withLock { _ownVaultID == vaultID.lowercased() }
    }

    func clear() {
        lock.withLock {
            _accountKey = nil
            _ownVaultID = nil
            _ownKeyID = nil
            _vaultKeys = [:]
            _readableVaults = []
        }
    }

    // MARK: Opening rows

    /// A contact's private fields, as sealed into its row.
    struct ContactFields: Codable, Equatable {
        var name: String?
        var email: String?
        var position: String?
        var phone: String?
        var greetingName: String?

        enum CodingKeys: String, CodingKey {
            case name = "n", email = "e", position = "p", phone = "t", greetingName = "g"
        }
    }

    enum Locked: Error {
        /// A row from a vault this account can't read: skipped, never shown.
        case notReadable
        /// A readable vault's row sealed under a key this phone doesn't hold.
        case missingKey
    }

    func openContact(_ sealed: String, id: String, vaultID: String, keyID: String) throws -> ContactFields {
        guard canRead(vault: vaultID) else { throw Locked.notReadable }
        guard let key = vaultKey(keyID) else { throw Locked.missingKey }
        return try Sealing.open(ContactFields.self, from: sealed, with: key,
                                context: Sealing.contactContext(id: id, vaultID: vaultID))
    }

    /// Seal a contact for the user's own vault. Throws when nothing is unlocked.
    func sealOwnContact(_ fields: ContactFields, id: String) throws -> (sealed: String, vaultID: String, keyID: String) {
        let (vaultID, keyID, key): (String?, String?, SymmetricKey?) = lock.withLock {
            (_ownVaultID, _ownKeyID, _ownKeyID.flatMap { _vaultKeys[$0] })
        }
        guard let vaultID, let keyID, let key else { throw Locked.missingKey }
        let sealed = try Sealing.seal(json: fields, with: key, context: Sealing.contactContext(id: id, vaultID: vaultID))
        return (sealed, vaultID, keyID)
    }

    /// Open something sealed under the account key. Nil when it can't be — a
    /// row from before a reset reads as empty rather than failing the load.
    func openPersonal<Value: Decodable>(_ type: Value.Type, from sealed: String?, context: String) -> Value? {
        guard let sealed, let key = accountKey else { return nil }
        return try? Sealing.open(type, from: sealed, with: key, context: context)
    }

    func sealPersonal<Value: Encodable>(_ value: Value, context: String) throws -> String {
        guard let key = accountKey else { throw Locked.missingKey }
        return try Sealing.seal(json: value, with: key, context: context)
    }
}

// MARK: - Account key in the keychain

/// The account key, kept in the keychain and synced by iCloud Keychain, so a
/// new phone signed in to the same Apple account unlocks without the recovery
/// phrase. One per Gmail address.
nonisolated enum AccountKeychain {
    private static let service = "com.realaryan.aurora.account-key"

    static func load(email: String) -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: email.lowercased(),
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    /// Store `key`, replacing any held for `email`. Synced where iCloud
    /// Keychain allows it, kept on this phone where it doesn't.
    @discardableResult
    static func save(_ key: SymmetricKey, email: String) -> Bool {
        delete(email: email)
        let data = key.withUnsafeBytes { Data($0) }
        for synchronizable in [true, false] {
            let item: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: email.lowercased(),
                kSecAttrSynchronizable as String: synchronizable,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
                kSecValueData as String: data
            ]
            if SecItemAdd(item as CFDictionary, nil) == errSecSuccess { return true }
        }
        return false
    }

    static func delete(email: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: email.lowercased(),
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        SecItemDelete(query as CFDictionary)
    }
}
