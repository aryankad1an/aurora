import Foundation

// The per-company personalised line: filed by company name, written into a mail
// only for people at that company, dropped cleanly where there isn't one, and
// kept on disk per account. Compiles against the app's own files:
//
//   swiftc -parse-as-library -default-isolation MainActor \
//     Aurora/Models/PersonalisedLineStore.swift Aurora/Models/RecipientName.swift \
//     Aurora/Models/MailTemplate.swift Aurora/Support/JSONFile.swift \
//     Tests/PersonalisedLineTests.swift -o /tmp/pl && /tmp/pl

extension String {
    var sanitizedLineSeparators: String { self }
}

struct Contact {
    var id = ""
    var name = ""
    var email = ""
    var position = ""
    var replyFrom: String? = nil
    var greeting: String { RecipientName.greeting(name: name, email: email, replyFrom: replyFrom) }
}

struct Profile {
    var name = "Asha", college = "IIT", company = "", position = "student", resumeLink = "r.pdf"
}

@main
struct PersonalisedLineTests {
    static var failures = 0

    static func expect<T: Equatable>(_ got: T, _ want: T, _ label: String, line: Int = #line) {
        if got == want { print("  ✓ \(label)") } else {
            failures += 1
            print("  ✗ \(label) (line \(line))\n      got:  \(got)\n      want: \(want)")
        }
    }

    static func main() {
        let dir = FileManager.default.temporaryDirectory.appending(path: "pl-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = PersonalisedLineStore()
        store.load(account: "a@x.com", directory: dir)
        store.set("  Loved the Atlas launch.  ", for: "Stripe")
        expect(store.line(for: "stripe "), "Loved the Atlas launch.", "found by name, ignoring case and spaces, trimmed")
        expect(store.line(for: "Square"), "", "another company has none")

        let template = "Hi {Receiver-Name}, I'm interested in {Receiver-Company}. {Company-Personalised} Thanks!"
        let contact = Contact(id: "1", name: "Priya Raghavan", email: "p@stripe.com")
        let with = MailContext.make(contact: contact, company: "Stripe", profile: Profile(),
                                    personalised: store.line(for: "Stripe")).fill(template)
        expect(with, "Hi Priya, I'm interested in Stripe. Loved the Atlas launch. Thanks!", "line lands where the placeholder is")
        let without = MailContext.make(contact: contact, company: "Square", profile: Profile(),
                                       personalised: store.line(for: "Square")).fill(template)
        expect(without, "Hi Priya, I'm interested in Square. Thanks!", "no line: placeholder drops out, no double space")

        // A blank placeholder on a line of its own takes the line with it.
        let own = "Hi {Receiver-Name},\n\nI like your work.\n\n{Company-Personalised}\n\nThanks!"
        let ownFilled = MailContext.make(contact: contact, company: "Square", profile: Profile()).fill(own)
        expect(ownFilled, "Hi Priya,\n\nI like your work.\n\nThanks!", "an empty line's paragraph leaves no double gap")
        let ownWith = MailContext.make(contact: contact, company: "Stripe", profile: Profile(),
                                       personalised: "Loved Atlas.").fill(own)
        expect(ownWith, "Hi Priya,\n\nI like your work.\n\nLoved Atlas.\n\nThanks!", "a filled one keeps its paragraph")
        let tight = MailContext.make(contact: contact, company: "Square", profile: Profile())
            .fill("Hi,\n{Company-Personalised}\nThanks")
        expect(tight, "Hi,\nThanks", "a single-break line is removed cleanly")
        let first = MailContext.make(contact: contact, company: "Square", profile: Profile())
            .fill("{Company-Personalised}\n\nThanks")
        expect(first, "Thanks", "at the start")
        let last = MailContext.make(contact: contact, company: "Square", profile: Profile())
            .fill("Thanks\n\n{Company-Personalised}")
        expect(last, "Thanks", "at the end")
        let inline = MailContext.make(contact: contact, company: "Square", profile: Profile())
            .fill("I like it. {Company-Personalised}\nThanks")
        expect(inline, "I like it.\nThanks", "mid-line, only the leading space goes")

        store.set("Now about Square.", for: "Square")
        store.move(from: "Square", to: "Block")
        expect(store.line(for: "Square"), "", "a rename takes the line off the old name...")
        store.set("Kept.", for: "Acme")
        store.set("Other.", for: "Acme Inc")
        store.move(from: "Acme", to: "Acme Inc")
        expect(store.line(for: "Acme Inc"), "Other.", "...and never overwrites a line the new name already has")
        store.set("", for: "Stripe")
        expect(store.line(for: "Stripe"), "", "an empty line removes it")

        let again = PersonalisedLineStore()
        again.load(account: "a@x.com", directory: dir)
        expect(again.line(for: "Block"), "Now about Square.", "the moved line reloads from disk")
        let other = PersonalisedLineStore()
        other.load(account: "b@x.com", directory: dir)
        expect(other.line(for: "Block"), "", "another account sees nothing")

        print(failures == 0 ? "all passed" : "\(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
