import Foundation

/// Up to when an account's mail has been read for replies and bounces, kept on
/// the phone per account (`reply-checkpoint-<account>.json`).
///
/// A reply check reads the threads of every open send — a request each — and
/// two inbox searches for failure notices. Once a check has read everything
/// Gmail had when it began, the next only needs what has come since: the
/// threads with inbound mail after that time, and notices after it. An
/// account's first check, or one asked to read everything, has no
/// checkpoint to go from and reads it all.
nonisolated struct ReplyCheckpoint: Codable, Equatable {
    /// When the last check that read everything it tried began.
    var checkedThrough: Date?

    /// Slack under `checkedThrough`, so nothing falls between two checks:
    /// Gmail's clock and the phone's differ, and mail can be indexed late.
    static let overlap: TimeInterval = 15 * 60

    /// Where a check should start reading: nil to read everything.
    func readFrom(fullCheck: Bool) -> Date? {
        guard !fullCheck, let checkedThrough else { return nil }
        return checkedThrough.addingTimeInterval(-Self.overlap)
    }

    /// A check that began at `startedAt` has finished. It moves the checkpoint
    /// on only if every read worked — a thread that couldn't be read must be
    /// read again next time, which a later checkpoint would skip — and never
    /// back.
    mutating func complete(startedAt: Date, failedReads: Int) {
        guard failedReads == 0, startedAt > (checkedThrough ?? .distantPast) else { return }
        checkedThrough = startedAt
    }

    /// A Gmail search term for mail after `date` ("after:1760000000"), or nil
    /// for no limit.
    static func searchTerm(after date: Date?) -> String? {
        date.map { "after:\(Int($0.timeIntervalSince1970))" }
    }
}
