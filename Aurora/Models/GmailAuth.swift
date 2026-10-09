import Foundation
import Observation
import CryptoKit
import AuthenticationServices
import UIKit

/// Connects the user's Gmail account via OAuth 2.0 with PKCE, run entirely in an
/// `ASWebAuthenticationSession` — no Google SDK and no Info.plist URL scheme, as
/// the session intercepts the reversed-client-id callback itself.
///
/// The refresh token (used for sending later) lives in the Keychain; only the
/// connected email address is cached on disk for display.
@Observable
final class GmailAuthStore: NSObject, ASWebAuthenticationPresentationContextProviding {
    private(set) var connectedEmail: String?
    private(set) var isConnecting = false
    var errorMessage: String?

    var isConnected: Bool { connectedEmail != nil }

    private static let refreshTokenKey = "gmail.refreshToken"
    private let file = JSONFile<Stored>(name: "gmail.json")
    private struct Stored: Codable { var email: String }

    @ObservationIgnored private var webSession: ASWebAuthenticationSession?
    @ObservationIgnored private let tokenVault = TokenVault()

    override init() {
        super.init()
        connectedEmail = file.load()?.email
    }

    // MARK: - Connect / disconnect

    @MainActor
    func connect() async {
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }

        do {
            let verifier = Self.codeVerifier()
            let code = try await authorize(verifier: verifier)
            let tokens = try await exchange(code: code, verifier: verifier)

            if let refresh = tokens.refresh_token {
                Keychain.set(refresh, for: Self.refreshTokenKey)
                await tokenVault.clear()
            }
            let email = tokens.id_token.flatMap(Self.email(fromIDToken:)) ?? "Connected"
            connectedEmail = email
            file.save(Stored(email: email))
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // User dismissed the sign-in sheet — not an error worth surfacing.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func disconnect() {
        Keychain.set(nil, for: Self.refreshTokenKey)
        file.delete()
        connectedEmail = nil
        Task { await tokenVault.clear() }
    }

    // MARK: - Sending

    /// Identifies a message Gmail accepted. The thread is the durable half: a
    /// reply keeps the thread id and gets a new message id, so reply detection
    /// keys on `threadID`.
    struct SentMessage: Decodable {
        let id: String
        let threadID: String

        enum CodingKeys: String, CodingKey {
            case id
            case threadID = "threadId"
        }
    }

