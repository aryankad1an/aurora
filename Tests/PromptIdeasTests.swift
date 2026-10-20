import Foundation

// The writing-help sheet's setup: the prompt ideas it offers for a template, a
// mail and a company line.
//
//   swiftc -parse-as-library Aurora/Models/PromptIdeas.swift Aurora/Models/RecipientName.swift \
//     Aurora/Models/MailTemplate.swift Tests/PromptIdeasTests.swift -o /tmp/pi && /tmp/pi

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
    var name = "Asha"
    var isStudying = true
    var college = "IIT Delhi"
    var isWorking = false
    var company = ""
    var position = ""
    var resumeLink = "r.pdf"
}

@main
struct PromptIdeasTests {
    static var failures = 0

    static func expect<T: Equatable>(_ got: T, _ want: T, _ label: String, line: Int = #line) {
        if got == want { print("  ✓ \(label)") } else {
            failures += 1
            print("  ✗ \(label) (line \(line))\n      got:  \(got)\n      want: \(want)")
        }
    }

    static func main() {
        let student = Profile()

        // A template is offered the placeholders it doesn't have yet.
        let bare = PromptIdeas.ideas(for: .template, text: "Hello, I'd like to apply.", profile: student)
        expect(bare.first, "Add {Company-Personalised} on its own line after the introduction", "template without the company line is offered it first")
        expect(bare.contains { $0.contains("{Receiver-Name}") }, true, "template without a greeting is offered one")
        expect(bare.count, 4, "at most four ideas")
        let full = PromptIdeas.ideas(for: .template,
                                     text: "Hi {Receiver-Name},\n{Company-Personalised}\nI study at {Sender-College}. {Resume-Link}",
                                     profile: student)
        expect(full.contains { $0.contains("{Company-Personalised}") || $0.contains("{Receiver-Name}") || $0.contains("{Resume-Link}") },
               false, "placeholders already there aren't suggested again")

        // A mail names its company and the sender's college, unless it already says it.
        let mail = PromptIdeas.ideas(for: .mail(company: "Stripe"), text: "Hi Priya, ...", profile: student)
        expect(mail.first, "Add a sentence on why I want to work at Stripe", "mail ideas name the company")
        expect(mail.contains("Mention that I study at IIT Delhi"), true, "mail ideas use the college")
        let saysCollege = PromptIdeas.ideas(for: .mail(company: nil), text: "I'm at IIT Delhi.", profile: student)
        expect(saysCollege.contains { $0.contains("IIT Delhi") }, false, "college the mail already mentions isn't suggested")

        // A company line with nothing written: notes on what it should say.
        let draft = PromptIdeas.ideas(for: .line(company: "Stripe", sector: "Fintech"), text: "", profile: student)
        expect(draft.first, "I admire Stripe's work in fintech and want to contribute to it", "draft idea uses the sector")
        expect(draft.contains("What I'm learning at IIT Delhi lines up with what Stripe does"), true, "draft idea uses the college")
        var worker = Profile()
        worker.isWorking = true
        worker.company = "Zomato"
        worker.position = "Android intern"
        let workDraft = PromptIdeas.ideas(for: .line(company: "Stripe", sector: nil), text: "", profile: worker)
        expect(workDraft.first, "I admire what Stripe is building and want to contribute to it", "no sector: a general admiration line")
        expect(workDraft.contains("My work as Android intern at Zomato is close to what Stripe does"), true, "a job comes before college")

        // With a line written: instructions about it.
        let edit = PromptIdeas.ideas(for: .line(company: "Stripe", sector: " "), text: "Loved Atlas.", profile: student)
        expect(edit.first, "Make it more specific to Stripe", "editing a line")
        expect(edit.contains { $0.hasPrefix("Tie it to") }, false, "a blank sector isn't offered")

        print(failures == 0 ? "All passed" : "\(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
