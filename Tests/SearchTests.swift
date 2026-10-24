import Foundation

// Search: folding, every word anywhere, and the per-company cache.
//
//   swiftc -parse-as-library -default-isolation MainActor \
//     Aurora/Models/Job.swift Aurora/Models/FresherHiring.swift \
//     Aurora/Models/RecipientName.swift Aurora/Models/Search.swift \
//     Aurora/Models/KeyRing.swift Aurora/Models/Sealing.swift Aurora/Support/Keychain.swift \
//     Tests/SearchTests.swift -o /tmp/search && /tmp/search

// MARK: - Stand-ins for app types these files reference

extension String {
    // The app's versions live in Theme.swift, which needs SwiftUI.
    var sanitizedLineSeparators: String { self }
    var withoutQuoteHeader: String { self }
}

/// The app's looks names up in Gmail; greetings aren't under test here.
final class MailboxNames {
    static let shared = MailboxNames()
    func entry(for email: String) -> String? { nil }
}

@main
struct SearchTests {
    static var failures = 0

    static func expect<T: Equatable>(_ got: T, _ want: T, _ label: String, line: Int = #line) {
        if got == want { print("  ✓ \(label)") } else {
            failures += 1
            print("  ✗ \(label) (line \(line))\n      got:  \(got)\n      want: \(want)")
        }
    }

    static func main() throws {
        // The query
        expect(SearchQuery("   ") == nil, true, "a blank query is no query")
        expect(SearchQuery("  Café   Noir ")?.words, ["cafe", "noir"], "folded and split into words")
        expect(SearchQuery("ＡＢＣ")?.words, ["abc"], "full-width letters fold")

        let q = SearchQuery("jose")!
        expect(q.matches("José Álvarez"), true, "accents don't matter")
        expect(SearchQuery("ab")!.matches("xa", "bx"), false, "a word never spans two fields")
        expect(SearchQuery("stripe priya")!.matches("Priya Nair", "Stripe"), true, "words match across fields")
        expect(SearchQuery("stripe raj")!.matches("Priya Nair", "Stripe"), false, "every word must match")

        // Companies
        let row = #"""
        {"id":"c1","name":"Juniper Cloud","sector":"Infrastructure","domains":["junipercloud.example"],
         "also_known_as":["Juniper"],"recruiters":[]}
        """#
        var juniper = try JSONDecoder().decode(Job.self, from: Data(row.utf8))
        juniper.contacts = [Contact(id: "p1", email: "chloe.martin@junipercloud.example",
                                    name: "Chloé Martin", position: "Engineering Manager")]
        expect(juniper.matches("juniper"), true, "by name")
        expect(juniper.matches("INFRA"), true, "by sector, any case")
        expect(juniper.matches("chloe"), true, "by a contact, accent-free")
        expect(juniper.matches("juniper chloe"), true, "company and person together")
        expect(juniper.matches("juniper ravi"), false, "not when a word is missing")
        expect(juniper.matches(""), false, "an empty query matches nothing")

        // The cache follows edits
        juniper.contacts[0].name = "Ravi Kumar"
        expect(juniper.matches("ravi"), true, "a renamed contact is found by the new name")
        expect(juniper.matches("chloe"), true, "…and the address still holds the old one")
        juniper.contacts[0].email = "ravi@junipercloud.example"
        expect(juniper.matches("chloe"), false, "until the address changes too")

        // matching over sources: each company once, first matching copy wins
        let other = try JSONDecoder().decode(Job.self, from: Data(#"{"id":"c2","name":"Lumen Health","recruiters":[]}"#.utf8))
        expect([Job].matching("juniper", in: [juniper, other], [juniper]).map(\.id), ["c1"], "deduplicated")
        expect([Job].matching(" ", in: [juniper, other]).count, 0, "a blank query lists nothing")

        print(failures == 0 ? "All passed" : "\(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