    /// Send a plain-text email from the connected account via the Gmail API, and
    /// return the ids Gmail assigned it.
    /// Returns nil when Gmail accepted the mail but its response couldn't be
    /// parsed: the mail is still sent, we just don't know its ids. Reporting that
    /// as a failure would be far worse than losing the ids — the queue would list
    /// it as unsent and offer to mail the person again. The recovery pass in
    /// `ReplySync` can find the thread later anyway.
    @discardableResult
    func send(to recipient: String, subject: String, body: String, fromName: String) async throws -> SentMessage? {
        let token = try await accessToken()
        let raw = Self.mimeMessage(
            from: connectedEmail ?? "", fromName: fromName,
            to: recipient, subject: subject, body: body
        )

        var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["raw": raw])

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard status == 200 else {
            throw Self.sendError(status: status, data: data,
                                 retryAfter: http?.value(forHTTPHeaderField: "Retry-After"))
        }
        return try? JSONDecoder().decode(SentMessage.self, from: data)
    }

    /// Gmail's refusal of a send, sorted by who it's about.
    ///
    /// Only a 400 is about *this* mail (an address Gmail won't take, a header
    /// it can't parse); the queue marks that one failed and carries on.
    /// Everything else is about the account — a sending limit reached, the API
    /// switched off, a session gone, Gmail itself down — and every mail after it
    /// would be refused the same way. Those end the run, so the rest wait
    /// instead of being marked failed one after another.
    ///
    /// A rate limit is neither: Gmail is asking for the sends to slow down, so
    /// it comes back as `rateLimited`, with when to try again if Gmail said, and
    /// the queue waits rather than giving up (`MailQueue.drain`). Gmail being
    /// briefly unavailable (5xx) is waited out the same way, as `unavailable`:
    /// it may have taken the mail before failing, so that's checked first.
    ///
    /// Whatever the case, the reason is Google's own sentence, pulled out of the
    /// JSON it arrives in. Kept raw, a failure used to read as just "{".
    static func sendError(status: Int, data: Data, retryAfter: String? = nil) -> GmailAuthError {
        let google = GoogleError(data: data)
        let message = google?.message ?? "HTTP \(status)"
        if status == 429 || google?.isRateLimit == true {
            return .rateLimited(message, retryAt: retryDate(header: retryAfter, message: message))
        }
        switch status {
        case 400:
            return .server(message)
        case 401:
            return .sessionExpired
        case 403 where google?.isScopeProblem == true:
            return .insufficientScope
        case 403:
            return .refused("Gmail stopped sending from your account: \(message)")
        case 500...599:
            return .unavailable("Gmail is briefly unavailable (\(message)).",
                                retryAt: retryDate(header: retryAfter, message: message))
        default:
            return .refused("Gmail couldn't take the mail (\(message)). Resume to try again.")
        }
    }

    /// When Gmail said to try again: the `Retry-After` header (seconds, or an
    /// HTTP date), else the "Retry after <time>" its rate-limit message ends
    /// with. Nil when it said neither.
    nonisolated static func retryDate(header: String?, message: String, now: Date = .now) -> Date? {
        if let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty {
            if let seconds = Double(header) { return now.addingTimeInterval(seconds) }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: header) { return date }
        }
        guard let match = message.firstMatch(of: /(?i)retry after\s+(\S+)/) else { return nil }
        let text = String(match.1).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: text)
    }

    /// Run an authorized GET against the Gmail API and hand back the raw body.
    ///
    /// Reply syncing needs to read the mailbox, but it has no business holding a
    /// token: this exposes the *capability* while the refresh token and its
    /// short-lived access token stay inside this type.
    func gmailGET(path: String, query: [URLQueryItem]) async throws -> Data {
        let token = try await accessToken()
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/\(path)")!
        if !query.isEmpty { components.queryItems = query }

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw Self.error(status: status, data: data, fallback: "Gmail request failed.")
        }
        return data
    }

    /// The mail sent to `recipient` since `since`, if Sent mail has one — how a
    /// send cut off by the app closing is found to have gone out or not.
    ///
    /// Throws when it can't tell (offline, or an address that can't be searched
    /// safely), so the caller never mistakes "couldn't look" for "not sent".
    func findSent(to recipient: String, since: Date) async throws -> SentMessage? {
        guard ReplySync.isSearchable(recipient) else {
            throw GmailAuthError.server("Can't search Sent mail for \(recipient).")
        }
        // A minute's slack before: the recorded time is the app's, not Gmail's.
        let after = Int(since.addingTimeInterval(-60).timeIntervalSince1970)
        let data = try await gmailGET(path: "messages", query: [
            URLQueryItem(name: "q", value: "in:sent to:\(recipient) after:\(after)"),
            URLQueryItem(name: "maxResults", value: "1")
        ])
        struct Listing: Decodable { let messages: [SentMessage]? }
        return try JSONDecoder().decode(Listing.self, from: data).messages?.first
    }

    /// Translate a Gmail *read* failure into something a person can act on. A
    /// token minted before reply tracking existed is missing the read scope, and
    /// Google says so with a 403 that reads like a bug — it isn't, it just needs
    /// reconnecting, which is the one thing the message should say.
    private static func error(status: Int, data: Data, fallback: String) -> GmailAuthError {
        let google = GoogleError(data: data)
        if status == 401 || status == 403, google?.isScopeProblem == true {
            return .insufficientScope
        }
        return .server(google?.message ?? fallback)
    }

    /// Trade the stored refresh token for a short-lived access token, reusing
    /// a cached token while still valid to prevent redundant round-trips.
    private func accessToken() async throws -> String {
        guard let refresh = Keychain.get(Self.refreshTokenKey) else {
            throw GmailAuthError.notConnected
        }
        return try await tokenVault.getToken(refreshToken: refresh, clientID: AppConfig.googleClientID)
    }

    /// Build a base64url-encoded RFC 2822 message for the Gmail API's `raw` field.
    private static func mimeMessage(from: String, fromName: String, to: String, subject: String, body: String) -> String {
        let fromHeader = fromName.isEmpty ? from : "\(displayName(fromName)) <\(from)>"
        let headers = [
            "From: \(fromHeader)",
            "To: \(to)",
            "Subject: \(encodeHeader(subject))",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=\"UTF-8\"",
            "Content-Transfer-Encoding: 8bit"
        ]
        let message = headers.joined(separator: "\r\n") + "\r\n\r\n" + body
        return Data(message.utf8).base64URLEncodedString()
    }

    /// RFC 2047-encode a header value only when it contains non-ASCII characters.
    private static func encodeHeader(_ text: String) -> String {
        guard !text.allSatisfy(\.isASCII) else { return text }
        return "=?UTF-8?B?\(Data(text.utf8).base64EncodedString())?="
    }

    /// The sender's name as it goes before `<address>`. Non-ASCII is encoded like
    /// the subject — "Aryan Kādian" sent raw reached some clients as mojibake —
    /// and a plain name with punctuation that means something in an address
    /// header ("Kadian, Aryan") is quoted, or it reads as two recipients.
    private static func displayName(_ name: String) -> String {
        guard name.allSatisfy(\.isASCII) else { return encodeHeader(name) }
        guard name.contains(where: { "()<>[]:;@\\,.\"".contains($0) }) else { return name }
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: - OAuth steps

    /// Present Google's consent screen and return the authorization code.
    @MainActor
    private func authorize(verifier: String) async throws -> String {
        defer { webSession = nil }
        let state = UUID().uuidString
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: AppConfig.googleClientID),
            URLQueryItem(name: "redirect_uri", value: AppConfig.googleRedirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: AppConfig.googleScopes),
            URLQueryItem(name: "code_challenge", value: Self.codeChallenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            // Force account choice + consent so a refresh token is always issued.
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]

        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: components.url!,
                callbackURLScheme: AppConfig.googleRedirectScheme
            ) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: error ?? GmailAuthError.cancelled)
                }
            }
            session.presentationContextProvider = self
            webSession = session
            session.start()
        }

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems
        guard items?.first(where: { $0.name == "state" })?.value == state,
              let code = items?.first(where: { $0.name == "code" })?.value else {
            throw GmailAuthError.invalidResponse
        }
        return code
    }

    /// Trade the authorization code for access + refresh tokens.
    private func exchange(code: String, verifier: String) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "client_id", value: AppConfig.googleClientID),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "code_verifier", value: verifier),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "redirect_uri", value: AppConfig.googleRedirectURI)
        ]
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw GmailAuthError.server(String(data: data, encoding: .utf8) ?? "Token exchange failed.")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    // MARK: - Helpers

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let id_token: String?
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // The system always calls this on the main thread.
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
                preconditionFailure("Sign-in was started with no window on screen.")
            }
            return scene.keyWindow ?? ASPresentationAnchor(windowScene: scene)
        }
    }

    private static func codeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private static func codeChallenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }

    /// Pull the email claim out of the returned id_token (a JWT) so we can show
    /// which account connected, without an extra userinfo request.
    private static func email(fromIDToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return claims["email"] as? String
    }
}

