import SwiftUI

/// The Profile tab: personal details (read-only until you tap the pencil),
/// plus the Gmail connection.
struct ProfileView: View {
    @Environment(ProfileStore.self) private var store
    @Environment(JobStore.self) private var jobStore
    @Environment(GmailAuthStore.self) private var gmail
    @Environment(ReplySync.self) private var replySync

    @State private var isEditing = false
    @State private var draft = Profile()
    @State private var isReconnecting = false
    @State private var confirmingSignOut = false

    var body: some View {
        NavigationStack {
            PaperForm {
                if !isEditing { header }

                // Editable only in edit mode; otherwise a read-only snapshot.
                ProfileFields(profile: isEditing ? $draft : .constant(store.profile),
                              isEditing: isEditing)

                if gmail.isConnected { gmailSection }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.large)
            // The pencil is the bar's verb, and in edit mode the same slot is
            // Save — the ✎ morphs into the ✓ where the thumb already is, and a ✕
            // arrives on the leading edge to back out.
            .topBarActions(
                isEditing
                    ? TopBarPrimary(title: "Save", systemImage: "checkmark",
                                    isProminent: true, isBusy: store.isSaving) { save() }
                    : TopBarPrimary(title: "Edit Profile", systemImage: "pencil") {
                        withAnimation(Theme.Motion.liquid) {
                            draft = store.profile         // start from the current profile
                            isEditing = true
                        }
                    },
                // Cancel discards the draft — but not one already being written.
                onCancel: isEditing ? { if !store.isSaving { isEditing = false } } : nil
            ) {
                if replySync.needsReconnect {
                    Button { reconnect() } label: {
                        Label("Reconnect Gmail", systemImage: "arrow.trianglehead.clockwise")
                    }
                    .disabled(isReconnecting)
                    Divider()
                }
                Button(role: .destructive) { confirmingSignOut = true } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
            // Signing out drops the Gmail connection, and getting it back means
            // the whole Google sign-in again — so it asks, as Settings does.
            .confirmAlert("Sign out of Gmail?",
                          message: "You'll need to sign in again to send or track mail. Nothing you've saved is deleted.",
                          confirmLabel: "Sign Out", role: .destructive,
                          isPresented: $confirmingSignOut) { signOut() }
        }
    }

    /// Who's signed in, at the top — the way Settings opens on your account.
    private var header: some View {
        let name = store.profile.name.trimmingCharacters(in: .whitespaces)
        let role = store.profile.isWorking && !store.profile.position.isEmpty
            ? [store.profile.position, store.profile.company].filter { !$0.isEmpty }.joined(separator: " at ")
            : (store.profile.isStudying && !store.profile.college.isEmpty ? "Student at \(store.profile.college)" : nil)
        return Section {
            HStack(spacing: 14) {
                MonogramAvatar(text: name.isEmpty ? (gmail.connectedEmail ?? "?") : name, size: 60)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name.isEmpty ? "Add your name" : name)
                        .font(.display(22))
                        .foregroundStyle(name.isEmpty ? Color.inkMuted : Color.ink)
                        .lineLimit(1)
                    if let email = gmail.connectedEmail {
                        Text(email)
                            .font(.subheadline)
                            .foregroundStyle(.inkMuted)
                            .lineLimit(1)
                    }
                    if let role {
                        Text(role)
                            .font(.caption)
                            .foregroundStyle(.inkFaint)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// The connected account, plus the one repair this app can need: a token
    /// minted before reply tracking existed has no permission to read mail, and
    /// only a fresh consent can grant it. Reconnecting keeps the same account and
    /// the same data — it just re-runs the Google sheet.
    @ViewBuilder
    private var gmailSection: some View {
        Section {
            LabeledContent("Account", value: gmail.connectedEmail ?? "")

            if replySync.needsReconnect {
                Label {
                    Text("Gmail needs you to sign in again — the sign-in expired, or predates reply tracking.")
                        .font(.footnote)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.statusInvalid)
                }

                Button { reconnect() } label: {
                    if isReconnecting {
                        ProgressView()
                    } else {
                        Label("Reconnect Gmail", systemImage: "arrow.trianglehead.clockwise")
                    }
                }
                .disabled(isReconnecting)
            }

            Button("Sign Out", role: .destructive) { confirmingSignOut = true }
        } header: {
            Label("Gmail", systemImage: "envelope.fill")
        } footer: {
            Text(replySync.needsReconnect
                 ? "Reconnecting signs in to the same account again. Nothing is deleted."
                 : "Used to send your mails and to check which ones were answered.")
        }
    }

    /// Only leave edit mode once the write actually lands. A failed save used to
    /// exit anyway, leaving the screen showing the edited values it had already
    /// written locally — so a lost edit looked identical to a saved one until the
    /// next load quietly restored the old profile.
    private func save() {
        Task {
            let previous = store.profile
            store.profile = draft
            if await store.save() {
                Haptics.success()
                withAnimation(Theme.Motion.bouncy) { isEditing = false }
            } else {
                // The alert says what went wrong; the buzz says *that* something
                // did, while the user is still looking at the fields they typed.
                Haptics.failure()
                store.profile = previous
            }
        }
    }

    private func reconnect() {
        Haptics.press()
        isReconnecting = true
        Task {
            await gmail.connect()
            isReconnecting = false
            // Check straight away with the new sign-in, which also clears the
            // warning above rather than leaving it until the next sync.
            if gmail.errorMessage == nil {
                await jobStore.syncReplies(using: replySync, forceFullCheck: true)
            }
        }
    }

    private func signOut() {
        Haptics.press()
        UndoCoordinator.shared.dismiss()
        store.reset()
        jobStore.userEmail = nil
        gmail.disconnect()
    }

}

#Preview {
    ProfileView()
        .environment(ProfileStore())
        .environment(JobStore())
        .environment(GmailAuthStore())
        .environment(ReplySync())
}
