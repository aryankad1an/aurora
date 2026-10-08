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

        // Reasons from status codes
        check(BounceParsing.reason(status: "5.1.1", text: nil) == .addressNotFound, "5.1.1 is no such mailbox")
        check(BounceParsing.reason(status: "5.1.10", text: nil) == .addressNotFound, "Exchange 5.1.10")
        check(BounceParsing.reason(status: "5.1.2", text: nil) == .domainNotFound, "5.1.2 is a bad domain")
        check(BounceParsing.reason(status: "5.4.310", text: nil) == .domainNotFound, "Exchange 5.4.310")
        check(BounceParsing.reason(status: "5.2.2", text: nil) == .mailboxFull, "5.2.2 is a full mailbox")
        check(BounceParsing.reason(status: "5.7.1", text: "user unknown") == .rejected, "the code beats the text")
        check(BounceParsing.reason(status: "5.0.0", text: "No such user here") == .addressNotFound, "a vague code falls back to the text")
        check(BounceParsing.statusCode(in: "550 5.1.1 <a@b.com>: Recipient address rejected") == "5.1.1", "status code from text")
        check(BounceParsing.statusCode(in: "Version 2026.10") == nil, "no status code in plain numbers")

        // Whole notices
        let gmail = gmailFailure.replacingOccurrences(of: "\n", with: "\r\n")
        let parsed = BounceParsing.parseNotice(raw: gmail)
        check(parsed.isNotice, "Gmail DSN is a notice")
        check(parsed.report?.count == 1, "Gmail DSN has one recipient")
        check(parsed.originalMessageID == "CAJx+abc=123@mail.gmail.com", "original Message-ID from the quoted mail")
        let failed = parsed.failures(snippet: nil)
        check(failed == [BounceFailure(address: "jane.doe@acme.com", status: "5.1.1",
                                       diagnostic: "The email account that you tried to reach does not exist. Please try double-checking the recipient's email address for typos.")],
              "Gmail DSN: address, status, and a clean diagnostic")

        let encoded = Data(gmailFailure.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        check(BounceParsing.parseNotice(base64URL: encoded)?.failures(snippet: nil).first?.address == "jane.doe@acme.com",
              "reads Gmail's base64url raw format")

        let delay = BounceParsing.parseNotice(raw: gmailDelay)
        check(delay.isNotice && delay.failures(snippet: nil).isEmpty, "Action: delayed is not a bounce")

        let exchange = BounceParsing.parseNotice(raw: exchangeFailure)
        check(exchange.isNotice, "Exchange NDR is a notice")
        check(exchange.originalMessageID == "abc123@mail.gmail.com", "Message-ID from text/rfc822-headers")
        check(exchange.failures(snippet: nil) == [BounceFailure(address: "bob@corp.example", status: "5.1.10",
                                                                diagnostic: "RESOLVER.ADR.RecipientNotFound; Recipient not found by SMTP address lookup")],
              "Exchange NDR, base64 prose and all")
        check(BounceParsing.reason(status: "5.1.10", text: nil) == .addressNotFound, "Exchange reason")

        let forwarded = BounceParsing.parseNotice(raw: forwardedFailure)
        check(forwarded.failures(snippet: nil).map(\.address) == ["jane@acme.com"], "Original-Recipient wins over Final-Recipient")

        let qmail = BounceParsing.parseNotice(raw: qmailFailure)
        check(qmail.report == nil && qmail.isNotice, "a prose-only notice is still a notice")
        check(qmail.failures(snippet: nil) == [BounceFailure(address: "sam@oldco.example", status: "5.1.1", diagnostic: nil)],
              "prose-only: address and status from the text")

        let person = BounceParsing.parseNotice(raw: personalMail)
        check(!person.isNotice && person.failures(snippet: nil).isEmpty, "a person's mail titled 'Returned mail' isn't a bounce")

        check(BounceParsing.isBounceSender("Microsoft Outlook <MicrosoftExchange329e71ec88ae4615bbc36ab6ce41109e@corp.example>"),
              "Exchange's service account is a bounce sender")

        // "No longer in service": answers from the recipient's side, not the daemon
        let dead: [(String?, String, String)] = [
            (nil, "The email address you are trying to reach is no longer in service.", "no longer in service"),
            ("Automatic reply: Hello", "Thank you for your email. Jane Doe is no longer with Acme. Please contact hr@acme.com.", "no longer with the company"),
            ("Auto: Re: intro", "This mailbox is no longer monitored. For recruiting queries write to careers@acme.com", "mailbox no longer monitored"),
            (nil, "Jane has left the company. Your mail has not been forwarded.", "has left the company"),
            (nil, "I am no longer working at Acme, so I can't help with this, sorry!", "a person saying they've left"),
            (nil, "This email account has been deactivated.", "account deactivated"),
            (nil, "Please note this inbox is not monitored.", "inbox not monitored"),
            (nil, "The email address jane@acme.com is no longer valid.", "address no longer valid"),
            (nil, "This address is no longer in use. Please update your records.", "no longer in use"),
            ("Undeliverable", "Jane\u{2019}s mailbox is no longer active", "curly apostrophe, no longer active"),
            (nil, "Jane is no longer employed by Acme Corp.", "no longer employed"),
        ]
        for (subject, text, name) in dead {
            check(BounceParsing.isDeadAddressNotice(subject: subject, text: text), "dead address: \(name)")
        }
        let alive: [(String?, String, String)] = [
            ("Automatic reply: Out of office", "I'm out of the office until Monday with limited access to email. I will respond when I'm back.", "out of office"),
            ("Out of Office", "I am on annual leave and my email is not monitored. I will be back on 12 October.", "away, and not monitored until back"),
            (nil, "Thanks Maya! Unfortunately the new-grad role is no longer available, but I'll keep you posted.", "a role no longer available isn't a dead address"),
            (nil, "Hi Maya, happy to chat. Are you free on Thursday?", "a real reply"),
            (nil, "Thanks for reaching out — I've passed your resume to the team.", "another real reply"),
            (nil, "", "nothing at all"),
        ]
        for (subject, text, name) in alive {
            check(!BounceParsing.isDeadAddressNotice(subject: subject, text: text), "not a dead address: \(name)")
        }
        check(BounceParsing.reason(in: "The email address you are trying to reach is no longer in service.") == .noLongerThere,
              "no longer in service reads as its own reason")
        check(BounceParsing.reason(in: "550 5.1.1 The email account that you tried to reach does not exist.") == .addressNotFound,
              "a daemon's 'does not exist' is still address not found")
        check(BounceParsing.reason(in: "Per company policy, this mailbox is no longer monitored.") == .noLongerThere,
              "'policy' in a no-longer-monitored answer doesn't make it a rejection")
        check(BounceParsing.reason(in: "552 5.2.2 The recipient's mailbox is full") == .mailboxFull,
              "mailbox full is unchanged")

        // Sender addresses
        check(BounceParsing.senderAddress("Jane Doe <Jane@Acme.com>") == "jane@acme.com", "sender in brackets")
        check(BounceParsing.senderAddress("jane@acme.com") == "jane@acme.com", "bare sender")
        check(BounceParsing.senderAddress("Acme Recruiting") == nil, "no address in the sender")

        // Who a "no longer in service" message is about
        let day: TimeInterval = 24 * 3600
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let mailed = [
            BounceParsing.Mailed(contactID: "jane", address: "jane@acme.com", sentAt: now - day, threadID: "t1"),
            BounceParsing.Mailed(contactID: "bob", address: "bob@acme.com", sentAt: now - 10 * day, threadID: "t2"),
            BounceParsing.Mailed(contactID: "sam", address: "sam@other.example", sentAt: now - day, threadID: "t3"),
            BounceParsing.Mailed(contactID: "late", address: "late@acme.com", sentAt: now + day, threadID: "t4"),
        ]
        check(BounceParsing.matchDeadAddressNotice(sender: "x@elsewhere.example", text: nil, threadID: "t3", at: now, mailed: mailed) == "sam",
              "matched by its thread")
        check(BounceParsing.matchDeadAddressNotice(sender: "Bob <bob@acme.com>", text: "no longer in service", threadID: "zz", at: now, mailed: mailed) == "bob",
              "matched by the dead mailbox answering for itself, outside the thread")
        check(BounceParsing.matchDeadAddressNotice(sender: "it@acme.com", text: "jane@acme.com is no longer monitored", threadID: nil, at: now, mailed: mailed) == "jane",
              "matched by the address it names")
        check(BounceParsing.matchDeadAddressNotice(sender: "noreply@acme.com", text: "This person has left the company.", threadID: nil, at: now, mailed: mailed) == "jane",
              "matched by domain: one person there mailed in the last three days")
        check(BounceParsing.matchDeadAddressNotice(sender: "noreply@acme.com", text: "This person has left the company.", threadID: nil, at: now + 20 * day, mailed: mailed) == nil,
              "by domain, nobody mailed recently: no match")
        check(BounceParsing.matchDeadAddressNotice(sender: "late@acme.com", text: "no longer in service", threadID: nil, at: now, mailed: mailed) == nil,
              "someone mailed after it arrived isn't matched")
        let twoAtAcme = mailed + [BounceParsing.Mailed(contactID: "ann", address: "ann@acme.com", sentAt: now - 2 * day, threadID: "t5")]
        check(BounceParsing.matchDeadAddressNotice(sender: "noreply@acme.com", text: "has left the company", threadID: nil, at: now, mailed: twoAtAcme) == nil,
              "by domain, two people mailed recently: can't tell, no match")

        print("Bounce parsing: \(passed) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}


// MARK: - Sample notices, shaped like the real ones

private let gmailFailure = """
Return-Path: <>
From: Mail Delivery Subsystem <mailer-daemon@googlemail.com>
To: me@gmail.com
Subject: Delivery Status Notification (Failure)
Content-Type: multipart/report; boundary="000000000000abc"; report-type=delivery-status

--000000000000abc
Content-Type: multipart/related; boundary="000000000000def"

--000000000000def
Content-Type: multipart/alternative; boundary="000000000000ghi"

--000000000000ghi
Content-Type: text/plain; charset="UTF-8"

** Address not found **

Your message wasn't delivered to jane.doe@acme.com because the address couldn't be found, or is unable to receive mail.

--000000000000ghi
Content-Type: text/html; charset="UTF-8"

<html><body>Address not found</body></html>
--000000000000ghi--
--000000000000def--
--000000000000abc
Content-Type: message/delivery-status

Reporting-MTA: dns; googlemail.com
Received-From-MTA: dns; me@gmail.com
Arrival-Date: Tue, 29 Sep 2026 10:00:00 -0700 (PDT)

Final-Recipient: rfc822; jane.doe@acme.com
Action: failed
Status: 5.1.1
Remote-MTA: dns; mx.acme.com. (1.2.3.4, the server for the domain acme.com.)
Diagnostic-Code: smtp; 550-5.1.1 The email account that you tried to reach does
 not exist. Please try
 550-5.1.1 double-checking the recipient's email address for typos.
Last-Attempt-Date: Tue, 29 Sep 2026 10:00:01 -0700 (PDT)

--000000000000abc
Content-Type: message/rfc822

From: Me <me@gmail.com>
To: jane.doe@acme.com
Subject: Hello
Message-ID: <CAJx+abc=123@mail.gmail.com>

Hi Jane, …
--000000000000abc--
"""

private let gmailDelay = """
From: Mail Delivery Subsystem <mailer-daemon@googlemail.com>
Subject: Delivery Status Notification (Delay)
Content-Type: multipart/report; boundary="b1"; report-type=delivery-status

--b1
Content-Type: text/plain

Message not delivered. There was a temporary problem delivering your message to jane@acme.com. Gmail will retry for 46 more hours.
--b1
Content-Type: message/delivery-status

Reporting-MTA: dns; googlemail.com

Final-Recipient: rfc822; jane@acme.com
Action: delayed
Status: 4.4.1
--b1--
"""

private let exchangeFailure = """
From: Microsoft Outlook <MicrosoftExchange329e71ec88ae4615bbc36ab6ce41109e@corp.example>
To: <me@gmail.com>
Subject: Undeliverable: Hello
Content-Type: multipart/report; report-type=delivery-status;
\tboundary="_000_NDR_"

--_000_NDR_
Content-Type: text/plain; charset="utf-8"
Content-Transfer-Encoding: base64

\(Data("Delivery has failed to these recipients or groups:\n\nbob@corp.example\nThe email address you entered couldn't be found.".utf8).base64EncodedString())

--_000_NDR_
Content-Type: message/delivery-status

Reporting-MTA: dns;EX01.corp.example

Final-recipient: RFC822; bob@corp.example
Action: failed
Status: 5.1.10
Diagnostic-code: smtp; 550 5.1.10 RESOLVER.ADR.RecipientNotFound; Recipient not found by SMTP address lookup

--_000_NDR_
Content-Type: text/rfc822-headers

From: Me <me@gmail.com>
To: bob@corp.example
Subject: Hello
Message-ID: <abc123@mail.gmail.com>

--_000_NDR_--
"""

private let forwardedFailure = """
From: MAILER-DAEMON@relay.acme.com
Subject: Undelivered Mail Returned to Sender
Content-Type: multipart/report; report-type=delivery-status; boundary="xyz"

--xyz
Content-Type: message/delivery-status

Reporting-MTA: dns; relay.acme.com

Original-Recipient: rfc822;jane@acme.com
Final-Recipient: rfc822;jane.personal@elsewhere.example
Action: failed
Status: 5.1.1
--xyz--
"""

private let qmailFailure = """
From: MAILER-DAEMON@mail.oldco.example
Subject: failure notice

Hi. This is the qmail-send program at mail.oldco.example.
I'm afraid I wasn't able to deliver your message to the following addresses.
This is a permanent error; I've given up. Sorry it didn't work out.

<sam@oldco.example>:
550 5.1.1 Sorry, no mailbox here by that name.
"""

private let personalMail = """
From: Priya <priya@friend.example>
Subject: Returned mail from the trip
Content-Type: text/plain

Returned the mail you left at mine, it's with the front desk.
"""
