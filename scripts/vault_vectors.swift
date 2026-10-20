import Foundation
import CryptoKit

// Cross-checks scripts/vault_crypto.py against the app's own sealing code.
// Compiled against Sealing.swift and KeyRing.swift (test_vault_crypto.py does
// this when swiftc is on hand):
//
//   swiftc -parse-as-library Aurora/Models/Sealing.swift Aurora/Models/KeyRing.swift \
//     scripts/vault_vectors.swift -o <scratch>/vault_vectors
//   <scratch>/vault_vectors make  > scripts/vault_vectors.json   # Swift seals, Python opens
//   <scratch>/vault_vectors open < python_sealed.json            # Python seals, Swift opens
//
// Every key, secret and value here is made up.

@main
struct VaultVectors {
    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    static func raw(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }
    static func data(hex: String) -> Data {
        var out = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    static func main() throws {
        switch CommandLine.arguments.dropFirst().first {
        case "make": try make()
        case "open": try open()
        default:
            FileHandle.standardError.write(Data("usage: vault_vectors make|open\n".utf8))
            exit(2)
        }
    }

    // MARK: Swift seals

    static func make() throws {
        let key = SymmetricKey(data: data(hex: String(repeating: "0f1e2d3c4b5a6978", count: 4)))
        let id = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
        let vaultID = "0E984725-C51C-4BF4-9960-E1C80E27ABA0"
        let keyID = "8C2D1A7E-5B3F-4E21-9A0B-7D6C5E4F3A21"
        let email = "Maya.Rao@Example.com"

        let contexts: [String: String] = [
            "contact": Sealing.contactContext(id: id, vaultID: vaultID),
            "company_links": Sealing.companyLinksContext(id: id, vaultID: vaultID),
            "send": Sealing.sendContext(id: id),
            "reply": Sealing.replyContext(id: id),
            "template": Sealing.templateContext(id: id),
            "profile": Sealing.profileContext(email: email),
            "vault_key": Sealing.vaultKeyContext(vaultID: vaultID, keyID: keyID),
            "grant": Sealing.grantContext(email: email, vaultID: vaultID, keyID: keyID),
            "account": Sealing.accountContext(email: email),
        ]

        var seals: [[String: Any]] = []
        let plaintexts = ["", "hello", String(repeating: "sixteen bytes!!!", count: 3), "Zoë — café ☕️ 名前"]
        for (index, text) in plaintexts.enumerated() {
            let context = index == 0 ? "" : contexts["send"]!
            seals.append(["plaintext_hex": hex(Data(text.utf8)), "context": context,
                          "sealed": try Sealing.seal(Data(text.utf8), with: key, context: context)])
        }

        let full = KeyRing.ContactFields(name: "Maya Rao", email: "maya.rao@example.com", position: "Talent Partner",
                                         phone: "+91 98765 43210", greetingName: "Maya",
                                         linkedIn: "https://www.linkedin.com/in/maya-rao-example",
                                         location: "Pune, Maharashtra, India")
        let sparse = KeyRing.ContactFields(name: "Zoë Ünal", email: "zoe/unal@example.com", position: nil,
                                           phone: nil, greetingName: nil)
        let noAddress = KeyRing.ContactFields(name: "Ravi Menon", email: nil, position: "Recruiter", phone: nil,
                                              greetingName: nil, linkedIn: "https://www.linkedin.com/in/ravi-menon-example",
                                              location: nil)
        var contacts: [[String: Any]] = []
        for fields in [full, sparse, noAddress] {
            contacts.append(["id": id, "vault_id": vaultID, "fields": fieldsJSON(fields),
                             "sealed": try Sealing.seal(json: fields, with: key,
                                                        context: Sealing.contactContext(id: id, vaultID: vaultID))])
        }

        let linkSets = [
            KeyRing.CompanyLinks(linkedIn: "https://www.linkedin.com/company/acme-example",
                                 x: "https://x.com/acme_example", facebook: "https://www.facebook.com/AcmeExample"),
            KeyRing.CompanyLinks(linkedIn: nil, x: "https://x.com/zoe_example", facebook: nil),
        ]
        var companyLinks: [[String: Any]] = []
        for links in linkSets {
            companyLinks.append(["id": id, "vault_id": vaultID, "links": linksJSON(links),
                                 "sealed": try Sealing.seal(json: links, with: key,
                                                            context: Sealing.companyLinksContext(id: id, vaultID: vaultID))])
        }

        // Derived keys, including the normalisation's edges: Unicode spaces
        // Foundation trims, ones it keeps, and two spellings of one accent.
        let salt = data(hex: "a1b2c3d4e5f60718293a4b5c6d7e8f90")
        let secrets = ["correct horse", "  correct horse\n", "\u{00A0}\u{2028}\u{3000}\u{1680}\u{0085}x\u{2029}\t",
                       "\u{200B}x\u{FEFF}", "\u{202F}\u{205F}x\u{200A}\u{180E}", "\u{1C}x\u{1F}", "caf\u{E9}", "cafe\u{301}", "Ω≈ç√ 鍵"]
        var derived: [[String: Any]] = []
        for secret in secrets {
            derived.append(["secret": secret, "salt_hex": hex(salt), "rounds": 1_000,
                            "key_hex": hex(raw(Sealing.deriveKey(from: secret, salt: salt, rounds: 1_000)))])
        }
        derived.append(["secret": "AURORA private key", "salt_hex": hex(salt), "rounds": Sealing.defaultRounds,
                        "key_hex": hex(raw(Sealing.deriveKey(from: "AURORA private key", salt: salt,
                                                             rounds: Sealing.defaultRounds)))])

        // A vault as VaultStore writes it: its key wrapped under the key made
        // from the private key, the salt in base 64.
        let vaultKey = key
        let vaultSalt = data(hex: "00112233445566778899aabbccddeeff")
        let privateKey = "  correct horse battery staple "
        let unlocking = Sealing.deriveKey(from: privateKey, salt: vaultSalt, rounds: 1_000)
        let vault: [String: Any] = [
            "id": vaultID.lowercased(), "code": "TESTVAULT", "key_id": keyID.lowercased(),
            "kdf_salt": vaultSalt.base64EncodedString(), "kdf_rounds": 1_000,
            "sealed_key": try Sealing.wrap(vaultKey, with: unlocking,
                                           context: Sealing.vaultKeyContext(vaultID: vaultID, keyID: keyID)),
        ]

        let out: [String: Any] = [
            "key_hex": hex(raw(key)), "contexts": contexts, "seals": seals, "contacts": contacts,
            "company_links": companyLinks,
            "derived": derived,
            "vault": ["row": vault, "private_key": privateKey, "vault_key_hex": hex(raw(vaultKey))],
        ]
        let json = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(json)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    static func fieldsJSON(_ f: KeyRing.ContactFields) -> [String: Any] {
        ["name": f.name ?? NSNull(), "email": f.email ?? NSNull(), "position": f.position ?? NSNull(),
         "phone": f.phone ?? NSNull(), "greeting_name": f.greetingName ?? NSNull(),
         "linkedin": f.linkedIn ?? NSNull(), "location": f.location ?? NSNull()]
    }

    static func linksJSON(_ l: KeyRing.CompanyLinks) -> [String: Any] {
        ["linkedin": l.linkedIn ?? NSNull(), "x": l.x ?? NSNull(), "facebook": l.facebook ?? NSNull()]
    }

    // MARK: Swift opens what Python sealed

    /// Reads {"key_hex", "seals": [{plaintext_hex, context, sealed}],
    /// "contacts": [{id, vault_id, fields, sealed}], "company_links": [{id, vault_id, links, sealed}],
    /// "vault": {row, private_key, vault_key_hex},
    /// "rejects": [{sealed, context}]} and prints {"ok": Bool, "failures": [...]}.
    static func open() throws {
        let input = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as! [String: Any]
        let key = SymmetricKey(data: data(hex: input["key_hex"] as! String))
        var failures: [String] = []

        for item in input["seals"] as! [[String: Any]] {
            let context = item["context"] as! String
            let opened = try? Sealing.open(item["sealed"] as! String, with: key, context: context)
            if opened.map(hex) != (item["plaintext_hex"] as! String) { failures.append("seal under \(context)") }
        }
        for item in input["contacts"] as! [[String: Any]] {
            let id = item["id"] as! String, vaultID = item["vault_id"] as! String
            let want = item["fields"] as! [String: Any]
            guard let got = try? Sealing.open(KeyRing.ContactFields.self, from: item["sealed"] as! String, with: key,
                                              context: Sealing.contactContext(id: id, vaultID: vaultID)) else {
                failures.append("contact \(id) didn't open"); continue
            }
            if !NSDictionary(dictionary: fieldsJSON(got)).isEqual(to: want) { failures.append("contact \(id) fields differ") }
        }
        for item in input["company_links"] as? [[String: Any]] ?? [] {
            let id = item["id"] as! String, vaultID = item["vault_id"] as! String
            guard let got = try? Sealing.open(KeyRing.CompanyLinks.self, from: item["sealed"] as! String, with: key,
                                              context: Sealing.companyLinksContext(id: id, vaultID: vaultID)) else {
                failures.append("company links \(id) didn't open"); continue
            }
            if !NSDictionary(dictionary: linksJSON(got)).isEqual(to: item["links"] as! [String: Any]) {
                failures.append("company links \(id) differ")
            }
        }
        if let vault = input["vault"] as? [String: Any] {
            let row = vault["row"] as! [String: Any]
            let salt = Data(base64Encoded: row["kdf_salt"] as! String)!
            let unlocking = Sealing.deriveKey(from: vault["private_key"] as! String, salt: salt, rounds: row["kdf_rounds"] as! Int)
            let opened = try? Sealing.unwrap(row["sealed_key"] as! String, with: unlocking,
                                             context: Sealing.vaultKeyContext(vaultID: row["id"] as! String,
                                                                              keyID: row["key_id"] as! String))
            if opened.map(raw).map(hex) != (vault["vault_key_hex"] as! String) { failures.append("vault key didn't unwrap") }
        }
        for item in input["rejects"] as? [[String: Any]] ?? [] {
            if (try? Sealing.open(item["sealed"] as! String, with: key, context: item["context"] as! String)) != nil {
                failures.append("a value that must not open did: \(item["why"] ?? "")")
            }
        }
        let out: [String: Any] = ["ok": failures.isEmpty, "failures": failures]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: out))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
