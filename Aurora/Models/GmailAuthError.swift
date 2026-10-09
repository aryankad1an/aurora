import Foundation

enum GmailAuthError: LocalizedError {
    case cancelled
    case invalidResponse
    case notConnected
    case insufficientScope
    /// Google refused the stored refresh token (`invalid_grant`): it was
    /// revoked, or it expired — an app whose OAuth consent screen is in Testing
    /// gets tokens that last seven days. Only signing in again fixes it.
    case sessionExpired
    /// Gmail refused the account rather than a mail: a sending limit, the API
    /// disabled, the account blocked from sending, or Gmail down. Every later
    /// send would be refused too.
    case refused(String)
    /// Gmail asked for the sends to slow down, and took nothing.
    /// Nothing is wrong with the mail or the account: waiting fixes it.
    /// `retryAt` is when Gmail said to try again, when it said.
    case rateLimited(String, retryAt: Date?)
    /// Gmail failed partway (a 5xx): it may or may not have taken a mail that
    /// was being sent, so the queue checks Sent mail before sending it again,
    /// and otherwise waits it out like a rate limit. `retryAt` as above.
    case unavailable(String, retryAt: Date?)
    case server(String)
    /// What was asked for isn't there (a 404): a thread or message deleted in
    /// Gmail. Nothing to read, and nothing wrong.
    case gone(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Sign-in was cancelled."
        case .invalidResponse: return "Unexpected response from Google."
        case .notConnected: return "Gmail isn't signed in on this device. Reconnect Gmail in Settings."
        case .insufficientScope:
            return "Reply tracking needs permission to read your mail. Reconnect Gmail in Settings to grant it."
        case .sessionExpired:
            return "Your Gmail sign-in has expired. Reconnect Gmail in Settings."
        case .refused(let message): return message
        case .rateLimited(let message, _): return "Gmail asked to slow down: \(message)"
        case .unavailable(let message, _): return message
        case .server(let message): return message
        case .gone(let message): return message
        }
    }

    /// Whether the fix is signing in to Gmail again — the UI answers these with
    /// a Reconnect prompt rather than an error. `notConnected` counts: it only
    /// reaches the UI when the app still shows an account but its token is gone,
    /// and Profile then has no Connect button to point at — only Reconnect.
    var needsReconnect: Bool {
        switch self {
        case .notConnected, .insufficientScope, .sessionExpired: true
        default: false
        }
    }

    /// A rate limit or Gmail being briefly down: what Gmail said, and when it
    /// said to try again. The queue waits these out instead of stopping.
    var waitsOut: (message: String, retryAt: Date?)? {
        switch self {
        case .rateLimited(let message, let retryAt), .unavailable(let message, let retryAt): (message, retryAt)
        default: nil
        }
    }

    /// Whether every later request would fail the same way, so a run of them
    /// (a send batch, a reply sync) should stop rather than fail one by one.
    var endsRun: Bool {
        switch self {
        case .notConnected, .insufficientScope, .sessionExpired, .refused, .rateLimited, .unavailable: true
        default: false
        }
    }
}
