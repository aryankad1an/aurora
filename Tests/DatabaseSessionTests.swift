import Foundation

// The database session: signing in with Google's ID token, renewing with the
// refresh token, falling back to the publishable key when Supabase won't sign
// the account in, and not asking again on every request while it won't. Runs
// against a fake Supabase Auth, with the Keychain and Google stubbed out.
//
//   swiftc -parse-as-library -default-isolation MainActor \
//     Aurora/Models/DatabaseSession.swift Tests/DatabaseSessionTests.swift \
//     -o /tmp/ds && /tmp/ds

nonisolated enum AppConfig {
    static let supabaseURL = "https://project.example.supabase.co"
    static let supabaseAnonKey = "sb_publishable_test"
}

/// In memory, so the test never touches the real Keychain.
nonisolated enum Keychain {
    nonisolated(unsafe) static var items: [String: String] = [:]
    static func set(_ value: String?, for key: String) { items[key] = value }
    static func get(_ key: String) -> String? { items[key] }
}

final class GmailAuthStore {
    /// What Google hands back on a refresh: an ID token, or nil when signed out.
    nonisolated(unsafe) static var idToken: String? = "google-id-1"
    nonisolated(unsafe) static var refreshes = 0
    nonisolated static func freshIDToken() async throws -> String? {
        refreshes += 1
        guard let idToken else { throw URLError(.userAuthenticationRequired) }
        return idToken
    }
}

/// Supabase Auth's token endpoint, scripted.
final class FakeAuth: URLProtocol {
    nonisolated(unsafe) static var calls: [(grant: String, body: [String: String])] = []
    /// When false, every grant is refused the way a project without Google
    /// sign-in refuses it.
    nonisolated(unsafe) static var googleEnabled = true
    nonisolated(unsafe) static var expiresIn = 3600
    nonisolated(unsafe) static var issued = 0
    nonisolated(unsafe) static var validRefresh: Set<String> = []

    override class func canInit(with request: URLRequest) -> Bool { request.url?.path == "/auth/v1/token" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let grant = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            .queryItems!.first { $0.name == "grant_type" }!.value!
        let data = request.httpBodyStream.map { stream -> Data in
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: 4096); if n <= 0 { break }; data.append(buffer, count: n) }
            return data
        } ?? request.httpBody ?? Data()
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] ?? [:]
        Self.calls.append((grant, body))
        let accepted: Bool
        switch grant {
        case "id_token": accepted = Self.googleEnabled && body["provider"] == "google" && body["id_token"] != nil
        case "refresh_token": accepted = Self.validRefresh.remove(body["refresh_token"] ?? "") != nil
        default: accepted = false
        }
        let status: Int
        let json: [String: Any]
        if accepted {
            Self.issued += 1
            let refresh = "refresh-\(Self.issued)"
            Self.validRefresh.insert(refresh)
            status = 200
            json = ["access_token": "jwt-\(Self.issued)", "refresh_token": refresh, "expires_in": Self.expiresIn]
        } else {
            status = 400
            json = ["error_code": "provider_disabled", "msg": "Unsupported provider: provider is not enabled"]
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                                               headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: json))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@main
struct DatabaseSessionTests {
    nonisolated(unsafe) static var failures = 0

    static func expect<T: Equatable>(_ got: T, _ want: T, _ label: String) {
        if got == want { print("  ✓ \(label)") } else { failures += 1; print("  ✗ \(label): got \(got), want \(want)") }
    }

    static func reset() {
        FakeAuth.calls = []; FakeAuth.googleEnabled = true; FakeAuth.expiresIn = 3600
        FakeAuth.validRefresh = []; Keychain.items = [:]
        GmailAuthStore.idToken = "google-id-1"; GmailAuthStore.refreshes = 0
    }

    static func main() async {
        URLProtocol.registerClass(FakeAuth.self)

        print("Signing in")
        reset()
        var session = DatabaseSession()
        await session.signIn(idToken: "google-at-connect")
        expect(await session.bearer(), "jwt-\(FakeAuth.issued)", "connect's ID token makes a session")
        expect(FakeAuth.calls.map(\.grant), ["id_token"], "one sign-in, and the session is reused")
        expect(Keychain.items["supabase.refreshToken"] != nil, true, "its refresh token is kept")

        print("An existing install (no session yet)")
        reset()
        session = DatabaseSession()
        let tokens = await withTaskGroup(of: String.self) { group in
            for _ in 0..<5 { group.addTask { await session.bearer() } }
            return await group.reduce(into: [String]()) { $0.append($1) }
        }
        expect(Set(tokens), ["jwt-\(FakeAuth.issued)"], "five requests at once all go out signed in")
        expect(FakeAuth.calls.count, 1, "with one sign-in between them")
        expect(GmailAuthStore.refreshes, 1, "from one Google refresh")
        expect(FakeAuth.calls.first?.body["id_token"], "google-id-1", "using the ID token the refresh brought")

        print("Renewing")
        reset()
        FakeAuth.expiresIn = 30   // inside the minute's margin: due at once
        session = DatabaseSession()
        _ = await session.bearer()
        let renewed = await session.bearer()
        expect(FakeAuth.calls.map(\.grant), ["id_token", "refresh_token"], "a session about to expire is renewed by its refresh token")
        expect(renewed, "jwt-\(FakeAuth.issued)", "and the new one is used")
        expect(GmailAuthStore.refreshes, 1, "without asking Google again")
        FakeAuth.validRefresh = []   // revoked on the server
        _ = await session.bearer()
        expect(FakeAuth.calls.suffix(2).map(\.grant), ["refresh_token", "id_token"], "a refused refresh token falls back to Google")
        expect(Keychain.items["supabase.refreshToken"], "refresh-\(FakeAuth.issued)", "and the dead one is replaced")

        print("Expired early")
        reset()
        session = DatabaseSession()
        let first = await session.bearer()
        await session.invalidate("someone-else's")
        expect(await session.bearer(), first, "invalidating another token changes nothing")
        await session.invalidate(first)
        let second = await session.bearer()
        expect(second != first, true, "invalidating this one renews it")

        print("Google sign-in not turned on in Supabase")
        reset()
        FakeAuth.googleEnabled = false
        session = DatabaseSession()
        expect(await session.bearer(), AppConfig.supabaseAnonKey, "requests fall back to the publishable key")
        for _ in 0..<10 { _ = await session.bearer() }
        expect(FakeAuth.calls.count, 1, "and Supabase isn't asked again on every request")
        await session.signIn(idToken: "google-at-connect")
        expect(await session.bearer(), AppConfig.supabaseAnonKey, "a refused sign-in at connect falls back too")

        print("Signing out")
        reset()
        session = DatabaseSession()
        _ = await session.bearer()
        await session.signOut()
        GmailAuthStore.idToken = nil
        expect(Keychain.items["supabase.refreshToken"] == nil, true, "the refresh token is forgotten")
        expect(await session.bearer(), AppConfig.supabaseAnonKey, "and nothing goes out as the old account")

        print(failures == 0 ? "All passed" : "\(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