/// The JSON Google wraps every API error in:
/// `{"error": {"code": 429, "message": "…", "status": "…", "errors": [{"reason": "…"}]}}`.
/// The token endpoint uses a flatter `{"error": "…", "error_description": "…"}`.
nonisolated struct GoogleError {
    let message: String
    let reasons: [String]

    init?(data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return nil }
            message = String(text.prefix(200))
            reasons = []
            return
        }
        if let error = object["error"] as? [String: Any] {
            let details = error["errors"] as? [[String: Any]] ?? []
            message = (error["message"] as? String) ?? (details.first?["message"] as? String) ?? "Unknown error."
            reasons = details.compactMap { $0["reason"] as? String } + [error["status"] as? String].compactMap { $0 }
        } else if let code = object["error"] as? String {
            message = (object["error_description"] as? String) ?? code
            reasons = [code]
        } else {
            return nil
        }
    }

    /// Gmail asking for fewer requests: a per-user or per-second rate, or the
    /// account's daily sending allowance.
    var isRateLimit: Bool {
        let limits: Set = ["rateLimitExceeded", "userRateLimitExceeded", "dailyLimitExceeded",
                           "quotaExceeded", "RESOURCE_EXHAUSTED"]
        return reasons.contains(where: limits.contains)
            || message.localizedCaseInsensitiveContains("limit exceeded")
            || message.localizedCaseInsensitiveContains("rate limit")
    }

    /// The token lacks a scope the request needs — fixed only by signing in again.
    var isScopeProblem: Bool {
        reasons.contains { $0 == "insufficientPermissions" || $0 == "ACCESS_TOKEN_SCOPE_INSUFFICIENT" }
            || message.localizedCaseInsensitiveContains("insufficient")
    }
}

