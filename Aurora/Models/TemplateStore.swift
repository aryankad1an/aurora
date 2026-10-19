import Foundation
import Observation

/// The user's mail templates, stored in Supabase keyed by their Gmail address,
/// so they load on any device after signing in. A change shows at once and is
/// written in the background, put back if the database refuses it — it used to
/// write, refetch, and hold the whole app behind a "Saving…" veil meanwhile.
@Observable
final class TemplateStore {
    private(set) var templates: [MailTemplate] = []
    private(set) var isLoading = false
    var errorMessage: String?

    func clearError() { errorMessage = nil }

    private var email: String?

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
        let previous = templates.first { $0.id == template.id }
        put(template)
        do {
            try await SupabaseAPI.upsertTemplate(userEmail: email, template: template)
        } catch {
            // Only this template goes back: restoring the whole list as it was would
            // also undo any other change made while this one was on its way.
            if let previous { put(previous) } else { templates.removeAll { $0.id == template.id } }
            errorMessage = error.localizedDescription
        }
    }

    /// Delete templates in one request; they leave the list at once.
    func delete(_ doomed: [MailTemplate]) async {
        guard email != nil, !doomed.isEmpty else { return }
        let ids = Set(doomed.map(\.id))
        templates.removeAll { ids.contains($0.id) }
        do {
            try await SupabaseAPI.deleteTemplates(ids: doomed.map(\.id))
        } catch {
            for template in doomed { put(template) }
            errorMessage = error.localizedDescription
        }
    }

    /// Insert or replace a template, keeping the list in name order.
    private func put(_ template: MailTemplate) {
        if let index = templates.firstIndex(where: { $0.id == template.id }) {
            templates[index] = template
        } else {
            templates.append(template)
        }
        templates.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Save a copy under a new id, named so it's clearly the copy.
    func duplicate(_ template: MailTemplate) async {
        await save(MailTemplate(name: template.name + " copy", subject: template.subject,
                                content: template.content))
    }
}
