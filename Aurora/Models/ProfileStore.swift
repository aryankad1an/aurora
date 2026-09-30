import Foundation
import Observation

/// Holds the user's profile, stored in Supabase keyed by their Gmail address.
/// Loaded on sign-in; saved explicitly (onboarding, or the Profile tab's Save).
@Observable
final class ProfileStore {
    var profile = Profile()

    private(set) var email: String?
    private(set) var isSaving = false
    /// False until the first load finishes, so the UI can show a splash instead
    /// of briefly flashing the onboarding screen.
    private(set) var loaded = false
    /// True once a profile row exists for this user (onboarding complete).
    private(set) var hasProfile = false
    var errorMessage: String?

    func clearError() { errorMessage = nil }

    /// Load the profile for `email`. `hasProfile` reflects whether a row exists.
    func load(email: String) async {
        self.email = email
        defer { loaded = true }
        do {
            if let fetched = try await SupabaseAPI.fetchProfile(email: email) {
                profile = fetched
                hasProfile = true
            } else {
                profile = Profile()
                hasProfile = false
            }
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }

    /// Save the current profile to the database.
    ///
    /// - Returns: whether the write landed. Callers need this: leaving edit mode
    ///   on a failed save makes a lost edit look like a successful one.
    @discardableResult
    func save() async -> Bool {
        guard let email else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            try await SupabaseAPI.upsertProfile(email: email, profile: profile)
            hasProfile = true
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Clear on sign-out so the next user starts fresh.
    func reset() {
        email = nil
        profile = Profile()
        hasProfile = false
        loaded = false
    }
}
