import Foundation

// MARK: - Test Framework (Lightweight, runnable on macOS CLI)

struct TestFailure: Error {
    let message: String
    let file: StaticString
    let line: UInt
}

func assertTrue(_ condition: Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) throws {
    if !condition {
        throw TestFailure(message: "Assertion failed: \(message)", file: file, line: line)
    }
}

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: StaticString = #file, line: UInt = #line) throws {
    if a != b {
        throw TestFailure(message: "Assertion failed: [\(a)] != [\(b)]. \(message)", file: file, line: line)
    }
}

// MARK: - Standalone Model Stubs for Testing

struct TestSentMessage: Decodable {
    let id: String
    let threadID: String
    enum CodingKeys: String, CodingKey {
        case id
        case threadID = "threadId"
    }
}

struct TestMailSend: Identifiable {
    let id: String
    let contactID: String
    let sentAt: Date?
    var gmailMessageID: String?
    var gmailThreadID: String?
    var repliedAt: Date?
    var replyFrom: String?
    var replySnippet: String?

    var hasReplied: Bool { repliedAt != nil }

    func attaching(message: TestSentMessage) -> TestMailSend {
        var copy = self
        copy.gmailMessageID = message.id
        copy.gmailThreadID = message.threadID
        return copy
    }
}

// MARK: - HTML Unescape Implementation (Mirrors Theme.swift)

extension String {
    var htmlUnescaped: String {
        guard contains("&") else { return self }
        let named = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&apos;": "'", "&nbsp;": " ", "&hellip;": "…", "&mdash;": "—",
            "&ndash;": "–", "&rsquo;": "'", "&lsquo;": "'",
            "&ldquo;": "\u{201C}", "&rdquo;": "\u{201D}"
        ]
        var result = self
        for (entity, character) in named {
            result = result.replacingOccurrences(of: entity, with: character, options: .caseInsensitive)
        }
        guard let pattern = try? Regex(#"&#(x?)([0-9A-Fa-f]+);"#) else { return result }
        while let match = result.firstMatch(of: pattern) {
            let prefix = match.output[1].substring ?? ""
            let hexOrDec = match.output[2].substring ?? ""
            let radix = prefix.isEmpty ? 10 : 16
            guard let code = UInt32(hexOrDec, radix: radix),
                  let scalar = Unicode.Scalar(code) else {
                result.replaceSubrange(match.range, with: "")
                continue
            }
            result.replaceSubrange(match.range, with: String(Character(scalar)))
        }
        return result
    }
}

// MARK: - Gmail Thread Parsing Helpers & Engine Under Test

struct GmailThreadMock: Codable {
    let messages: [MessageMock]

    struct MessageMock: Codable {
        let id: String
        let labelIds: [String]?
        let snippet: String?
        let internalDate: String?
        let payload: PayloadMock?

        struct PayloadMock: Codable {
            let headers: [HeaderMock]?
            struct HeaderMock: Codable {
                let name: String
                let value: String
            }
        }

        // Mirrors `ReplySync.gmailDate`: "NaN" and "inf" parse as Doubles, and
        // a NaN date would slip past every comparison.
        var date: Date {
            guard let ms = internalDate.flatMap(Double.init), ms.isFinite, ms > 0 else { return .distantPast }
            return Date(timeIntervalSince1970: ms / 1000)
        }

        var isOurs: Bool {
            let labels = labelIds ?? []
            return labels.contains("SENT") || labels.contains("DRAFT")
        }

        var from: String? {
            header("From")
        }

        var isAutomated: Bool {
            if let auto = header("Auto-Submitted")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), auto != "no" {
                return true
            }
            if let precedence = header("Precedence")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               ["bulk", "auto_reply", "junk", "list"].contains(precedence) {
                return true
            }
            let sender = from ?? ""
            return sender.localizedCaseInsensitiveContains("no-reply")
                || sender.localizedCaseInsensitiveContains("noreply")
                || sender.localizedCaseInsensitiveContains("do-not-reply")
                || sender.localizedCaseInsensitiveContains("donotreply")
        }

        var isBounce: Bool {
            let sender = (from ?? "").lowercased()
            return sender.contains("mailer-daemon") || sender.contains("postmaster")
        }

        /// Copy of `BounceParsing.isDeadAddressNotice`: an answer from their
        /// side saying the address is no longer in service.
        var isDeadAddressNotice: Bool {
            let body = [header("Subject"), snippet].compactMap { $0 }.joined(separator: " ")
                .replacingOccurrences(of: "\u{2019}", with: "'").lowercased()
            guard !body.isEmpty else { return false }
            func has(_ phrases: [String]) -> Bool { phrases.contains { body.contains($0) } }
            let dead = ["no longer in service", "no longer in use", "no longer active", "no longer monitored",
                        "no longer being monitored", "no longer checked", "no longer with ", "no longer works",
                        "no longer working", "no longer employed", "no longer part of", "no longer associated",
                        "no longer at ", "has left the", "have left the", "left the company", "left the organization",
                        "left the organisation", "left the firm", "decommissioned", "deactivated"]
            let inactive = ["not monitored", "not being monitored", "is inactive", "has been disabled", "is disabled",
                            "has been closed", "is closed"]
            let away = ["out of office", "out of the office", "on leave", "on vacation", "on holiday", "annual leave",
                        "parental leave", "maternity leave", "paternity leave", "will return", "will be back",
                        "i'll be back", "back on", "back in the office", "away until", "away from", "limited access",
                        "returning on", "currently travelling", "currently traveling"]
            let addressPhrases = ["no longer valid", "no longer exists", "no longer available", "no longer accessible", "not in use"]
            let addressWords = ["address", "mailbox", "email", "e-mail", "inbox", "account"]
            if has(dead) { return true }
            if has(away) { return false }
            if has(inactive) { return true }
            return has(addressPhrases) && has(addressWords)
        }