private extension Data {
    /// Base64URL without padding, as required by PKCE.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Token Vault

/// Thread-safe in-memory cache for the short-lived OAuth access token.
///
/// Refreshes only when expired or within a 60-second safety cushion, and deduplicates
/// concurrent refresh calls so a chunk of requests never causes a token stampede.
private actor TokenVault {
    private var cachedToken: String?
    private var expiresAt: Date = .distantPast
    private var refreshTask: Task<String, Error>?
    /// Bumped by `clear()`. A refresh that was already in flight when the account
    /// was disconnected or switched must not land its token afterwards — that
    /// would send mail from the old account.
    private var generation = 0

    func getToken(refreshToken: String, clientID: String) async throws -> String {
        if let cachedToken, Date().addingTimeInterval(60) < expiresAt {
            return cachedToken
        }
        if let ongoing = refreshTask {
            return try await ongoing.value
        }
        let startedGeneration = generation
        let task = Task { () -> String in
            let requestedAt = Date()
            defer { finishRefresh(generation: startedGeneration) }
            let refreshed = try await Self.performRefresh(refreshToken: refreshToken, clientID: clientID)
            if generation == startedGeneration {
                cachedToken = refreshed.access_token
                expiresAt = requestedAt.addingTimeInterval(TimeInterval(refreshed.expires_in ?? 3600))
            }
            return refreshed.access_token
        }
        refreshTask = task
        return try await task.value
    }

    private func finishRefresh(generation finished: Int) {
        if generation == finished { refreshTask = nil }
    }

    func clear() {
        generation += 1
        cachedToken = nil
        expiresAt = .distantPast
        refreshTask = nil
    }

    private struct Refreshed: Decodable {
        let access_token: String
        let expires_in: Int?
    }

    private static func performRefresh(refreshToken: String, clientID: String) async throws -> Refreshed {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token")
        ]
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            // A dead refresh token is the common case here, and Google's raw
            // JSON for it means nothing to a person; it needs a reconnect.
            if body.contains("invalid_grant") { throw GmailAuthError.sessionExpired }
            throw GmailAuthError.server(GoogleError(data: data)?.message ?? "Couldn't refresh Google session.")
        }
        return try JSONDecoder().decode(Refreshed.self, from: data)
    }
}
