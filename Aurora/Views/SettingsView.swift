import SwiftUI

/// The Settings tab: who you are (with Edit Profile), how the app looks, and
/// the Gmail connection.
///
/// It replaced the Profile tab, which was a read-only copy of the onboarding
/// form with a pencil on it. The profile is still one tap away — the bar's
/// verb, and the button under your name — but the tab now holds the things you
/// set rather than a page you read.
struct SettingsView: View {
    @Environment(ProfileStore.self) private var store
    @Environment(JobStore.self) private var jobStore
    @Environment(GmailAuthStore.self) private var gmail
    @Environment(ReplySync.self) private var replySync

    @State private var isEditingProfile = false
    @State private var isReconnecting = false
    @State private var confirmingSignOut = false

    private enum Route: Hashable { case theme }

    var body: some View {
        NavigationStack {
            PaperForm {
                accountSection
                appearanceSection
                if gmail.isConnected { gmailSection }
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: Route.self) { _ in ThemePickerView() }
            .topBarActions(
                TopBarPrimary(title: "Edit Profile", systemImage: "pencil") { isEditingProfile = true }
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
            .sheet(isPresented: $isEditingProfile) {
                EditProfileSheet(profile: store.profile)
            }
            // Signing out drops the Gmail connection, and getting it back means
            // the whole Google sign-in again — so it asks, as Settings does.
            .confirmAlert("Sign out of Gmail?",
                          message: "You'll need to sign in again to send or track mail. Nothing you've saved is deleted.",
                          confirmLabel: "Sign Out", role: .destructive,
                          isPresented: $confirmingSignOut) { signOut() }
        }
    }

    // MARK: - Account

    /// Who's signed in, at the top — the way Settings opens on your account.
    private var accountSection: some View {
        let profile = store.profile
        let name = profile.name.trimmingCharacters(in: .whitespaces)
        let role = profile.isWorking && !profile.position.isEmpty
            ? [profile.position, profile.company].filter { !$0.isEmpty }.joined(separator: " at ")
            : (profile.isStudying && !profile.college.isEmpty ? "Student at \(profile.college)" : nil)
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

            Button {
                Haptics.tap()
                isEditingProfile = true
            } label: {
                Label("Edit Profile", systemImage: "person.text.rectangle")
            }
        } footer: {
            if profile.resumeLink.isEmpty {
                Text("Add your resume link in Edit Profile — templates using {Resume-Link} send with a blank space until you do.")
            }
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        let theme = ThemeStore.shared.current
        return Section {
            NavigationLink(value: Route.theme) {
                HStack(spacing: 12) {
                    Image(theme.iconPreview)
                        .resizable()
                        .frame(width: 34, height: 34)
                        .clipShape(.rect(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Theme")
                            .foregroundStyle(.ink)
                        Text(theme.name)
                            .font(.caption)
                            .foregroundStyle(.inkMuted)
                            .contentTransition(.opacity)
                    }
                    Spacer(minLength: 8)
                    ThemeSwatches(palette: theme.palette)
                }
            }
        } header: {
            Text("Appearance")
        } footer: {
            Text("Changes the colours, the chart behind every screen, the launch screen and the app icon.")
        }
    }

    // MARK: - Gmail

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

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: Self.version)
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    // MARK: - Actions

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

// MARK: - Edit Profile

/// The profile, as a sheet: the same fields onboarding asks for, with Cancel
/// (asking first if anything changed) and Save.
private struct EditProfileSheet: View {
    @Environment(ProfileStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private let original: Profile
    @State private var draft: Profile

    init(profile: Profile) {
        original = profile
        _draft = State(initialValue: profile)
    }

    var body: some View {
        NavigationStack {
            PaperForm {
                ProfileFields(profile: $draft)
            }
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .discardableEdits(draft != original)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if store.isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { save() }
                            .fontWeight(.semibold)
                            .disabled(draft == original)
                    }
                }
            }
        }
    }

    /// Only close once the write actually lands. A failed save keeps the sheet
    /// open on the values typed, with the alert saying why, rather than closing
    /// on a profile that was never stored.
    private func save() {
        Task {
            store.profile = draft
            if await store.save() {
                Haptics.success()
                dismiss()
            } else {
                Haptics.failure()
                store.profile = original
            }
        }
    }
}

/// A theme's four working colours, as dots: accent, reply, waiting, attention.
struct ThemeSwatches: View {
    let palette: ThemePalette
    var size: CGFloat = 10

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(Array([palette.accent, palette.reply, palette.waiting, palette.attention].enumerated()),
                    id: \.offset) { _, color in
                Circle()
                    .fill(color)
                    .frame(width: size, height: size)
                    .overlay(Circle().strokeBorder(palette.paper, lineWidth: 1.5))
            }
        }
        .accessibilityHidden(true)
    }
}
