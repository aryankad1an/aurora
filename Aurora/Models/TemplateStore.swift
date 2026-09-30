import Foundation
import Observation

/// The user's mail templates, stored in Supabase keyed by their Gmail address,
/// so they load on any device after signing in. Every change writes through and
/// then refetches, so on-screen state always mirrors the database.
@Observable
final class TemplateStore {
    private(set) var templates: [MailTemplate] = []
    private(set) var isLoading = false
    var errorMessage: String?

    func clearError() { errorMessage = nil }

    private var email: String?

    private var inFlight = 0
    /// True while a write and its confirming reload are in progress. Drives the
    /// app-wide "Saving…" overlay (see `RootView`) so a template isn't treated
    /// as saved until it's actually round-tripped to the database.
    var isSaving: Bool { inFlight > 0 }

    /// Load this user's templates from the database.
    func load(email: String) async {
        self.email = email
        isLoading = true
        defer { isLoading = false }
        do {
            templates = try await SupabaseAPI.fetchTemplates(userEmail: email)
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }

    /// Re-fetch this user's templates from the database — pull-to-refresh, so
    /// templates saved from another of the user's devices show up here too.
    func refresh() async {
        guard let email else { return }
        await load(email: email)
    }

    /// Create or update a template (both are an upsert on its id).
    func save(_ template: MailTemplate) async {
        guard let email else { return }
        inFlight += 1
        defer { inFlight -= 1 }
        do {
            try await SupabaseAPI.upsertTemplate(userEmail: email, template: template)
            templates = try await SupabaseAPI.fetchTemplates(userEmail: email)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Delete templates in one request and one refetch.
    func delete(_ doomed: [MailTemplate]) async {
        guard let email, !doomed.isEmpty else { return }
        inFlight += 1
        defer { inFlight -= 1 }
        do {
            try await SupabaseAPI.deleteTemplates(ids: doomed.map(\.id))
            templates = try await SupabaseAPI.fetchTemplates(userEmail: email)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Save a copy under a new id, named so it's clearly the copy.
    func duplicate(_ template: MailTemplate) async {
        await save(MailTemplate(name: template.name + " copy", subject: template.subject,
                                content: template.content))
    }
}