        private func header(_ name: String) -> String? {
            payload?.headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }
}

enum ParsedThreadResponse: Equatable {
    case reply(at: Date, from: String, snippet: String?)
    case bounce
    case silent
}

func parseThread(data: Data, after sentAt: Date?) throws -> ParsedThreadResponse {
    let thread = try JSONDecoder().decode(GmailThreadMock.self, from: data)

    // Fast-path: 1 or 0 messages from us
    if thread.messages.count <= 1 && (thread.messages.first?.isOurs ?? false) {
        return .silent
    }

    var sawBounce = false
    for message in thread.messages.sorted(by: { $0.date < $1.date }) {
        guard !message.isOurs else { continue }
        if let sentAt, message.date <= sentAt { continue }
        if message.isBounce { sawBounce = true; continue }
        // "No longer in service" from their side reads like a reply; it's a bounce.
        if message.isDeadAddressNotice { sawBounce = true; continue }
        if message.isAutomated { continue }
        guard let from = message.from, !from.isEmpty else { continue }
        return .reply(at: message.date,
                      from: from,
                      snippet: message.snippet?.htmlUnescaped)
    }
    return sawBounce ? .bounce : .silent
}

func isSafePathComponent(_ id: String) -> Bool {
    !id.isEmpty && id.count <= 64 && id.allSatisfy(\.isHexDigit)
}

func isSearchableEmail(_ email: String) -> Bool {
    guard !email.isEmpty,
          let atIndex = email.firstIndex(of: "@"),
          atIndex != email.startIndex,
          email.index(after: atIndex) != email.endIndex else {
        return false
    }
    return email.allSatisfy { !$0.isWhitespace && $0 != "\"" && $0 != "(" && $0 != ")" }
}

// MARK: - Token Cache Simulation

actor TokenCache {
    private var cachedToken: String?
    private var expiresAt: Date = .distantPast
    private var refreshTask: Task<String, Error>?
    private(set) var refreshCallCount = 0

    func getToken(now: Date = Date(), refreshHandler: @Sendable @escaping () async throws -> (token: String, expiresIn: Int)) async throws -> String {
        if let token = cachedToken, now.addingTimeInterval(60) < expiresAt {
            return token
        }
        if let ongoing = refreshTask {
            return try await ongoing.value
        }
        let task = Task { [self] () -> String in
            defer { self.clearTask() }
            let (newToken, expiresIn) = try await refreshHandler()
            self.store(token: newToken, expiresIn: expiresIn, now: now)
            return newToken
        }
        self.refreshCallCount += 1
        self.refreshTask = task
        return try await task.value
    }

    private func clearTask() {
        refreshTask = nil
    }

    private func store(token: String, expiresIn: Int, now: Date) {
        self.cachedToken = token
        self.expiresAt = now.addingTimeInterval(TimeInterval(expiresIn))
    }

    func clear() {
        cachedToken = nil
        expiresAt = .distantPast
        refreshTask = nil
    }
}

// MARK: - Test Suite Definition

class ReplySyncTestSuite {
    var passed = 0
    var failed = 0

    func runTest(_ name: String, block: () async throws -> Void) async {
        do {
            try await block()
            passed += 1
            print("  ✓ \(name)")
        } catch let err as TestFailure {
            failed += 1
            print("  ✗ \(name) [\(err.file):\(err.line)]: \(err.message)")
        } catch {
            failed += 1
            print("  ✗ \(name): Unexpected error: \(error)")
        }
    }

    func runAll() async {
        print("\n==========================================")
        print("Running Comprehensive ReplySync Test Suite")
        print("==========================================\n")

        await testPathAndEmailValidation()
        await testHTMLUnescapeEdgeCases()
        await testThreadParsingEdgeCases()
        await testAdvancedHeaderAndPayloadEdgeCases()
        await testComplexSequenceScenarios()
        await testTokenCachingAndVaultStress()
        await testDeltaSyncLogic()
        await testConcurrencySafety()
        await testRandomizedFuzzing()

        print("\n==========================================")
        print("Results: \(passed) passed, \(failed) failed")
        print("==========================================\n")
        if failed > 0 {
            exit(1)
        }
    }

    // MARK: - 1. Path & Email Validation Tests

