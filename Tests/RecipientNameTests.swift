import Foundation

// Who a mail greets, end to end: the name field, a signed reply, an address
// that spells a given name out, and the template closing up when there's no
// one to name. Compiles against the app's own files (with stand-ins for the
// SwiftUI-side helpers they lean on):
//
//   swiftc Aurora/Models/RecipientName.swift Aurora/Models/MailTemplate.swift \
//     Tests/RecipientNameTests.swift -o /tmp/rn && /tmp/rn

// MARK: - Stand-ins for app types these files reference

extension String {
    /// The app's version lives in Theme.swift, which needs SwiftUI.
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

// MARK: - Harness

@main
struct RecipientNameTests {
    static var failures = 0

    static func expect<T: Equatable>(_ got: T, _ want: T, _ label: String, line: Int = #line) {
        if got == want {
            print("  ✓ \(label)")
        } else {
            failures += 1
            print("  ❌ \(label): got [\(got)], want [\(want)] (line \(line))")
        }
    }

    static func greet(_ email: String, name: String = "") -> String {
        RecipientName.greeting(name: name, email: email)
    }

    static func main() {
        print("From the address: only a given name spelt out as its own part")
        expect(greet("neha.mathur@acme.com"), "Neha", "given name and surname")
        expect(greet("neha_mathur@acme.com"), "Neha", "underscore")
        expect(greet("neha-mathur@acme.com"), "Neha", "hyphen")
        expect(greet("rahul.k@acme.com"), "Rahul", "given name and initial")
        expect(greet("sai.krishna.reddy@acme.com"), "Sai", "three parts")
        expect(greet("anjali.kumari87+jobs@acme.com"), "Anjali", "digits and a +tag")
        expect(greet("hr.neha.mathur@acme.com"), "Neha", "a role word beside a name is dropped")
        expect(greet("rahul@acme.com"), "", "a lone word: no separation")
        expect(greet("nehamathur@acme.com"), "", "glued: no guess")
        expect(greet("akushwah@acme.com"), "", "glued initial and surname")
        expect(greet("sanhussain@acme.com"), "", "glued, no telling where the name ends")
        expect(greet("rahul123@acme.com"), "", "a word and digits")
        expect(greet("pm.singh@acme.com"), "", "initials first")
        expect(greet("r.saravanan@acme.com"), "", "an initial first")
        expect(greet("hr-neha@acme.com"), "", "a role word and one name")
        expect(greet("jsk.patel@acme.com"), "", "a first part with no vowel is initials")
        expect(greet("careers@acme.com"), "", "a role mailbox")
        expect(greet("oracle.india@oracle.com"), "", "the company's own name")
        expect(greet("talk2saravanan@acme.com"), "", "leetspeak")

        print("From the name field")
        expect(greet("ak@acme.com", name: "Dr. Anjali Kumari"), "Anjali", "honorific dropped")
        expect(greet("ak@acme.com", name: "KUMARI, Anjali"), "Anjali", "surname-first with a comma")
        expect(greet("akushwah@acme.com", name: "Akushwah"), "", "a name that only copies the mailbox")
        expect(greet("neha.mathur@acme.com", name: "Nehamathur"), "Neha", "…the address can still name them")

        expect(greet("arijit.sen@acme.com", name: "Arijit Sen"), "Arijit", "a spaced name matching first.last is real")
        expect(greet("arijitsen@acme.com", name: "Arijit Sen"), "Arijit", "…and matching firstlast")
        expect(greet("akushwah@acme.com", name: "A Kushwah"), "Kushwah", "an initial falls through to the surname, as before")
        expect(greet("nsacharya@acme.com", name: "NS Acharya"), "Acharya", "so do two capital initials")
        expect(greet("pm.singh@acme.com", name: "Pm Singh"), "Singh", "and two in any case")
        expect(greet("ak.sinha@acme.com", name: "Ak Sinha"), "Sinha", "even with a vowel")
        expect(greet("op@acme.com", name: "Om Prakash"), "Om", "a two-letter name is a name")
        expect(greet("op@acme.com", name: "OM PRAKASH"), "Om", "…in capitals too")

        print("From their own reply")
        func signed(_ from: String, _ email: String = "akushwah@acme.com", name: String = "") -> String {
            RecipientName.greeting(name: name, email: email, replyFrom: from)
        }
        expect(signed("Anjali Kushwah <akushwah@acme.com>"), "Anjali", "the name they signed with")
        expect(signed("\"Kushwah, Anjali\" <AKushwah@acme.com>"), "Anjali", "quoted, surname first, any case")
        expect(signed("Acme Recruiting <akushwah@acme.com>"), "", "a role display name")
        expect(signed("akushwah <akushwah@acme.com>"), "", "a display name that repeats the mailbox")
        expect(signed("Anjali Kushwah <anjali@gmail.com>"), "", "a reply from another address")
        expect(signed("Priya Nair <akushwah@acme.com>", name: "Anjali Kushwah"), "Anjali", "the name field still comes first")
        expect(signed("<rahul.verma@acme.com>", "rahul.verma@acme.com"), "Rahul", "no display name: the address decides")
        expect(signed("Arijit Sen <arijit.sen@acme.com>", "arijit.sen@acme.com"), "Arijit", "a signed name matching first.last")

        print("Who needs a Gmail lookup")
        expect(RecipientName.needsLookup(name: "", email: "akushwah@acme.com", greetingName: nil), true, "no name at all")
        expect(RecipientName.needsLookup(name: "", email: "akushwah@acme.com", greetingName: nil,
                                         replyFrom: "Anjali Kushwah <akushwah@acme.com>"), false, "a signed reply is enough")
        expect(RecipientName.needsLookup(name: "Arijit Sen", email: "arijit.sen@acme.com", greetingName: nil), false,
               "a spaced name matching the address is enough")

        print("Where an empty name would read oddly")
        expect(MailText.awkwardWithoutName(in: "Hi {Receiver-Name},\nHello {Receiver-Name}!"), [], "after a greeting word")
        expect(MailText.awkwardWithoutName(in: "Dear {Receiver-Name} ji,"), ["Dear ji,"], "a word after it")
        expect(MailText.awkwardWithoutName(in: "{Receiver-Name}, quick question"), [", quick question"], "starting a line")

        print("Into a template")
        let template = MailText("Hi {Receiver-Name},\nI'm {Sender-Name}.")
        let named = MailContext.make(contact: Contact(name: "", email: "rahul.verma@acme.com"), company: "Acme", profile: Profile())
        let unnamed = MailContext.make(contact: Contact(name: "", email: "akushwah@acme.com"), company: "Acme", profile: Profile())
        expect(template.filled(with: named), "Hi Rahul,\nI'm Asha.", "a name fills in")
        expect(template.filled(with: unnamed), "Hi,\nI'm Asha.", "no name closes up to \"Hi,\"")
        expect(String(template.length(with: unnamed)), String(template.filled(with: unnamed).utf8.count),
               "length agrees with the filled text")

        if failures > 0 {
            print("\n\(failures) failed")
            exit(1)
        }
        print("\nAll passed")
    }
}
