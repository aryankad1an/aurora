import Foundation
import CryptoKit

// Compiled against the app's own files:
//   swiftc -parse-as-library Aurora/Models/Sealing.swift Aurora/Models/KeyRing.swift \
//     Tests/SealingTests.swift -o /tmp/seal && /tmp/seal

@main
struct SealingTests {
    nonisolated(unsafe) static var failures = 0

    static func check(_ condition: Bool, _ message: String) {
        if !condition { failures += 1; print("FAIL: \(message)") }
    }

    static func main() throws {
        let key = Sealing.newKey()
        let other = Sealing.newKey()

        // Round trip, and the context is part of the seal.
        let sealed = try Sealing.seal(Data("hello".utf8), with: key, context: "a")
        check(sealed.hasPrefix("v1."), "sealed values carry their version")
        check(try Sealing.open(sealed, with: key, context: "a") == Data("hello".utf8), "opens with its key and context")
        check((try? Sealing.open(sealed, with: other, context: "a")) == nil, "a wrong key doesn't open it")
        check((try? Sealing.open(sealed, with: key, context: "b")) == nil, "a value moved elsewhere doesn't open")
        let twice = try Sealing.seal(Data("hello".utf8), with: key, context: "a")
        check(twice != sealed, "each seal uses a fresh nonce")

        // Tampering is caught.
        var bytes = Data(base64Encoded: String(sealed.dropFirst(3)))!
        bytes[bytes.count - 1] ^= 1
        check((try? Sealing.open("v1." + bytes.base64EncodedString(), with: key, context: "a")) == nil,
              "a changed byte doesn't open")
        check((try? Sealing.open("garbage", with: key, context: "a")) == nil, "garbage doesn't open")

        // Key wrapping.
        let wrapped = try Sealing.wrap(key, with: other, context: "w")
        let unwrapped = try Sealing.unwrap(wrapped, with: other, context: "w")
        check(unwrapped.withUnsafeBytes { Data($0) } == key.withUnsafeBytes { Data($0) }, "a wrapped key unwraps")

        // Derived keys: same input, same key; normalisation; salt matters.
        let salt = Sealing.newSalt()
        let k1 = Sealing.deriveKey(from: "correct horse", salt: salt, rounds: 1_000)
        let k2 = Sealing.deriveKey(from: "  correct horse\n", salt: salt, rounds: 1_000)
        let k3 = Sealing.deriveKey(from: "correct horse", salt: Sealing.newSalt(), rounds: 1_000)
        let k4 = Sealing.deriveKey(from: "Correct horse", salt: salt, rounds: 1_000)
        func raw(_ k: SymmetricKey) -> Data { k.withUnsafeBytes { Data($0) } }
        check(raw(k1) == raw(k2), "surrounding space doesn't change the key")
        check(raw(k1) != raw(k3), "a different salt gives a different key")
        check(raw(k1) != raw(k4), "case matters in a private key")
        let composed = Sealing.deriveKey(from: "caf\u{E9}", salt: salt, rounds: 1_000)
        let decomposed = Sealing.deriveKey(from: "cafe\u{301}", salt: salt, rounds: 1_000)
        check(raw(composed) == raw(decomposed), "the same accented word from two keyboards matches")

        // PBKDF2 against a published vector (RFC 7914 §11, PBKDF2-HMAC-SHA256).
        let vector = Sealing.deriveKey(from: "passwd", salt: Data("salt".utf8), rounds: 1)
        check(raw(vector).prefix(16).map { String(format: "%02x", $0) }.joined() == "55ac046e56e3089fec1691c22544b605",
              "PBKDF2-SHA256 matches RFC 7914")

        // Recovery phrases.
        let phrase = RecoveryPhrase.make()
        check(phrase.count == 24 + 5 && phrase.split(separator: "-").count == 6, "a phrase is six groups of four")
        check(RecoveryPhrase.normalized(phrase) == phrase.replacingOccurrences(of: "-", with: ""), "a phrase reads back")
        check(RecoveryPhrase.normalized(phrase.lowercased().replacingOccurrences(of: "-", with: " ")) != nil,
              "lower case and spaces are fine")
        check(RecoveryPhrase.normalized("ABCD") == nil, "a short phrase is refused")
        check(RecoveryPhrase.normalized("O0IL" + String(repeating: "A", count: 20)) == "0011" + String(repeating: "A", count: 20),
              "look-alike letters fold to digits")
        var seen = Set<String>()
        for _ in 0..<200 { seen.insert(RecoveryPhrase.make()) }
        check(seen.count == 200, "phrases don't repeat")

        // Codes and private keys.
        check(VaultCode.normalized(" abc 123 ") == "ABC123", "codes are upper case without spaces")
        check(VaultCode.problem(with: "AURORA") == nil, "AURORA is a fine code")
        check(VaultCode.problem(with: "AB") != nil, "too short")
        check(VaultCode.problem(with: "ABC-123") != nil, "letters and numbers only")
        check(PrivateKeyRule.problem(with: "short", confirmation: "short") != nil, "too short a key")
        check(PrivateKeyRule.problem(with: "long enough", confirmation: "long enougH") != nil, "mismatch")
        check(PrivateKeyRule.problem(with: "long enough", confirmation: "long enough ") == nil, "a match")

        // The key ring: only readable vaults open, only the own vault seals.
        let ring = KeyRing()
        let vault = UUID().uuidString.lowercased(), keyID = UUID().uuidString.lowercased()
        let vaultKey = Sealing.newKey()
        ring.add(vaultKey: vaultKey, keyID: keyID, vaultID: vault)
        ring.setOwnVault(id: vault, keyID: keyID)
        let contactID = UUID().uuidString.lowercased()
        let fields = KeyRing.ContactFields(name: "Ada Lovelace", email: "ada@example.com", position: nil,
                                           phone: nil, greetingName: "Ada")
        let own = try ring.sealOwnContact(fields, id: contactID)
        check(own.vaultID == vault && own.keyID == keyID, "own contacts seal into the own vault")
        check(try ring.openContact(own.sealed, id: contactID, vaultID: vault, keyID: keyID) == fields, "and open again")
        check(!own.sealed.contains("ada"), "nothing readable is left in the sealed value")
        check((try? ring.openContact(own.sealed, id: UUID().uuidString, vaultID: vault, keyID: keyID)) == nil,
              "a contact copied to another row doesn't open")
        let elsewhere = UUID().uuidString
        check((try? ring.openContact(own.sealed, id: contactID, vaultID: elsewhere, keyID: keyID)) == nil,
              "a vault this account can't read stays shut")
        ring.remove(vaultID: vault, keyIDs: [keyID])
        check((try? ring.openContact(own.sealed, id: contactID, vaultID: vault, keyID: keyID)) == nil,
              "a removed import stays shut")

        ring.set(accountKey: Sealing.newKey())
        let personal = try ring.sealPersonal(["subject": "Hi"], context: Sealing.sendContext(id: "x"))
        check(ring.openPersonal([String: String].self, from: personal, context: Sealing.sendContext(id: "x"))?["subject"] == "Hi",
              "personal values open with the account key")
        ring.set(accountKey: Sealing.newKey())
        check(ring.openPersonal([String: String].self, from: personal, context: Sealing.sendContext(id: "x")) == nil,
              "and not with another")

        // A real-strength derivation, timed, so a slow phone is noticed.
        let start = Date()
        _ = Sealing.deriveKey(from: "a private key", salt: salt, rounds: Sealing.defaultRounds)
        print(String(format: "PBKDF2 at %d rounds: %.2fs", Sealing.defaultRounds, Date().timeIntervalSince(start)))

        print(failures == 0 ? "All sealing tests passed." : "\(failures) failure(s).")
        exit(failures == 0 ? 0 : 1)
    }
}
