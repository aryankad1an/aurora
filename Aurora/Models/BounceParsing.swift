import Foundation

/// Reading a delivery-failure notice: whether a message is one, whether it's
/// final or only a delay, which addresses it's about, and why they failed.
///
/// Most notices carry a machine-readable report (RFC 3464) beside the prose: per
/// failed address, the address, what happened to it (`Action: failed` or
/// `delayed`), and a status code (`5.1.1`: no such mailbox). They also quote
/// the original mail's headers back, `Message-ID` included, which names the
/// exact send that bounced. `parseNotice` reads those; the phrase-matching
/// below is the fallback for servers that send prose alone.
///
/// Kept free of the rest of the app so it can be tested on its own:
///
///     swiftc Aurora/Models/BounceParsing.swift Tests/BounceParsingTests.swift -o /tmp/bt && /tmp/bt
nonisolated enum BounceParsing {

    /// Mail servers send failure notices as the mailer daemon or the postmaster.
    /// Exchange sends its own ("Undeliverable: …") from a fixed service account
    /// at the recipient's domain.
    static func isBounceSender(_ from: String?) -> Bool {
        let sender = (from ?? "").lowercased()
        return sender.contains("mailer-daemon") || sender.contains("postmaster")
            || sender.contains(exchangeSender)
    }

    static let exchangeSender = "microsoftexchange329e71ec88ae4615bbc36ab6ce41109e"

    /// The inbox search for notices: the usual senders, or the usual subjects
    /// from anyone — a subject alone isn't trusted, and `parseNotice` confirms
    /// each one is really a notice before it counts.
    static let noticeQuery = "{from:mailer-daemon from:postmaster from:\(exchangeSender) "
        + "subject:undeliverable subject:\"delivery status notification\" subject:\"returned mail\" "
        + "subject:\"delivery failure\" subject:\"undelivered mail\" subject:\"failure notice\"} "
        + "-from:me newer_than:120d"

    /// A "still trying" notice rather than a failure. Gmail sends one when a
    /// server is slow to accept a mail, then keeps retrying for days, and most
    /// of those mails are delivered in the end. Treating a delay as a bounce
    /// would rule out live addresses.
    static func isDelay(subject: String?, snippet: String?) -> Bool {
        let subject = (subject ?? "").lowercased()
        if subject.contains("delay") { return true }
        let text = (snippet ?? "").lowercased()
        return text.contains("will retry") || text.contains("temporary problem")
            || text.contains("has been delayed") || text.contains("not yet been delivered")
            || text.contains("hasn't been delivered yet")
    }

    /// The addresses a notice says it couldn't deliver to, lowercased. Gmail
    /// names them in an `X-Failed-Recipients` header; notices without one name
    /// them in the text ("wasn't delivered to jane@acme.com because…").
    static func failedAddresses(header: String?, snippet: String?) -> [String] {
        if let header, !header.trimmingCharacters(in: .whitespaces).isEmpty {
            let listed = header.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "<>")).lowercased() }
                .filter { $0.contains("@") }
            if !listed.isEmpty { return listed }
        }
        guard let snippet else { return [] }
        var found: [String] = []
        for match in snippet.matches(of: #/[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/#) {
            let address = String(match.output).lowercased()
            guard !isBounceSender(address), !found.contains(address) else { continue }
            found.append(address)
        }
        return found
    }

    /// Why an address failed. The status code is the server's own answer and
    /// wins when it's specific; the text decides when it isn't, or is missing.
    static func reason(status: String?, text: String?) -> BounceReason {
        if let status {
            // x.1.1 and Exchange's 5.1.10: no such mailbox. 5.1.6: moved away.
            // 5.2.1: the mailbox is disabled.
            if status.hasPrefix("5.1.1") || status == "5.1.6" || status == "5.2.1" { return .addressNotFound }
            // Bad domain, or nowhere to route it; 5.4.310 is Exchange's "the
            // domain doesn't exist".
            if status == "5.1.2" || status == "5.4.4" || status.hasPrefix("5.4.31") { return .domainNotFound }
            if status.hasSuffix(".2.2") { return .mailboxFull }
            if status.hasPrefix("5.7.") { return .rejected }
        }
        return reason(in: text)
    }

    static func reason(in snippet: String?) -> BounceReason {
        let text = (snippet ?? "").lowercased()
        func has(_ phrases: String...) -> Bool { phrases.contains { text.contains($0) } }
        // Before "address not found": Gmail's notice for a dead domain is headed
        // "Address not found" too, and only its text says it's the domain.
        if has("the domain", "domain not found", "5.1.2", "dns") && has("couldn't be found", "not found", "5.1.2", "dns") {
            return .domainNotFound
        }
        if has("address not found", "couldn't be found", "does not exist", "doesn't exist", "user unknown",
               "no such user", "5.1.1", "unknown recipient", "invalid recipient", "mailbox unavailable",
               "recipient not found", "address rejected") {
            return .addressNotFound
        }
        if has("mailbox full", "mailbox is full", "over quota", "quota exceeded", "5.2.2", "out of storage", "inbox is full") {
            return .mailboxFull
        }
        if has("blocked", "rejected", "policy", "spam", "5.7.", "not allowed", "denied") {
            return .rejected
        }
        return .other
    }
}

