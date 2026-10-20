import Foundation

/// This account's sign-in to the database.
///
/// Requests used to go out under the app's publishable key alone, which ships
/// in the app, so the server couldn't tell one account from another and anyone
/// holding the key could overwrite any row. Now each request carries a
/// Supabase session made from the account's Google sign-in: the server knows
/// whose request it is, and its row rules (`scripts/rls_migration.sql`) let an
/// account change only its own rows.
///
/// Until Google sign-in is turned on in the Supabase project the session can't
/// be made, and requests go out under the publishable key as before — so this
/// build works against the database both before that migration and after it.
actor DatabaseSession {
    static let shared = DatabaseSession()

    private var accessToken: String?
    private var expiresAt = Date.distantPast
    private var renewal: Task<String?, Never>?
    /// After a failed sign-in, when to try again. A project without Google
    /// sign-in would otherwise be asked on every request.
    private var retryAfter = Date.distantPast
    /// Bumped by `signIn` and `signOut`: a renewal still in flight for the
    /// previous account must not land its session afterwards.
    private var generation = 0

    private static let refreshKey = "supabase.refreshToken"
    private static let retryDelay: TimeInterval = 60

    /// What to send as the bearer: the account's session, renewed when it's
    /// close to expiring, or the publishable key when there's none to be had.
    func bearer() async -> String {
        await sessionToken() ?? AppConfig.supabaseAnonKey
    }

    /// Sign in with the ID token Google returned at connect.
    func signIn(idToken: String) async {
        generation += 1
        let started = generation
        renewal = nil
        do {
            let session = try await Self.token(grant: "id_token", body: ["provider": "google", "id_token": idToken])
            guard generation == started else { return }
            store(session)
        } catch {
            guard generation == started else { return }
            failed()
        }
    }

    /// Forget the session: the account was disconnected.
    func signOut() {
        generation += 1
        renewal = nil
        accessToken = nil
        expiresAt = .distantPast
        retryAfter = .distantPast
        Keychain.set(nil, for: Self.refreshKey)
    }

    /// The server turned `token` away (expired early, or revoked): renew it on
    /// the next request.
    func invalidate(_ token: String) {
        guard token == accessToken else { return }
        accessToken = nil
        expiresAt = .distantPast
    }

    private func sessionToken() async -> String? {
        if let accessToken, Date.now.addingTimeInterval(60) < expiresAt { return accessToken }
        if let renewal { return await renewal.value }
        guard Date.now >= retryAfter else { return nil }
        let started = generation
        let task = Task { await renew(generation: started) }
        renewal = task
        let token = await task.value
        if generation == started { renewal = nil }
        return token
    }

    /// The stored refresh token first; failing that, a fresh Google ID token,
    /// which every refresh of the Google sign-in comes with.
    private func renew(generation started: Int) async -> String? {
        var session: Session?
        if let refresh = Keychain.get(Self.refreshKey) {
            do {
                session = try await Self.token(grant: "refresh_token", body: ["refresh_token": refresh])
            } catch SessionError.refused {
                // Used up or revoked: only a new sign-in makes another.
                if generation == started { Keychain.set(nil, for: Self.refreshKey) }
            } catch {}
        }
        if session == nil, let idToken = try? await GmailAuthStore.freshIDToken() {
            session = try? await Self.token(grant: "id_token", body: ["provider": "google", "id_token": idToken])
        }
        guard generation == started else { return nil }
        guard let session else {
            failed()
            return nil
        }
        store(session)
        return session.accessToken
    }

    private func store(_ session: Session) {
        accessToken = session.accessToken
        expiresAt = .now.addingTimeInterval(TimeInterval(session.expiresIn ?? 3600))
        retryAfter = .distantPast
        if let refresh = session.refreshToken { Keychain.set(refresh, for: Self.refreshKey) }
    }

    private func failed() {
        accessToken = nil
        expiresAt = .distantPast
        retryAfter = .now.addingTimeInterval(Self.retryDelay)
    }

    // MARK: - Supabase Auth

    private struct Session: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    private enum SessionError: Error {
        /// The server answered and said no: a bad or used token, or Google
        /// sign-in not turned on for the project.
        case refused
    }

    private static func token(grant: String, body: [String: String]) async throws -> Session {
        var request = URLRequest(url: URL(string: "\(AppConfig.supabaseURL)/auth/v1/token?grant_type=\(grant)")!)
        request.httpMethod = "POST"
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw URLError(.badServerResponse) }
        guard status == 200 else {
            // A 4xx is an answer; anything else is worth asking again.
            throw (400..<500).contains(status) ? SessionError.refused : URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Session.self, from: data)
    }
}
