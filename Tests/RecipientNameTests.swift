import Foundation

// Who a mail greets, end to end: the name field, the address read by
// `NameClassifier`, and the template closing up when there's no one to name.
// Compiles against the app's own files (with stand-ins for the SwiftUI-side
// helpers they lean on):
//
//   swiftc Aurora/Models/RecipientName.swift Aurora/Models/NameClassifier.swift \
//     Aurora/Models/MailTemplate.swift Tests/RecipientNameTests.swift -o /tmp/rn && /tmp/rn
//
// Run from the repository root: it reads Aurora/Resources/NameModel.txt.

// MARK: - Stand-ins for app types these files reference

extension String {
    /// The app's version lives in Theme.swift, which needs SwiftUI.
    var sanitizedLineSeparators: String { self }
}

struct Contact {
    var name = ""
    var email = ""
    var position = ""
    var greeting: String { RecipientName.greeting(name: name, email: email) }
}

struct Profile {
    var name = "Asha", college = "IIT", company = "", position = "student", resumeLink = "r.pdf"
}

// MARK: - Harness

@main
struct RecipientNameTests {
    static var failures = 0

    static func expect(_ got: String, _ want: String, _ label: String, line: Int = #line) {
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
        guard let text = try? String(contentsOfFile: "Aurora/Resources/NameModel.txt", encoding: .utf8),
              let model = NameClassifier(modelText: text) else {
            print("❌ Couldn't load Aurora/Resources/NameModel.txt — run from the repository root.")
            exit(1)
        }
        RecipientName.classifier = model


        print("From the address")
        expect(greet("rahul@acme.com"), "Rahul", "a given name alone")
        expect(greet("nehamathur@acme.com"), "Neha", "given name glued to a surname")
        expect(greet("neha.mathur@acme.com"), "Neha", "given name and surname")
        expect(greet("kumar.rahul@acme.com"), "Rahul", "surname first")
        expect(greet("rahulk@acme.com"), "Rahul", "given name and initial")
        expect(greet("rakeshkumar@acme.com"), "Rakesh", "a compound name goes by its first part")
        expect(greet("hr-neha@acme.com"), "Neha", "a role word beside a name is dropped")
        expect(greet("anjali.kumari87+jobs@acme.com"), "Anjali", "digits and a +tag")
        expect(greet("akushwah@acme.com"), "", "initial and surname: no given name")
        expect(greet("pm.singh@acme.com"), "", "initials and surname")
        expect(greet("sharma@acme.com"), "", "a surname alone")
        expect(greet("singh.gurpreet@acme.com"), "", "an unlisted name isn't misread as the surname")
        expect(greet("suneeta@acme.com"), "Suneeta", "a final vowel isn't an initial")
        expect(greet("careers@acme.com"), "", "a role mailbox")
        expect(greet("design@acme.com"), "", "an English word")
        expect(greet("oracle.india@oracle.com"), "", "the company's own name")
        expect(greet("talk2saravanan@acme.com"), "", "leetspeak")
        expect(greet("zorvexa@acme.com"), "", "a name the model has never seen")

        print("From the name field")
        expect(greet("ak@acme.com", name: "Dr. Anjali Kumari"), "Anjali", "honorific dropped")
        expect(greet("ak@acme.com", name: "KUMARI, Anjali"), "Anjali", "surname-first with a comma")
        expect(greet("akushwah@acme.com", name: "Akushwah"), "", "a name that only copies the mailbox")
        expect(greet("rahul@acme.com", name: "Rahul"), "Rahul", "…unless the address names someone")

        print("Into a template")
        let template = MailText("Hi {Receiver-Name},\nI'm {Sender-Name}.")
        let named = MailContext.make(contact: Contact(name: "", email: "rahul@acme.com"), company: "Acme", profile: Profile())
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
