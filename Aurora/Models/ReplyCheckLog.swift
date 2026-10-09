import Foundation

/// One reply check, as the status timeline shows it: when it ran, how far back
/// it read, and what each step did. Only the latest is kept, per account, on
/// the phone (`reply-checks-<account>.json`): a check that finishes replaces
/// the one before it.
nonisolated struct ReplyCheckRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    let startedAt: Date
    var finishedAt: Date?
    /// Where it started reading: nil when it read everything.
    let readFrom: Date?
    /// The steps this check set out to take, in order, so the timeline can
    /// show the ones still to come.
    var plan: [String]?
    var steps: [Step] = []
    var result: Result = .running

    struct Step: Codable, Equatable, Identifiable {
        var id: String { title }
        let title: String
        /// What it did, in a line: "Read 12 threads with new mail · 2 replies".
        var summary: String
        /// What went wrong, each with how often: "3 couldn't be read: Connection dropped".
        var issues: [String] = []
    }

    enum Result: Codable, Equatable {
        case running
        /// Everything it tried was read.
        case complete
        /// Some reads failed; the next check reads from where this one began.
        case incomplete
        /// It stopped partway, and why.
        case stopped(String)
    }

    /// How long it took, once it has finished.
    var duration: TimeInterval? { finishedAt.map { $0.timeIntervalSince(startedAt) } }
}

/// The checks kept, newest first: the latest, and while one is running, the
/// one before it.
nonisolated struct ReplyCheckLog: Codable, Equatable {
    var records: [ReplyCheckRecord] = []
    static let limit = 2

    mutating func begin(_ record: ReplyCheckRecord) {
        records.insert(record, at: 0)
        if records.count > Self.limit { records.removeLast(records.count - Self.limit) }
    }

    /// Keep only the record with `id`: a finished check replaces the one before.
    mutating func keepOnly(_ id: UUID) {
        records.removeAll { $0.id != id }
    }

    /// Change the record with `id`, if it's still kept.
    mutating func update(_ id: UUID, _ change: (inout ReplyCheckRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index])
    }

    /// Why reads fail, said briefly, so the same cause is counted once:
    /// "Gmail's rate limit", "Connection dropped".
    static func reason(for error: Error) -> String {
        switch error {
        case let error as GmailAuthError:
            if case .server(let message) = error {
                let lower = message.lowercased()
                if lower.contains("rate") || lower.contains("quota") { return "Gmail's rate limit, even after waiting" }
                return "Gmail said: " + String(message.prefix(100))
            }
            return error.localizedDescription
        case let error as URLError where error.code == .notConnectedToInternet:
            return "Offline"
        case is URLError:
            return "Connection dropped"
        case is DecodingError:
            return "Gmail's answer couldn't be read"
        default:
            return String(error.localizedDescription.prefix(100))
        }
    }

    /// "3 couldn't be read: Connection dropped", most common first.
    static func issues(_ reasons: [String: Int], noun: String = "couldn't be read") -> [String] {
        reasons.sorted { $0.value > $1.value }.map { "\($0.value) \(noun): \($0.key)" }
    }
}
