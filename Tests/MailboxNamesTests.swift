import Foundation

// Finding what an address is called in the account's own mail, against a fake
// Gmail. Compiles against the app's own files, with stand-ins for the helpers
// they lean on:
//
//   swiftc Aurora/Models/MailboxNames.swift Aurora/Models/RecipientName.swift \
//     Tests/MailboxNamesTests.swift -o /tmp/mn && /tmp/mn

// MARK: - Stand-ins

extension String {
    var sanitizedLineSeparators: String { self }
}

struct Contact {
    var id = "", name = "", email = ""
    var replyFrom: String? = nil
}

enum GmailAuthError: Error {
    case notConnected
    var endsRun: Bool { true }
}

enum ReplySync {
    static func isSearchable(_ email: String) -> Bool { email.contains("@") && !email.contains(" ") }
    static func isSafePathComponent(_ id: String) -> Bool { !id.isEmpty && id.allSatisfy(\.isHexDigit) }
}

struct JSONFile<Value: Codable> {
    let name: String
    func load() -> Value? { nil }
    func save(_ value: Value) {}
}

// MARK: - A fake Gmail

/// Searches and messages by id; counts the requests made.
final class FakeGmail {
    var searches: [String: [String]] = [:]
    var headers: [String: [(String, String)]] = [:]
    var requests = 0

    func get(_ path: String, _ query: [URLQueryItem]) throws -> Data {
        requests += 1
        if path == "messages" {
            let q = query.first { $0.name == "q" }?.value ?? ""
            let ids = searches[q] ?? []
            return try JSONSerialization.data(withJSONObject: ["messages": ids.map { ["id": $0] }])
        }
        let id = String(path.dropFirst("messages/".count))
        let list = (headers[id] ?? []).map { ["name": $0.0, "value": $0.1] }
        return try JSONSerialization.data(withJSONObject: ["payload": ["headers": list]])
    }
}

@main
struct MailboxNamesTests {
    static var failures = 0

    static func expect<T: Equatable>(_ got: T, _ want: T, _ label: String, line: Int = #line) {
        if got == want {
            print("  ✓ \(label)")
        } else {
            failures += 1
            print("  ❌ \(label): got [\(got)], want [\(want)] (line \(line))")
        }
    }

    static func main() async {
        print("Header parsing")
        expect(MailboxNames.entries(in: "\"Kadian, Aryan\" <kdaryan@acme.com>, b@y.com"),
               ["\"Kadian, Aryan\" <kdaryan@acme.com>", "b@y.com"], "commas in quotes don't split")
        expect(MailboxNames.address(of: "Aryan Kadian <KDAryan@acme.com>"), "KDAryan@acme.com", "angle brackets")
        expect(MailboxNames.address(of: "b@y.com"), "b@y.com", "a bare address")

        print("Looking up")
        let gmail = FakeGmail()
        gmail.searches = [
            "from:kdaryan@acme.com": ["a1"],
            "from:careers@acme.com": ["b1"],
            "{to:pmsingh@acme.com cc:pmsingh@acme.com}": ["c1", "c2"],
        ]
        gmail.headers = [
            "a1": [("From", "Aryan Kadian <kdaryan@acme.com>"), ("To", "me@gmail.com")],
            "b1": [("From", "Acme Recruiting <careers@acme.com>")],
            "c1": [("To", "pmsingh@acme.com")],
            "c2": [("To", "Ravi Rao <ravi@acme.com>, \"Singh, Pooja\" <PMSingh@acme.com>"), ("Cc", "x@y.com")],
        ]
        let names = MailboxNames()
        names.reader = { path, query in try gmail.get(path, query) }
        let found = await names.lookUp(["KDAryan@acme.com", "careers@acme.com", "pmsingh@acme.com", "nobody@acme.com"],
                                       accepting: RecipientName.isPersonEntry)
        expect(found, 2, "two of four have a name in the mail")
        expect(names.entry(for: "kdaryan@acme.com") ?? "", "Aryan Kadian <kdaryan@acme.com>", "from their own mail")
        expect(names.entry(for: "pmsingh@acme.com") ?? "", "\"Singh, Pooja\" <PMSingh@acme.com>", "from mail copying them")
        expect(names.entry(for: "careers@acme.com") ?? "", "", "a role sender names no one")

        func greet(_ email: String) -> String {
            RecipientName.greeting(name: "", email: email, mailboxEntry: names.entry(for: email))
        }
        expect(greet("kdaryan@acme.com"), "Aryan", "kdaryan@ is greeted Aryan")
        expect(greet("pmsingh@acme.com"), "Pooja", "pmsingh@ is greeted Pooja")
        expect(RecipientName.greeting(name: "Rahul Verma", email: "kdaryan@acme.com",
                                      mailboxEntry: names.entry(for: "kdaryan@acme.com")), "Rahul",
               "the row's own name still comes first")

        print("Once per address")
        let before = gmail.requests
        _ = await names.lookUp(["kdaryan@acme.com", "nobody@acme.com"], accepting: RecipientName.isPersonEntry)
        expect(gmail.requests, before, "found and missed addresses aren't looked up again")

        print("Switching accounts mid-lookup")
        let other = FakeGmail()
        other.searches = ["from:anjali@acme.com": ["d1"]]
        other.headers = ["d1": [("From", "Anjali Kushwah <anjali@acme.com>")]]
        let switching = MailboxNames()
        switching.reader = { path, query in
            // Another account signs in while this account's lookup is out.
            if path == "messages" { switching.load(account: "someone-else") }
            return try other.get(path, query)
        }
        let kept = await switching.lookUp(["anjali@acme.com"], accepting: RecipientName.isPersonEntry)
        expect(kept, 0, "a lookup outlived by an account switch keeps nothing")
        expect(switching.entry(for: "anjali@acme.com") ?? "", "", "…and the new account doesn't get its names")

        print("Who needs a lookup")
        expect(RecipientName.needsLookup(name: "", email: "kdaryan@acme.com", greetingName: nil), true, "no name")
        expect(RecipientName.needsLookup(name: "Kdaryan", email: "kdaryan@acme.com", greetingName: nil), true, "mailbox copied")
        expect(RecipientName.needsLookup(name: "", email: "kdaryan@acme.com", greetingName: nil,
                                         replyFrom: "Aryan Kadian <kdaryan@acme.com>"), false, "a signed reply")
        expect(RecipientName.needsLookup(name: "Aryan Kadian", email: "kdaryan@acme.com", greetingName: nil), false, "a real name")
        expect(RecipientName.needsLookup(name: "", email: "kdaryan@acme.com", greetingName: "Aryan"), false, "a greeting set")

        if failures > 0 {
            print("\n\(failures) failed")
            exit(1)
        }
        print("\nAll passed")
    }
}