// MARK: - Reading a whole notice

/// One address a notice says wasn't delivered.
nonisolated struct BounceFailure: Equatable {
    /// Lowercased. The address the mail was sent to, where the report gives it
    /// (`Original-Recipient`), since a forwarded address fails under another name.
    let address: String
    /// The enhanced status code, `5.1.1` and the like.
    let status: String?
    /// The receiving server's own words, cleaned of SMTP codes.
    let diagnostic: String?
}

/// A message read as a possible failure notice.
nonisolated struct ParsedNotice {
    /// One recipient's entry in a machine-readable report.
    struct Recipient: Equatable {
        let address: String
        /// `failed`, `delayed`, `delivered`, `relayed` or `expanded`.
        let action: String
        let status: String?
        let diagnostic: String?
    }

    var from: String?
    var subject: String?
    var failedRecipientsHeader: String?
    /// The report's recipients; nil when the notice has no report at all.
    var report: [Recipient]?
    /// The original mail's `Message-ID`, without angle brackets.
    var originalMessageID: String?
    /// The notice's first plain-text part: the prose a person would read.
    var text: String?

    /// Whether this is a delivery notice at all, rather than a person's mail
    /// that happens to say "undeliverable" in the subject.
    var isNotice: Bool {
        report != nil || failedRecipientsHeader != nil || BounceParsing.isBounceSender(from)
    }

    /// The addresses this notice says failed for good. Empty for a delay, a
    /// success report, or anything that isn't a notice.
    ///
    /// - Parameter snippet: Gmail's preview of the message, used with the text
    ///   when there's no report to go on.
    func failures(snippet: String?) -> [BounceFailure] {
        guard isNotice else { return [] }
        if let report, !report.isEmpty {
            return report.filter { $0.action == "failed" }.map {
                BounceFailure(address: $0.address, status: $0.status, diagnostic: $0.diagnostic)
            }
        }
        let prose = [snippet, text.map { String($0.prefix(1500)) }].compactMap { $0 }.joined(separator: " ")
        let opening = String(prose.prefix(600))
        guard !BounceParsing.isDelay(subject: subject, snippet: opening) else { return [] }
        let status = BounceParsing.statusCode(in: prose)
        return BounceParsing.failedAddresses(header: failedRecipientsHeader, snippet: prose).map {
            BounceFailure(address: $0, status: status, diagnostic: nil)
        }
    }
}