    func testPathAndEmailValidation() async {
        print("• Path & Email Validation:")

        await runTest("Valid hex thread IDs accepted") {
            try assertTrue(isSafePathComponent("18d85fbc294a6e01"))
            try assertTrue(isSafePathComponent("abcdef0123456789"))
            try assertTrue(isSafePathComponent("1A2B3C4D"))
            try assertTrue(isSafePathComponent("0"))
            try assertTrue(isSafePathComponent(String(repeating: "f", count: 64)))
        }

        await runTest("Path traversal attacks and invalid characters rejected") {
            try assertTrue(!isSafePathComponent("../../../etc/passwd"))
            try assertTrue(!isSafePathComponent("18d85fbc?param=val"))
            try assertTrue(!isSafePathComponent("thread/id"))
            try assertTrue(!isSafePathComponent("18d8 5fbc"))
            try assertTrue(!isSafePathComponent(""))
            try assertTrue(!isSafePathComponent("   "))
            try assertTrue(!isSafePathComponent("18d85fbc\0"))
            try assertTrue(!isSafePathComponent("18d85fbc\n"))
            try assertTrue(!isSafePathComponent("18d85fbc#hash"))
            try assertTrue(!isSafePathComponent(String(repeating: "a", count: 65)))
        }

        await runTest("Email searchability validation") {
            try assertTrue(isSearchableEmail("alice@example.com"))
            try assertTrue(isSearchableEmail("contact.talent+eng@bigco.co.uk"))
            try assertTrue(isSearchableEmail("john_doe-123@sub.domain.org"))
            try assertTrue(!isSearchableEmail("bad email@domain.com"))
            try assertTrue(!isSearchableEmail(" contact@domain.com"))
            try assertTrue(!isSearchableEmail("contact@domain.com "))
            try assertTrue(!isSearchableEmail("\"name\"@domain.com"))
            try assertTrue(!isSearchableEmail("name(comment)@domain.com"))
            try assertTrue(!isSearchableEmail("no-at-sign.com"))
            try assertTrue(!isSearchableEmail("@nodomain"))
            try assertTrue(!isSearchableEmail(""))
        }
    }

    // MARK: - 2. HTML Unescape Edge Cases

    func testHTMLUnescapeEdgeCases() async {
        print("• HTML Snippet Unescaping:")

        await runTest("Common entities in reply snippets") {
            let raw = "Thanks &amp; regards, I&#39;d love to connect &quot;soon&quot;&hellip;"
            let expected = "Thanks & regards, I'd love to connect \"soon\"…"
            try assertEqual(raw.htmlUnescaped, expected)
        }

        await runTest("Hex numeric entities") {
            let raw = "Let&#x27;s talk &#x201C;excited&#x201D; &mdash; ok?"
            let expected = "Let's talk \u{201C}excited\u{201D} — ok?"
            try assertEqual(raw.htmlUnescaped, expected)
        }

        await runTest("Decimal and hex uppercase/lowercase entities") {
            let raw = "&#60;b&#62;Hello&#x3C;/b&#x3E; &#x1F600;"
            let expected = "<b>Hello</b> 😀"
            try assertEqual(raw.htmlUnescaped, expected)
        }

        await runTest("Malformed / unescaped entities do not crash or loop") {
            let malformed = "Just an & and a half-formed &# and invalid &#xZZZ; &#; &#x; entity."
            let res = malformed.htmlUnescaped
            try assertTrue(res.contains("&"))
        }

        await runTest("Out-of-range scalars and surrogate entities handled safely") {
            // 0x110000 is beyond Unicode limit, 0xD800 is a surrogate code point
            let input = "Valid &#x21; Bad &#x110000; Surrogate &#xD800; Done"
            let res = input.htmlUnescaped
            try assertTrue(res.contains("!"))
            try assertTrue(res.contains("Done"))
        }

        await runTest("Large string with dozens of entities decodes cleanly") {
            let repeated = String(repeating: "&amp; &quot; &#39; &#x2014; ", count: 50)
            let decoded = repeated.htmlUnescaped
            try assertTrue(decoded.contains("& \" ' —"))
            try assertTrue(!decoded.contains("&amp;"))
        }
    }

    // MARK: - 3. Thread Parsing Edge Cases

