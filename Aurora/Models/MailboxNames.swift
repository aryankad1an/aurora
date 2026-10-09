import Foundation
import Observation

/// The names people go by in this account's own mail, by address.
///
/// A contact row often has no usable name, only an address like `kdaryan@`
/// that can't be read with confidence. But if that address has ever mailed
/// this account, or been mailed or copied with a name on it, the headers say
/// who it is: `From: Aryan Kadian <kdaryan@acme.com>`. This looks each such
/// address up once in Gmail — mail from it first, then mail to or copying it —
/// and keeps the header entry that names that exact address. `RecipientName`
/// decides whether the name in it is a person's (not "Acme Recruiting", not
/// the mailbox spelt out) before it greets anyone by it.
///
/// Read-only, through the Gmail access reply tracking already has: nothing is
/// sent anywhere but this account's own Gmail, and what's found stays on the
/// device, per account.
@Observable
final class MailboxNames {
    static let shared = MailboxNames()

    /// Performs an authorized Gmail GET. Injected, like `ReplySync.reader`.
    @ObservationIgnored var reader: ((String, [URLQueryItem]) async throws -> Data)?

    /// The header entry found for each address, by lowercased address:
    /// "Aryan Kadian <kdaryan@acme.com>".
    private(set) var found: [String: String] = [:]
    /// When an address was looked up and nothing usable was found.
    @ObservationIgnored private var missed: [String: Date] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var file: JSONFile<Log>?

    private struct Log: Codable {
        var found: [String: String] = [:]
        var missed: [String: Date] = [:]
    }

    /// A miss is tried again after this long: they may have written since.
    nonisolated static let retryAfter: TimeInterval = 30 * 24 * 60 * 60
    nonisolated static let concurrency = 4
    /// Messages read per search. The first that names the address is enough;
    /// a few more cover mail whose headers carry only the bare address.
    nonisolated static let messagesPerSearch = 3

    /// Open this account's record of what has been looked up.
    func load(account: String) {
        let file = JSONFile<Log>(name: "mailbox-names-\(account).json")
        self.file = file
        let log = file.load() ?? Log()
        found = log.found
        missed = log.missed
        inFlight = []
    }

    /// The header entry naming `email`, if one was found.
    func entry(for email: String) -> String? {
        found[email.lowercased().trimmingCharacters(in: .whitespaces)]
    }

    /// Look up every address not looked up yet (or missed more than a month
    /// ago). `accepts` says whether a header entry names a person; the first
    /// accepted one is kept. Returns how many names were found.
    @discardableResult
    func lookUp(_ emails: [String], accepting accepts: (String, String) -> Bool) async -> Int {
        guard let reader else { return 0 }
        let now = Date()
        var todo: [String] = []
        for raw in emails {
            let email = raw.lowercased().trimmingCharacters(in: .whitespaces)
            guard ReplySync.isSearchable(email), found[email] == nil, !inFlight.contains(email),
                  now.timeIntervalSince(missed[email] ?? .distantPast) > Self.retryAfter,
                  !todo.contains(email) else { continue }
            todo.append(email)
        }
        guard !todo.isEmpty else { return 0 }
        inFlight.formUnion(todo)
        defer { inFlight.subtract(todo) }

        var named = 0
        for chunk in stride(from: 0, to: todo.count, by: Self.concurrency).map({
            Array(todo[$0..<min($0 + Self.concurrency, todo.count)])
        }) {
            let results: [(String, [String]?)]
            do {
                results = try await withThrowingTaskGroup(of: (String, [String]?).self) { group in
                    for email in chunk {
                        group.addTask {
                            do {
                                return (email, try await Self.candidates(for: email, reader: reader))
                            } catch let error as GmailAuthError where error.endsRun {
                                throw error
                            } catch {
                                return (email, nil)  // couldn't look: try again next time
                            }
                        }
                    }
                    var out: [(String, [String]?)] = []
                    for try await result in group { out.append(result) }
                    return out
                }
            } catch {
                break  // the Gmail session has ended; nothing more can be looked up
            }
            for (email, entries) in results {
                guard let entries else { continue }
                if let entry = entries.first(where: { accepts($0, email) }) {
                    found[email] = entry
                    missed[email] = nil
                    named += 1
                } else {
                    missed[email] = now
                }
            }
        }
        file?.save(Log(found: found, missed: missed))
        return named
    }

    // MARK: - Gmail

    /// Every header entry naming `email` in the account's mail: from it first,
    /// then to or copying it. Empty when the mail never names it.
    nonisolated static func candidates(for email: String,
                                       reader: (String, [URLQueryItem]) async throws -> Data) async throws -> [String] {
        var entries: [String] = []
        for query in ["from:\(email)", "{to:\(email) cc:\(email)}"] {
            for id in try await search(query, reader: reader) {
                entries += try await headerEntries(naming: email, inMessage: id, reader: reader)
            }
            if !entries.isEmpty { break }
        }
        return entries
    }

    nonisolated private static func search(_ query: String,
                                           reader: (String, [URLQueryItem]) async throws -> Data) async throws -> [String] {
        struct Listing: Decodable {
            struct Message: Decodable { let id: String }
            let messages: [Message]?
        }
        let data = try await reader("messages", [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: String(messagesPerSearch))
        ])
        return (try JSONDecoder().decode(Listing.self, from: data).messages ?? [])
            .map(\.id).filter(ReplySync.isSafePathComponent)
    }

    nonisolated private static func headerEntries(naming email: String, inMessage id: String,
                                                  reader: (String, [URLQueryItem]) async throws -> Data) async throws -> [String] {
        struct Message: Decodable {
            struct Payload: Decodable {
                struct Header: Decodable { let name: String; let value: String }
                let headers: [Header]?
            }
            let payload: Payload?
        }
        let data = try await reader("messages/\(id)", [
            URLQueryItem(name: "format", value: "metadata"),
            URLQueryItem(name: "fields", value: "payload/headers"),
            URLQueryItem(name: "metadataHeaders", value: "From"),
            URLQueryItem(name: "metadataHeaders", value: "To"),
            URLQueryItem(name: "metadataHeaders", value: "Cc")
        ])
        let headers = try JSONDecoder().decode(Message.self, from: data).payload?.headers ?? []
        return headers
            .filter { ["from", "to", "cc"].contains($0.name.lowercased()) }
            .flatMap { entries(in: $0.value) }
            .filter { address(of: $0)?.caseInsensitiveCompare(email) == .orderedSame }
    }

    // MARK: - Header parsing

    /// An address header split into its entries: `"Kadian, Aryan" <a@x.com>,
    /// b@y.com` is two. Commas inside quotes or angle brackets don't split.
    nonisolated static func entries(in header: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quoted = false, angled = false
        for character in header {
            switch character {
            case "\"": quoted.toggle()
            case "<" where !quoted: angled = true
            case ">" where !quoted: angled = false
            case "," where !quoted && !angled:
                out.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            default: break
            }
            current.append(character)
        }
        out.append(current.trimmingCharacters(in: .whitespaces))
        return out.filter { !$0.isEmpty }
    }

    /// The address in an entry: what's in its angle brackets, or the entry
    /// itself when it's a bare address.
    nonisolated static func address(of entry: String) -> String? {
        if let open = entry.lastIndex(of: "<"), let close = entry.lastIndex(of: ">"), open < close {
            return entry[entry.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
        }
        return entry.contains("@") ? entry.trimmingCharacters(in: .whitespaces) : nil
    }
}
