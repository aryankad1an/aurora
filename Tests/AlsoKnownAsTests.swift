import Foundation

// A company's other names: decoded, cleaned on save, matched by search.
//
//   swiftc -parse-as-library -default-isolation MainActor \
//     Aurora/Models/Job.swift Aurora/Models/FresherHiring.swift \
//     Aurora/Models/RecipientName.swift \
//     Tests/AlsoKnownAsTests.swift -o /tmp/aka && /tmp/aka

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
struct AlsoKnownAsTests {
    static var failures = 0

    static func expect<T: Equatable>(_ got: T, _ want: T, _ label: String, line: Int = #line) {
        if got == want { print("  ✓ \(label)") } else {
            failures += 1
            print("  ✗ \(label) (line \(line))\n      got:  \(got)\n      want: \(want)")
        }
    }

    static func main() throws {
        let row = #"{"id":"e1","name":"Eternal","also_known_as":["Zomato","Blinkit","District"],"recruiters":[]}"#
        let eternal = try JSONDecoder().decode(Job.self, from: Data(row.utf8))
        expect(eternal.alsoKnownAs, ["Zomato", "Blinkit", "District"], "decodes other names")
        expect(eternal.matches("blinkit"), true, "an other name finds the company")
        expect(eternal.matches("blink"), true, "part of an other name finds it")
        expect(eternal.otherName(matching: "blink"), "Blinkit", "says which name it matched")
        expect(eternal.otherName(matching: "Eter"), nil, "no other name when its own name matched")
        expect(eternal.matches("swiggy"), false, "an unrelated name doesn't")

        let old = #"{"id":"o1","name":"Onity","recruiters":[]}"#
        expect(try JSONDecoder().decode(Job.self, from: Data(old.utf8)).alsoKnownAs, [],
               "a row from before the migration has none")

        var d = eternal.details
        d.alsoKnownAs = [" Zomato ", "zomato", "", "Eternal", "Hyperpure"]
        expect(d.trimmed.alsoKnownAs, ["Zomato", "Hyperpure"],
               "trimmed: spaces, duplicates, blanks and its own name go")

        var edited = eternal
        edited.apply(d.trimmed)
        expect(edited.alsoKnownAs, ["Zomato", "Hyperpure"], "a save shows at once")

        print(failures == 0 ? "All passed" : "\(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