    func testThreadParsingEdgeCases() async {
        print("• Basic Thread Parsing Logic & Filters:")

        let sendDate = Date(timeIntervalSince1970: 1000)

        await runTest("Fast-path: Thread with only 1 message from us is silent") {
            let mock = GmailThreadMock(messages: [
                .init(id: "m1", labelIds: ["SENT"], snippet: "Original send", internalDate: "1000000",
                      payload: .init(headers: [.init(name: "From", value: "me@gmail.com")]))
            ])
            let data = try JSONEncoder().encode(mock)
            let result = try parseThread(data: data, after: sendDate)
            try assertEqual(result, .silent)
        }

        await runTest("Empty messages thread is silent") {
            let mock = GmailThreadMock(messages: [])
            let data = try JSONEncoder().encode(mock)
            let result = try parseThread(data: data, after: sendDate)
            try assertEqual(result, .silent)
        }

        await runTest("Self-sent emails or drafts are ignored") {
            let mock = GmailThreadMock(messages: [
                .init(id: "m1", labelIds: ["SENT"], snippet: "Original send", internalDate: "1000000",
                      payload: .init(headers: [.init(name: "From", value: "me@gmail.com")])),
                .init(id: "m2", labelIds: ["SENT"], snippet: "My follow-up", internalDate: "2000000",
                      payload: .init(headers: [.init(name: "From", value: "me@gmail.com")])),
                .init(id: "m3", labelIds: ["DRAFT"], snippet: "Draft reply", internalDate: "3000000",
                      payload: .init(headers: [.init(name: "From", value: "me@gmail.com")]))
            ])
            let data = try JSONEncoder().encode(mock)
            let result = try parseThread(data: data, after: sendDate)
            try assertEqual(result, .silent)
        }

        await runTest("Out of office / auto-submitted is ignored") {
            let mock = GmailThreadMock(messages: [
                .init(id: "m1", labelIds: ["SENT"], snippet: "Original send", internalDate: "1000000",
                      payload: .init(headers: [.init(name: "From", value: "me@gmail.com")])),
                .init(id: "m2", labelIds: ["INBOX"], snippet: "I am out of office until Monday", internalDate: "1050000",
                      payload: .init(headers: [
                        .init(name: "From", value: "contact@corp.com"),
                        .init(name: "Auto-Submitted", value: "auto-replied")
                      ]))
            ])
            let data = try JSONEncoder().encode(mock)
            let result = try parseThread(data: data, after: sendDate)
            try assertEqual(result, .silent)
        }

        await runTest("Precedence bulk / junk / list is ignored") {
            for precedence in ["bulk", "junk", "list", "auto_reply"] {
                let mock = GmailThreadMock(messages: [
                    .init(id: "m1", labelIds: ["INBOX"], snippet: "Automated update", internalDate: "1050000",
                          payload: .init(headers: [
                            .init(name: "From", value: "contact@corp.com"),
                            .init(name: "Precedence", value: precedence)
                          ]))
                ])
                let data = try JSONEncoder().encode(mock)
                let result = try parseThread(data: data, after: sendDate)
                try assertEqual(result, .silent, "Failed for precedence: \(precedence)")
            }
        }

        await runTest("No-reply / do-not-reply addresses are ignored") {
            let senders = [
                "no-reply@greenhouse.io",
                "noreply@lever.co",
                "do-not-reply@workday.com",
                "donotreply@smartcontacts.com"
            ]
            for sender in senders {
                let mock = GmailThreadMock(messages: [
                    .init(id: "m1", labelIds: ["INBOX"], snippet: "Application received", internalDate: "1050000",
                          payload: .init(headers: [
                            .init(name: "From", value: sender)
                          ]))
                ])
                let data = try JSONEncoder().encode(mock)
                let result = try parseThread(data: data, after: sendDate)
                try assertEqual(result, .silent, "Failed for sender: \(sender)")
            }
        }

        await runTest("Delivery failure / bounce returns bounce") {
            let bounceSenders = [
                "Mail Delivery Subsystem <mailer-daemon@googlemail.com>",
                "postmaster@domain.com",
                "MAILER-DAEMON@relay.corp.com",
                "Postmaster <postmaster@outbound.net>"
            ]
            for sender in bounceSenders {
                let mock = GmailThreadMock(messages: [
                    .init(id: "m1", labelIds: ["INBOX"], snippet: "Delivery incomplete", internalDate: "1050000",
                          payload: .init(headers: [
                            .init(name: "From", value: sender)
                          ]))
                ])
                let data = try JSONEncoder().encode(mock)
                let result = try parseThread(data: data, after: sendDate)
                try assertEqual(result, .bounce, "Failed for bounce sender: \(sender)")
            }
        }

        await runTest("Genuine contact reply recognized") {
            let mock = GmailThreadMock(messages: [
                .init(id: "m1", labelIds: ["SENT"], snippet: "Hi, interested in Aurora?", internalDate: "1000000",
                      payload: .init(headers: [.init(name: "From", value: "me@gmail.com")])),
                .init(id: "m2", labelIds: ["INBOX"], snippet: "Hi! Let&#39;s chat tomorrow.", internalDate: "1500000",
                      payload: .init(headers: [.init(name: "From", value: "Contact <sarah@tech.co>")]))
            ])
            let data = try JSONEncoder().encode(mock)
            let result = try parseThread(data: data, after: sendDate)
            if case .reply(let at, let from, let snippet) = result {
                try assertEqual(from, "Contact <sarah@tech.co>")
                try assertEqual(snippet, "Hi! Let's chat tomorrow.")
                try assertEqual(at, Date(timeIntervalSince1970: 1500))
            } else {
                throw TestFailure(message: "Expected .reply, got \(result)", file: #file, line: #line)
            }
        }

        await runTest("Out of order messages resolved chronologically") {
            let mock = GmailThreadMock(messages: [
                .init(id: "m3", labelIds: ["INBOX"], snippet: "Second reply", internalDate: "3000000",
                      payload: .init(headers: [.init(name: "From", value: "colleague@tech.co")])),
                .init(id: "m2", labelIds: ["INBOX"], snippet: "First reply", internalDate: "2000000",
                      payload: .init(headers: [.init(name: "From", value: "sarah@tech.co")]))
            ])
            let data = try JSONEncoder().encode(mock)
            let result = try parseThread(data: data, after: sendDate)
            if case .reply(let at, let from, let snippet) = result {
                try assertEqual(from, "sarah@tech.co")
                try assertEqual(snippet, "First reply")
                try assertEqual(at, Date(timeIntervalSince1970: 2000))
            } else {
                throw TestFailure(message: "Expected first reply chronologically", file: #file, line: #line)
            }
        }

        await runTest("Message with timestamp <= sentAt ignored") {
            let mock = GmailThreadMock(messages: [
                .init(id: "m1", labelIds: ["INBOX"], snippet: "Old thread message", internalDate: "900000",
                      payload: .init(headers: [.init(name: "From", value: "sarah@tech.co")]))
            ])
            let data = try JSONEncoder().encode(mock)
            let result = try parseThread(data: data, after: sendDate)
            try assertEqual(result, .silent)
        }
    }

    // MARK: - 4. Advanced Header & Payload Edge Cases

    func testAdvancedHeaderAndPayloadEdgeCases() async {
        print("• Advanced Header & Payload Edge Cases:")
        let sendDate = Date(timeIntervalSince1970: 1000)

        await runTest("Auto-Submitted: no with whitespace is recognized as human reply") {
            let mock = GmailThreadMock(messages: [
                .init(id: "m1", labelIds: ["INBOX"], snippet: "Human answer", internalDate: "1500000",
                      payload: .init(headers: [
                        .init(name: "Auto-Submitted", value: " no \r\n"),
                        .init(name: "From", value: "contact@corp.com")
                      ]))
            ])
            let data = try JSONEncoder().encode(mock)
            let result = try parseThread(data: data, after: sendDate)
            if case .reply(_, let from, _) = result {
                try assertEqual(from, "contact@corp.com")
            } else {
                throw TestFailure(message: "Expected human reply when Auto-Submitted is 'no'", file: #file, line: #line)
            }
        }

        await runTest("Precedence with whitespace and mixed cases is filtered") {
            let mock = GmailThreadMock(messages: [
                .init(id: "m1", labelIds: ["INBOX"], snippet: "Bulk mail", internalDate: "1500000",
                      payload: .init(headers: [
                        .init(name: "pReCeDeNcE", value: "  BULK \n"),
                        .init(name: "From", value: "newsletter@corp.com")
                      ]))
            ])
            let data = try JSONEncoder().encode(mock)
            let result = try parseThread(data: data, after: sendDate)
            try assertEqual(result, .silent)
        }

        await runTest("Message payload completely missing or headers array nil") {
            let mock = GmailThreadMock(messages: [
                .init(id: "m1", labelIds: ["INBOX"], snippet: "Ghost message", internalDate: "1500000", payload: nil),
                .init(id: "m2", labelIds: ["INBOX"], snippet: "Real message", internalDate: "2000000",
                      payload: .init(headers: [.init(name: "From", value: "real@corp.com")]))
            ])
            let data = try JSONEncoder().encode(mock)
            let result = try parseThread(data: data, after: sendDate)
            if case .reply(_, let from, _) = result {
                try assertEqual(from, "real@corp.com")
            } else {
                throw TestFailure(message: "Expected real message after ghost message", file: #file, line: #line)
            }
        }

        await runTest("Malformed internalDate values do not crash") {
            let malformedDates = ["", "NaN", "nan", "inf", "-inf", "not_a_number", "-999999", "0", "   "]
            for badDate in malformedDates {
                let mock = GmailThreadMock(messages: [
                    .init(id: "m1", labelIds: ["INBOX"], snippet: "Bad date", internalDate: badDate,
                          payload: .init(headers: [.init(name: "From", value: "someone@corp.com")])),
                    .init(id: "m2", labelIds: ["INBOX"], snippet: "Good date", internalDate: "1500000",
                          payload: .init(headers: [.init(name: "From", value: "valid@corp.com")]))
                ])
                let data = try JSONEncoder().encode(mock)
                let result = try parseThread(data: data, after: sendDate)
                if case .reply(_, let from, _) = result {
                    try assertEqual(from, "valid@corp.com")
                } else {
                    throw TestFailure(message: "Failed for badDate: \(badDate)", file: #file, line: #line)
                }
            }
        }

        await runTest("Multiple From headers in message payload picks first") {
            let mock = GmailThreadMock(messages: [
                .init(id: "m1", labelIds: ["INBOX"], snippet: "Multiple from headers", internalDate: "1500000",
                      payload: .init(headers: [
                        .init(name: "From", value: "first@corp.com"),
                        .init(name: "From", value: "second@corp.com")
                      ]))
            ])
            let data = try JSONEncoder().encode(mock)
            let result = try parseThread(data: data, after: sendDate)
            if case .reply(_, let from, _) = result {
                try assertEqual(from, "first@corp.com")
            } else {
                throw TestFailure(message: "Expected reply from first From header", file: #file, line: #line)
            }
        }
    }

    // MARK: - 5. Complex Sequence Scenarios

    func testComplexSequenceScenarios() async {
        print("• Complex Sequence Scenarios:")
        let sendDate = Date(timeIntervalSince1970: 1000)

        await runTest("Send -> OOO -> Bounce -> Genuine Contact Reply -> Reply Wins") {
            let mock = GmailThreadMock(messages: [
                .init(id: "m1", labelIds: ["SENT"], snippet: "Cold email", internalDate: "1000000",
                      payload: .init(headers: [.init(name: "From", value: "me@gmail.com")])),
                .init(id: "m2", labelIds: ["INBOX"], snippet: "I am away on holiday", internalDate: "1100000",
                      payload: .init(headers: [
                        .init(name: "From", value: "sarah@corp.com"),
                        .init(name: "Auto-Submitted", value: "auto-generated")
                      ])),
                .init(id: "m3", labelIds: ["INBOX"], snippet: "Delivery failure to CC alias", internalDate: "1200000",
                      payload: .init(headers: [.init(name: "From", value: "mailer-daemon@corp.com")])),
                .init(id: "m4", labelIds: ["INBOX"], snippet: "Hi Aryan, I'd love to chat!", internalDate: "1300000",
                      payload: .init(headers: [.init(name: "From", value: "sarah@corp.com")]))
            ])
            let data = try JSONEncoder().encode(mock)
            let result = try parseThread(data: data, after: sendDate)
            if case .reply(let at, let from, let snippet) = result {
                try assertEqual(from, "sarah@corp.com")
                try assertEqual(snippet, "Hi Aryan, I'd love to chat!")
                try assertEqual(at, Date(timeIntervalSince1970: 1300))
            } else {
                throw TestFailure(message: "Expected genuine reply to win over OOO and bounce", file: #file, line: #line)
            }
        }

        await runTest("Send -> OOO -> Bounce -> No Reply -> Bounce Wins") {
            let mock = GmailThreadMock(messages: [
                .init(id: "m1", labelIds: ["SENT"], snippet: "Cold email", internalDate: "1000000",
                      payload: .init(headers: [.init(name: "From", value: "me@gmail.com")])),
                .init(id: "m2", labelIds: ["INBOX"], snippet: "Auto reply", internalDate: "1100000",
                      payload: .init(headers: [
                        .init(name: "From", value: "sarah@corp.com"),
                        .init(name: "Auto-Submitted", value: "auto-generated")
                      ])),
                .init(id: "m3", labelIds: ["INBOX"], snippet: "Permanent failure", internalDate: "1200000",
                      payload: .init(headers: [.init(name: "From", value: "mailer-daemon@corp.com")]))
            ])
            let data = try JSONEncoder().encode(mock)
            let result = try parseThread(data: data, after: sendDate)
            try assertEqual(result, .bounce)
        }

        await runTest("Send -> 'no longer in service' auto-answer -> Bounce, not a reply") {
            let mock = GmailThreadMock(messages: [
                .init(id: "m1", labelIds: ["SENT"], snippet: "Cold email", internalDate: "1000000",
                      payload: .init(headers: [.init(name: "From", value: "me@gmail.com")])),
                .init(id: "m2", labelIds: ["INBOX"], snippet: "The email address you are trying to reach is no longer in service.",
                      internalDate: "1100000",
                      payload: .init(headers: [.init(name: "From", value: "jane@corp.com")]))
            ])
            let result = try parseThread(data: try JSONEncoder().encode(mock), after: sendDate)
            try assertEqual(result, .bounce)
        }

        await runTest("Send -> colleague: 'Jane has left the company' -> Bounce") {
            let mock = GmailThreadMock(messages: [
                .init(id: "m1", labelIds: ["SENT"], snippet: "Cold email", internalDate: "1000000",
                      payload: .init(headers: [.init(name: "From", value: "me@gmail.com")])),
                .init(id: "m2", labelIds: ["INBOX"], snippet: "Hi, Jane has left the company and this inbox is closed.",
                      internalDate: "1100000",
                      payload: .init(headers: [.init(name: "From", value: "Front Desk <office@corp.com>")]))
            ])
            let result = try parseThread(data: try JSONEncoder().encode(mock), after: sendDate)
            try assertEqual(result, .bounce)
        }

        await runTest("Send -> 'no longer monitored' -> real reply from a colleague -> Reply wins") {
            let mock = GmailThreadMock(messages: [
                .init(id: "m1", labelIds: ["SENT"], snippet: "Cold email", internalDate: "1000000",
                      payload: .init(headers: [.init(name: "From", value: "me@gmail.com")])),
                .init(id: "m2", labelIds: ["INBOX"], snippet: "This mailbox is no longer monitored.", internalDate: "1100000",
                      payload: .init(headers: [.init(name: "From", value: "jane@corp.com")])),
                .init(id: "m3", labelIds: ["INBOX"], snippet: "Hi Aryan, I took over Jane's roles — happy to chat!", internalDate: "1200000",
                      payload: .init(headers: [.init(name: "From", value: "sam@corp.com")]))
            ])
            let result = try parseThread(data: try JSONEncoder().encode(mock), after: sendDate)
            if case .reply(_, let from, _) = result {
                try assertEqual(from, "sam@corp.com")
            } else {
                throw TestFailure(message: "Expected the colleague's reply", file: #file, line: #line)
            }
        }

        await runTest("Send -> out-of-office saying mail isn't monitored -> Silent, not a bounce") {
            let mock = GmailThreadMock(messages: [
                .init(id: "m1", labelIds: ["SENT"], snippet: "Cold email", internalDate: "1000000",
                      payload: .init(headers: [.init(name: "From", value: "me@gmail.com")])),
                .init(id: "m2", labelIds: ["INBOX"], snippet: "I'm on annual leave; email is not monitored. I will be back on Monday.",
                      internalDate: "1100000",
                      payload: .init(headers: [
                        .init(name: "From", value: "jane@corp.com"),
                        .init(name: "Auto-Submitted", value: "auto-replied")
                      ]))
            ])
            let result = try parseThread(data: try JSONEncoder().encode(mock), after: sendDate)
            try assertEqual(result, .silent)
        }

        await runTest("Send -> Contact Reply -> User Replies Back -> First Reply Remains") {
            let mock = GmailThreadMock(messages: [
                .init(id: "m1", labelIds: ["SENT"], snippet: "Cold email", internalDate: "1000000",
                      payload: .init(headers: [.init(name: "From", value: "me@gmail.com")])),
                .init(id: "m2", labelIds: ["INBOX"], snippet: "Interested, send your resume", internalDate: "1200000",
                      payload: .init(headers: [.init(name: "From", value: "sarah@corp.com")])),
                .init(id: "m3", labelIds: ["SENT"], snippet: "Attached resume, thanks!", internalDate: "1400000",
                      payload: .init(headers: [.init(name: "From", value: "me@gmail.com")]))
            ])
            let data = try JSONEncoder().encode(mock)
            let result = try parseThread(data: data, after: sendDate)
            if case .reply(let at, let from, _) = result {
                try assertEqual(from, "sarah@corp.com")
                try assertEqual(at, Date(timeIntervalSince1970: 1200))
            } else {
                throw TestFailure(message: "Expected contact reply at 1200s", file: #file, line: #line)
            }
        }
    }

    // MARK: - 6. Token Caching & Vault Stress Tests

    func testTokenCachingAndVaultStress() async {
        print("• OAuth Token Caching & Fault Stress:")

        let cache = TokenCache()
        let t0 = Date()

        await runTest("Cached token is returned without refreshing") {
            let tok1 = try await cache.getToken(now: t0) {
                ("token_abc_1", 3600)
            }
            try assertEqual(tok1, "token_abc_1")
            try assertEqual(await cache.refreshCallCount, 1)

            // 10 minutes later (still valid)
            let tok2 = try await cache.getToken(now: t0.addingTimeInterval(600)) {
                ("token_abc_2", 3600)
            }
            try assertEqual(tok2, "token_abc_1")
            try assertEqual(await cache.refreshCallCount, 1)
        }

        await runTest("Token refreshing when inside 60-second cushion") {
            // At 3550s (less than 60s remaining before 3600s expiry)
            let tok3 = try await cache.getToken(now: t0.addingTimeInterval(3550)) {
                ("token_refreshed", 3600)
            }
            try assertEqual(tok3, "token_refreshed")
            try assertEqual(await cache.refreshCallCount, 2)
        }

        await runTest("Stampede protection: 100 concurrent calls share 1 refresh") {
            await cache.clear()
            let countBefore = await cache.refreshCallCount

            try await withThrowingTaskGroup(of: String.self) { group in
                for _ in 0..<100 {
                    group.addTask {
                        try await cache.getToken(now: Date()) {
                            try await Task.sleep(nanoseconds: 15_000_000) // 15ms
                            return ("token_concurrent_shared", 3600)
                        }
                    }
                }
                for try await tok in group {
                    try assertEqual(tok, "token_concurrent_shared")
                }
            }

            let countAfter = await cache.refreshCallCount
            try assertEqual(countAfter - countBefore, 1, "Expected exactly 1 refresh for 100 concurrent requests")
        }

        await runTest("Token refresh failure propagates and resets for retry") {
            await cache.clear()

            struct TestNetworkError: Error, Equatable {}

            // First call fails
            do {
                _ = try await cache.getToken(now: Date()) {
                    throw TestNetworkError()
                }
                throw TestFailure(message: "Expected error to be thrown", file: #file, line: #line)
            } catch is TestNetworkError {
                // Good!
            }

            // Second call retries and succeeds (not stuck on old failed task)
            let recoveredToken = try await cache.getToken(now: Date()) {
                ("token_recovered", 3600)
            }
            try assertEqual(recoveredToken, "token_recovered")
        }
    }

    // MARK: - 7. Delta Sync Logic Tests

    func testDeltaSyncLogic() async {
        print("• Delta Sync Filtering & Boundary Cases:")

        await runTest("Delta search matches only threads with inbound activity") {
            let activeSend1 = TestMailSend(id: "s1", contactID: "r1", sentAt: Date(timeIntervalSince1970: 1000), gmailThreadID: "thread_111")
            let activeSend2 = TestMailSend(id: "s2", contactID: "r2", sentAt: Date(timeIntervalSince1970: 2000), gmailThreadID: "thread_222")
            let activeSend3 = TestMailSend(id: "s3", contactID: "r3", sentAt: Date(timeIntervalSince1970: 3000), gmailThreadID: "thread_333")
            let allPending = [activeSend1, activeSend2, activeSend3]

            let incomingThreadIDs: Set<String> = ["thread_222", "thread_999"]

            let candidates = allPending.filter { send in
                guard let tid = send.gmailThreadID else { return false }
                return incomingThreadIDs.contains(tid)
            }

            try assertEqual(candidates.count, 1)
            try assertEqual(candidates.first?.id, "s2")
        }

        await runTest("Empty delta search inspects zero threads") {
            let activeSend1 = TestMailSend(id: "s1", contactID: "r1", sentAt: Date(), gmailThreadID: "thread_111")
            let incomingThreadIDs: Set<String> = []

            let candidates = [activeSend1].filter { send in
                guard let tid = send.gmailThreadID else { return false }
                return incomingThreadIDs.contains(tid)
            }

            try assertEqual(candidates.count, 0)
        }

        await runTest("Excluding invalidated / bounced contacts from check targets") {
            let validSend = TestMailSend(id: "s1", contactID: "r_valid", sentAt: Date(), gmailThreadID: "thread_1")
            let bouncedSend = TestMailSend(id: "s2", contactID: "r_invalid", sentAt: Date(), gmailThreadID: "thread_2")

            let validContactIDs: Set<String> = ["r_valid"]
            let sendsToCheck = [validSend, bouncedSend].filter { validContactIDs.contains($0.contactID) }

            try assertEqual(sendsToCheck.count, 1)
            try assertEqual(sendsToCheck.first?.id, "s1")
        }
    }

    // MARK: - 8. Concurrency Safety Tests

    func testConcurrencySafety() async {
        print("• Concurrency Safety & TaskGroup Gathering:")

        await runTest("Collecting outcomes concurrently without data race") {
            let count = 100
            let items = (0..<count).map { "item_\($0)" }

            enum WorkResult {
                case success(String)
                case failure(String)
            }

            var successCount = 0
            var failureCount = 0

            for chunk in stride(from: 0, to: items.count, by: 10).map({
                Array(items[$0..<min($0 + 10, items.count)])
            }) {
                try await withThrowingTaskGroup(of: WorkResult.self) { group in
                    for item in chunk {
                        group.addTask {
                            try await Task.sleep(nanoseconds: 1_000)
                            if item.hasSuffix("0") {
                                return .failure(item)
                            } else {
                                return .success(item)
                            }
                        }
                    }
                    for try await res in group {
                        switch res {
                        case .success: successCount += 1
                        case .failure: failureCount += 1
                        }
                    }
                }
            }

            try assertEqual(successCount + failureCount, count)
            try assertEqual(failureCount, 10)
            try assertEqual(successCount, 90)
        }
    }

    // MARK: - 9. Randomized Fuzzing Tests (500 Iterations)

    func testRandomizedFuzzing() async {
        print("• Randomized Fuzz Testing (500 Iterations):")

        await runTest("Random thread structures, timestamps, and headers") {
            let names = ["Alice", "Bob", "Charlie", "Contact Team", "Talent Scout", "René Müller", "Jane (Hiring)"]
            let companies = ["google.com", "stripe.com", "meta.com", "apple.com", "startup.io", "tech.co"]
            let autoHeaders = ["auto-generated", "auto-replied", "bulk", "junk", "list", "no", "  bulk \n"]
            let snippetPhrases = [
                "Sounds great, let&#39;s chat!",
                "Sorry, we are not hiring &amp; all the best.",
                "I&#39;m OOO until next week.",
                "Delivery has failed to recipients.",
                "Thank you for reaching out &quot;Aryan&quot;!",
                "&#60;Hello&#62; from team!",
                "Let's talk &#x1F600; soon!"
            ]

            var totalDetectedReplies = 0
            var totalDetectedBounces = 0
            var totalSilent = 0

            for iteration in 0..<500 {
                let sendTimestamp = 1_000_000 + Double(iteration * 10_000)
                let sendDate = Date(timeIntervalSince1970: sendTimestamp)

                let messageCount = Int.random(in: 1...10)
                var messages: [GmailThreadMock.MessageMock] = []

                // Original send
                messages.append(.init(
                    id: "send_\(iteration)",
                    labelIds: ["SENT"],
                    snippet: "Mail inquiry",
                    internalDate: String(Int(sendTimestamp * 1000)),
                    payload: .init(headers: [.init(name: "From", value: "me@gmail.com")])
                ))

                for msgIdx in 1...messageCount {
                    let msgTimestamp = sendTimestamp + Double.random(in: -1000...10000)
                    let isOurs = (msgIdx % 3 == 0) // ~33%
                    let isBounceMsg = !isOurs && (msgIdx % 5 == 0)
                    let isAutoMsg = !isOurs && !isBounceMsg && (msgIdx % 4 == 0)

                    var headers: [GmailThreadMock.MessageMock.PayloadMock.HeaderMock] = []
                    var labels: [String] = []

                    let fromAddress: String
                    if isOurs {
                        labels.append("SENT")
                        fromAddress = "me@gmail.com"
                    } else if isBounceMsg {
                        labels.append("INBOX")
                        fromAddress = "mailer-daemon@\(companies.randomElement()!)"
                    } else if isAutoMsg {
                        labels.append("INBOX")
                        fromAddress = "contact@\(companies.randomElement()!)"
                        headers.append(.init(name: "Auto-Submitted", value: autoHeaders.randomElement()!))
                    } else {
                        labels.append("INBOX")
                        fromAddress = "\(names.randomElement()!) <contact@\(companies.randomElement()!)>"
                    }
                    headers.append(.init(name: "From", value: fromAddress))

                    messages.append(.init(
                        id: "msg_\(iteration)_\(msgIdx)",
                        labelIds: labels,
                        snippet: snippetPhrases.randomElement()!,
                        internalDate: String(Int(msgTimestamp * 1000)),
                        payload: .init(headers: headers)
                    ))
                }

                messages.shuffle()

                // Compute oracle expectation
                var oracleBounce = false
                var oracleReply: (from: String, date: Date)? = nil
                for m in messages.sorted(by: { $0.date < $1.date }) {
                    guard !m.isOurs else { continue }
                    if m.date <= sendDate { continue }
                    if m.isBounce { oracleBounce = true; continue }
                    if m.isAutomated { continue }
                    guard let from = m.from, !from.isEmpty else { continue }
                    oracleReply = (from, m.date)
                    break
                }

                let mockThread = GmailThreadMock(messages: messages)
                let threadData = try JSONEncoder().encode(mockThread)
                let response = try parseThread(data: threadData, after: sendDate)

                switch response {
                case .reply(let at, let from, _):
                    totalDetectedReplies += 1
                    try assertTrue(oracleReply != nil, "Detected reply but oracle had none in iteration \(iteration)")
                    try assertEqual(from, oracleReply?.from ?? "", "From mismatch in iteration \(iteration)")
                    try assertEqual(at, oracleReply?.date ?? .distantPast, "Date mismatch in iteration \(iteration)")
                case .bounce:
                    totalDetectedBounces += 1
                    try assertTrue(oracleReply == nil, "Expected reply but got bounce in iteration \(iteration)")
                    try assertTrue(oracleBounce, "Got bounce but oracle had no bounce in iteration \(iteration)")
                case .silent:
                    totalSilent += 1
                    try assertTrue(oracleReply == nil, "Expected reply but got silent in iteration \(iteration)")
                    try assertTrue(!oracleBounce, "Expected bounce but got silent in iteration \(iteration)")
                }
            }

            print("    Generated 500 fuzzed threads: detected \(totalDetectedReplies) replies, \(totalDetectedBounces) bounces, \(totalSilent) silent without a single crash or oracle deviation.")
        }
    }
}

// MARK: - Entry Point

let suite = ReplySyncTestSuite()
await suite.runAll()
