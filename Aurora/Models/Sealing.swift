import Foundation
import CryptoKit
import CommonCrypto

/// The app's one cipher. Everything private that goes to the database — a
/// contact's details, a sent mail, a template, the profile — leaves the phone
/// sealed here and is opened only on a phone holding the key.
///
/// AES-256-GCM, so a sealed value can't be read *or* altered unnoticed. Each
/// seal is bound to where it lives (`context`: the table, the row's id, the
/// vault): a sealed contact copied onto another row, or moved to another vault,
/// no longer opens.
///
/// Keys made from something typed (a private key, a recovery phrase) go
/// through PBKDF2-SHA256 at `defaultRounds`, because the sealed copies sit in a
/// database anyone holding the app's public key can read, and the only thing
/// between them and a guess is how long each guess takes.
nonisolated enum Sealing {
    /// Bumped if the format ever changes, so old values still open.
    private static let prefix = "v1."

    /// OWASP's 2023 figure for PBKDF2-SHA256: about half a second on a phone.
    static let defaultRounds = 600_000

    enum Failure: LocalizedError {
        /// The key is wrong, or the value was changed or moved.
        case cannotOpen
        case malformed

        var errorDescription: String? {
            switch self {
            case .cannotOpen: "This couldn't be unlocked with that key."
            case .malformed: "The stored value isn't in a form the app can read."
            }
        }
    }

    // MARK: Keys

    static func newKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    static func newSalt() -> Data { randomBytes(16) }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "The system random number generator failed.")
        return Data(bytes)
    }

    /// A key from something typed. Slow on purpose (see the type's note), so
    /// call it off the main actor.
    static func deriveKey(from secret: String, salt: Data, rounds: Int) -> SymmetricKey {
        let password = Array(normalized(secret).utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBytes in
            password.withUnsafeBufferPointer { passwordBytes in
                passwordBytes.withMemoryRebound(to: Int8.self) { passwordChars in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         passwordChars.baseAddress, passwordChars.count,
                                         saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds),
                                         &derived, derived.count)
                }
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 failed.")
        return SymmetricKey(data: derived)
    }

    /// What's typed, as it's keyed: surrounding space dropped, and accents
    /// in one canonical form so the same word typed on two keyboards matches.
    static func normalized(_ secret: String) -> String {
        secret.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }

    // MARK: Sealing

    static func seal(_ plaintext: Data, with key: SymmetricKey, context: String) throws -> String {
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: Data(context.utf8))
        guard let combined = box.combined else { throw Failure.malformed }
        return prefix + combined.base64EncodedString()
    }

    static func open(_ sealed: String, with key: SymmetricKey, context: String) throws -> Data {
        guard sealed.hasPrefix(prefix),
              let combined = Data(base64Encoded: String(sealed.dropFirst(prefix.count))),
              let box = try? AES.GCM.SealedBox(combined: combined) else { throw Failure.malformed }
        do {
            return try AES.GCM.open(box, using: key, authenticating: Data(context.utf8))
        } catch {
            throw Failure.cannotOpen
        }
    }

    static func seal<Value: Encodable>(json value: Value, with key: SymmetricKey, context: String) throws -> String {
        try seal(try encoder.encode(value), with: key, context: context)
    }

    static func open<Value: Decodable>(_ type: Value.Type, from sealed: String, with key: SymmetricKey,
                                       context: String) throws -> Value {
        try decoder.decode(type, from: try open(sealed, with: key, context: context))
    }

    /// One key sealed under another — a vault's key under a private key's, or
    /// under the account key.
    static func wrap(_ key: SymmetricKey, with wrappingKey: SymmetricKey, context: String) throws -> String {
        try seal(key.withUnsafeBytes { Data($0) }, with: wrappingKey, context: context)
    }

    static func unwrap(_ sealed: String, with wrappingKey: SymmetricKey, context: String) throws -> SymmetricKey {
        let raw = try open(sealed, with: wrappingKey, context: context)
        guard raw.count == 32 else { throw Failure.malformed }
        return SymmetricKey(data: raw)
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    // MARK: Contexts
    //
    // Where each sealed value lives, bound into its seal. Change one and every
    // value sealed under the old wording stops opening — they're part of the
    // stored format.

    static func contactContext(id: String, vaultID: String) -> String { "aurora.contact.v1|\(id.lowercased())|\(vaultID.lowercased())" }
    static func sendContext(id: String) -> String { "aurora.send.v1|\(id.lowercased())" }
    static func replyContext(id: String) -> String { "aurora.reply.v1|\(id.lowercased())" }
    static func templateContext(id: String) -> String { "aurora.template.v1|\(id.lowercased())" }
    static func profileContext(email: String) -> String { "aurora.profile.v1|\(email.lowercased())" }
    /// A vault's key under the key made from its private key.
    static func vaultKeyContext(vaultID: String, keyID: String) -> String {
        "aurora.vault.v1|\(vaultID.lowercased())|\(keyID.lowercased())"
    }
    /// A vault's key under an account key: one account's way into it.
    static func grantContext(email: String, vaultID: String, keyID: String) -> String {
        "aurora.grant.v1|\(email.lowercased())|\(vaultID.lowercased())|\(keyID.lowercased())"
    }
    /// The account key under the key made from the recovery phrase.
    static func accountContext(email: String) -> String { "aurora.account.v1|\(email.lowercased())" }
}

// MARK: - Recovery phrase

/// The account key's paper backup: 24 characters in six groups ("K7QM-2XRP-…"),
/// 120 random bits. Crockford's base-32 alphabet, so there's no 0/O or 1/I/L to
/// misread, and a misread one is taken the way it was meant.
nonisolated enum RecoveryPhrase {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    static let length = 24

    static func make() -> String {
        let bytes = Sealing.randomBytes(length)
        let characters = bytes.map { alphabet[Int($0) & 31] }
        return stride(from: 0, to: length, by: 4)
            .map { String(characters[$0..<min($0 + 4, length)]) }
            .joined(separator: "-")
    }

    /// As it's keyed: upper case, no separators, look-alikes folded. Nil when
    /// what's left can't be a phrase.
    static func normalized(_ typed: String) -> String? {
        var out = ""
        for character in typed.uppercased() {
            switch character {
            case "-", " ", "\n", "\t": continue
            case "O": out.append("0")
            case "I", "L": out.append("1")
            default:
                guard alphabet.contains(character) else { return nil }
                out.append(character)
            }
        }
        return out.count == length ? out : nil
    }
}

// MARK: - Codes

/// A vault's public code ("AURORA", "ABC123"): what someone types to import its
/// contacts, alongside its private key.
nonisolated enum VaultCode {
    static let lengths = 4...16

    /// Upper case, spaces dropped.
    static func normalized(_ typed: String) -> String {
        typed.uppercased().filter { !$0.isWhitespace }
    }

    /// Why `code` can't be used, or nil when it can.
    static func problem(with code: String) -> String? {
        let code = normalized(code)
        if code.isEmpty { return "Choose a code." }
        if !code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) { return "Use only letters and numbers." }
        if !lengths.contains(code.count) { return "Use \(lengths.lowerBound) to \(lengths.upperBound) characters." }
        return nil
    }
}

/// The rules for a private key, the same in onboarding and Settings.
nonisolated enum PrivateKeyRule {
    static let minimumLength = 8

    static func problem(with key: String, confirmation: String) -> String? {
        let key = Sealing.normalized(key)
        if key.count < minimumLength { return "Use at least \(minimumLength) characters." }
        if key != Sealing.normalized(confirmation) { return "The two keys don't match." }
        return nil
    }
}
