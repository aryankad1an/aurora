import Foundation

/// App-wide configuration values.
enum AppConfig {
    /// Your Supabase project URL, e.g. https://abcdxyz.supabase.co
    static let supabaseURL = "https://imiampamznvfdebbcoxk.supabase.co"

    /// Your Supabase **anon public** API key (safe to ship in the app; it's
    /// protected by Row Level Security policies on the database).
    static let supabaseAnonKey = "sb_publishable_T1Tx7-gPZ6R8H4jf5VcQUA_fvOVr9hR"

    // MARK: - Google (Gmail) OAuth

    /// iOS OAuth client ID. Not a secret — iOS clients ship it and use PKCE
    /// instead of a client secret.
    static let googleClientID = "893359004595-r6vvkbkonur3qmkv17nupi6na9t49749.apps.googleusercontent.com"

    /// The reversed client ID, used as the redirect URL scheme. Google
    /// auto-accepts this redirect for iOS clients, so no console setup is needed.
    static let googleRedirectScheme = "com.googleusercontent.apps.893359004595-r6vvkbkonur3qmkv17nupi6na9t49749"

    /// Full redirect URI handed to Google and matched on the callback.
    static var googleRedirectURI: String { "\(googleRedirectScheme):/oauth2redirect" }

    /// Requested scopes: identify the account (openid/email), send mail on the
    /// user's behalf, and read it back.
    ///
    /// `gmail.readonly` is what reply tracking runs on — it needs the `q` search
    /// parameter (to find a send's thread) and the message headers in a thread (to
    /// see who answered), and the narrower `gmail.metadata` scope allows neither.
    /// It's a restricted scope, so a published app needs Google's verification;
    /// while the OAuth consent screen is in Testing it works for the listed test
    /// users as-is. Adding it invalidates existing consent: reconnect Gmail from
    /// Profile once after updating, or Gmail reads fail with a 403.
    static let googleScopes = """
        openid email \
        https://www.googleapis.com/auth/gmail.send \
        https://www.googleapis.com/auth/gmail.readonly
        """
}