nonisolated extension BounceParsing {

    /// Read a message fetched with Gmail's `format=raw`: base64url of the whole
    /// RFC 822 text.
    static func parseNotice(base64URL raw: String) -> ParsedNotice? {
        var base64 = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else { return nil }
        return parseNotice(raw: text(of: data))
    }

    /// Read a message's full RFC 822 text.
    static func parseNotice(raw: String) -> ParsedNotice {
        let message = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let (headers, _) = splitEntity(message)
        var notice = ParsedNotice(from: headers["from"], subject: headers["subject"],
                                  failedRecipientsHeader: headers["x-failed-recipients"])
        walk(message, depth: 0, into: &notice)
        return notice
    }

    /// The first enhanced status code in some text: `5.1.1` in "550 5.1.1 User unknown".
    static func statusCode(in text: String?) -> String? {
        guard let text, let match = text.firstMatch(of: #/\b([245])\.(\d{1,3})\.(\d{1,3})\b/#) else { return nil }
        return "\(match.output.1).\(match.output.2).\(match.output.3)"
    }

    // MARK: MIME

    private static func walk(_ entity: String, depth: Int, into notice: inout ParsedNotice) {
        guard depth < 8 else { return }
        let (headers, body) = splitEntity(entity)
        let (type, parameters) = contentType(headers["content-type"])
        let encoding = headers["content-transfer-encoding"]

        switch type {
        case _ where type.hasPrefix("multipart/"):
            guard let boundary = parameters["boundary"], !boundary.isEmpty else { return }
            for part in parts(of: body, boundary: boundary) {
                walk(part, depth: depth + 1, into: &notice)
            }
        case "message/delivery-status", "message/global-delivery-status":
            let recipients = deliveryStatus(decode(body, encoding: encoding))
            notice.report = (notice.report ?? []) + recipients
        case "text/rfc822-headers", "message/rfc822-headers", "message/rfc822", "message/global":
            // Only the quoted mail's headers matter; its body is ours.
            guard notice.originalMessageID == nil else { return }
            let quoted = decode(body, encoding: encoding).replacingOccurrences(of: "\r\n", with: "\n")
            notice.originalMessageID = messageID(splitEntity(quoted).headers["message-id"])
        case "text/plain", "":
            guard notice.text == nil else { return }
            notice.text = decode(body, encoding: encoding, charset: parameters["charset"])
        default:
            break
        }
    }

    /// Headers (names lowercased, folded lines joined, first occurrence kept)
    /// and the body after the blank line.
    private static func splitEntity(_ entity: String) -> (headers: [String: String], body: String) {
        let head: Substring
        let body: String
        if entity.hasPrefix("\n") {
            head = ""
            body = String(entity.dropFirst())
        } else if let blank = entity.range(of: "\n\n") {
            head = entity[..<blank.lowerBound]
            body = String(entity[blank.upperBound...])
        } else {
            head = entity[...]
            body = ""
        }
        var headers: [String: String] = [:]
        var name: String?
        var value = ""
        func flush() {
            if let name, headers[name] == nil { headers[name] = value.trimmingCharacters(in: .whitespaces) }
        }
        for line in head.split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = line.first, first == " " || first == "\t" {
                value += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                flush()
                name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                value = String(line[line.index(after: colon)...])
            }
        }
        flush()
        return (headers, body)
    }

    /// `text/plain; charset="utf-8"` → ("text/plain", ["charset": "utf-8"]).
    private static func contentType(_ header: String?) -> (String, [String: String]) {
        guard let header else { return ("", [:]) }
        let pieces = header.split(separator: ";")
        let type = pieces.first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        var parameters: [String: String] = [:]
        for piece in pieces.dropFirst() {
            guard let equals = piece.firstIndex(of: "=") else { continue }
            let key = piece[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = piece[piece.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            parameters[key] = value
        }
        return (type, parameters)
    }

    /// The parts of a multipart body, between its boundary lines.
    private static func parts(of body: String, boundary: String) -> [String] {
        let open = "--" + boundary
        let close = open + "--"
        var parts: [String] = []
        var current: [Substring]?
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == close {
                if let current { parts.append(current.joined(separator: "\n")) }
                return parts
            }
            if trimmed == open {
                if let current { parts.append(current.joined(separator: "\n")) }
                current = []
            } else {
                current?.append(line)
            }
        }
        if let current { parts.append(current.joined(separator: "\n")) }
        return parts
    }

    private static func decode(_ body: String, encoding: String?, charset: String? = nil) -> String {
        switch encoding?.lowercased().trimmingCharacters(in: .whitespaces) {
        case "base64":
            guard let data = Data(base64Encoded: body, options: .ignoreUnknownCharacters) else { return body }
            return text(of: data, charset: charset)
        case "quoted-printable":
            return text(of: quotedPrintable(body), charset: charset)
        default:
            return body
        }
    }

    private static func quotedPrintable(_ body: String) -> Data {
        var bytes: [UInt8] = []
        let source = Array(body.replacingOccurrences(of: "=\n", with: "").utf8)
        var index = 0
        while index < source.count {
            if source[index] == UInt8(ascii: "="), index + 2 < source.count,
               let byte = UInt8(String(decoding: source[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) {
                bytes.append(byte)
                index += 3
            } else {
                bytes.append(source[index])
                index += 1
            }
        }
        return Data(bytes)
    }

    private static func text(of data: Data, charset: String? = nil) -> String {
        if let charset, charset.lowercased().contains("8859") || charset.lowercased().contains("1252"),
           let latin = String(data: data, encoding: .isoLatin1) {
            return latin
        }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    // MARK: Reports

    /// The per-recipient entries of a `message/delivery-status` body: groups of
    /// fields separated by blank lines, the first of which is about the message
    /// as a whole and has no `Final-Recipient`.
    private static func deliveryStatus(_ body: String) -> [ParsedNotice.Recipient] {
        let normalized = body.replacingOccurrences(of: "\r\n", with: "\n")
        var recipients: [ParsedNotice.Recipient] = []
        for group in normalized.components(separatedBy: "\n\n") {
            let fields = splitEntity(group + "\n\n").headers
            guard let final = fields["final-recipient"] else { continue }
            let address = recipientAddress(fields["original-recipient"]) ?? recipientAddress(final)
            guard let address else { continue }
            let action = (fields["action"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            recipients.append(ParsedNotice.Recipient(
                address: address,
                action: action,
                status: statusCode(in: fields["status"]),
                diagnostic: cleanDiagnostic(fields["diagnostic-code"])
            ))
        }
        return recipients
    }

    /// `rfc822; Jane@Acme.com` → `jane@acme.com`.
    private static func recipientAddress(_ field: String?) -> String? {
        guard let field else { return nil }
        let value = field.split(separator: ";", maxSplits: 1).last.map(String.init) ?? field
        let address = value.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            .lowercased()
        return address.contains("@") ? address : nil
    }

    /// `smtp; 550-5.1.1 The email account … 550-5.1.1 double-checking …` →
    /// "The email account … double-checking …".
    private static func cleanDiagnostic(_ field: String?) -> String? {
        guard let field else { return nil }
        var text = field
        if let semicolon = text.firstIndex(of: ";"),
           text[..<semicolon].allSatisfy({ $0.isLetter || $0 == "-" }) {
            text = String(text[text.index(after: semicolon)...])
        }
        // The reply code, alone at the start or with a status code after it on
        // each continuation line. A bare number mid-sentence is left alone.
        text = text.replacing(#/\b[245]\d\d[ -][245]\.\d{1,3}\.\d{1,3}\b\s*/#, with: "")
        text = text.replacing(#/^\s*[245]\d\d[ -]/#, with: "")
        text = text.replacing(#/\s+/#, with: " ").trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// A `Message-ID` header's id, without brackets, if it's safe to search for.
    private static func messageID(_ header: String?) -> String? {
        guard let header else { return nil }
        let id = header.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".@+=-_$%#!&*/?^~|"))
        guard !id.isEmpty, id.count <= 250, id.contains("@"),
              id.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return id
    }
}

/// Why a mail came back, as the notice put it.
nonisolated enum BounceReason: Equatable {
    case addressNotFound, domainNotFound, mailboxFull, rejected, other

    var label: String {
        switch self {
        case .addressNotFound: "Address not found"
        case .domainNotFound: "Domain doesn't exist"
        case .mailboxFull: "Mailbox full"
        case .rejected: "Rejected by their server"
        case .other: "Couldn't be delivered"
        }
    }

    var systemImage: String {
        switch self {
        case .addressNotFound: "person.crop.circle.badge.xmark"
        case .domainNotFound: "globe.badge.chevron.backward"
        case .mailboxFull: "tray.full"
        case .rejected: "hand.raised"
        case .other: "exclamationmark.triangle"
        }
    }
}
