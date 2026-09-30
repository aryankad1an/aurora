import Foundation

// Tests for reading delivery-failure notices. Unlike the other files here, this
// one runs against the app's own code rather than a copy of it:
//
//     swiftc Aurora/Models/BounceParsing.swift Tests/BounceParsingTests.swift -o /tmp/bt && /tmp/bt

@main
struct BounceParsingTests {
    static var failures = 0
    static var passed = 0

    static func check(_ condition: Bool, _ name: String) {
        if condition { passed += 1 } else { failures += 1; print("  ✗ \(name)") }
    }

    static func main() {
        // Senders
        check(BounceParsing.isBounceSender("Mail Delivery Subsystem <mailer-daemon@googlemail.com>"), "Gmail daemon is a bounce sender")
        check(BounceParsing.isBounceSender("postmaster@outbound.acme.net"), "postmaster is a bounce sender")
        check(BounceParsing.isBounceSender("MAILER-DAEMON@relay.corp.com"), "case-insensitive")
        check(!BounceParsing.isBounceSender("Jane Doe <jane@acme.com>"), "a person isn't a bounce sender")
        check(!BounceParsing.isBounceSender(nil), "no sender isn't a bounce sender")

        // Delays are not bounces
        check(BounceParsing.isDelay(subject: "Delivery Status Notification (Delay)", snippet: nil), "Gmail delay subject")
        check(BounceParsing.isDelay(subject: "Delivery Status Notification",
                                    snippet: "Message not delivered There was a temporary problem delivering your message to jane@acme.com. Gmail will retry for 46 more hours."),
              "Gmail delay text")
        check(!BounceParsing.isDelay(subject: "Delivery Status Notification (Failure)",
                                     snippet: "Address not found Your message wasn't delivered to jane@acme.com because the address couldn't be found."),
              "a failure isn't a delay")

        // Addresses
        check(BounceParsing.failedAddresses(header: "jane@acme.com", snippet: nil) == ["jane@acme.com"], "header, one address")
        check(BounceParsing.failedAddresses(header: "Jane@Acme.com, <bob@acme.com>", snippet: nil) == ["jane@acme.com", "bob@acme.com"],
              "header, two addresses, lowercased and unbracketed")
        check(BounceParsing.failedAddresses(header: nil,
                                            snippet: "Address not found Your message wasn't delivered to Jane.Doe@acme.com because the address couldn't be found.") == ["jane.doe@acme.com"],
              "address from the text")
        check(BounceParsing.failedAddresses(header: "", snippet: "Undeliverable to x@y.io — reply to mailer-daemon@googlemail.com") == ["x@y.io"],
              "the daemon's own address is left out")
        check(BounceParsing.failedAddresses(header: nil, snippet: "Your message could not be delivered.").isEmpty, "no address, nothing found")

        // Reasons
        check(BounceParsing.reason(in: "Address not found Your message wasn't delivered to a@acme.com because the address couldn't be found, or is unable to receive mail.") == .addressNotFound,
              "address not found")
        check(BounceParsing.reason(in: "Address not found Your message wasn't delivered to a@acmee.com because the domain acmee.com couldn't be found. Check for typos.") == .domainNotFound,
              "a dead domain, despite the 'Address not found' heading")
        check(BounceParsing.reason(in: "DNS Error: Domain name not found") == .domainNotFound, "DNS error")
        check(BounceParsing.reason(in: "550 5.1.1 The email account that you tried to reach does not exist.") == .addressNotFound, "5.1.1")
        check(BounceParsing.reason(in: "552 5.2.2 The recipient's mailbox is full") == .mailboxFull, "mailbox full")
        check(BounceParsing.reason(in: "550 5.7.1 Message rejected due to local policy") == .rejected, "policy rejection")
        check(BounceParsing.reason(in: "Something went wrong.") == .other, "anything else")
        check(BounceParsing.reason(in: nil) == .other, "no text")

        print("Bounce parsing: \(passed) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
