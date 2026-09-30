import SwiftUI

/// Shown after the first Gmail sign-in: collect the profile details used to fill
/// mail templates, then save them to the database before entering the app.
struct OnboardingView: View {
    @Environment(ProfileStore.self) private var store

    var body: some View {
        @Bindable var store = store

        NavigationStack {
            PaperForm {
                Section {
                    Text("Tell us about yourself. This fills in your mail templates and is saved to your account.")
                        .font(.subheadline)
                        .foregroundStyle(.inkMuted)
                }

                ProfileFields(profile: $store.profile)

                Section {
                    Button {
                        Haptics.press()
                        Task {
                            // The one gate into the app: worth saying plainly
                            // which way it went before the screen changes.
                            if await store.save() { Haptics.success() } else { Haptics.failure() }
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if store.isSaving {
                                ProgressView().tint(.white)
                            } else {
                                Text("Continue").fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(store.profile.name.trimmingCharacters(in: .whitespaces).isEmpty || store.isSaving)
                }
            }
            .navigationTitle("Set Up Profile")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
            .messageAlert("Couldn't save profile", message: store.errorMessage) {
                store.clearError()
            }
        }
    }
}

/// The shared profile fields, reused by onboarding and the Profile tab.
///
/// Read-only mode names each value rather than showing a disabled `TextField`,
/// which renders the value with its label gone — leaving the Profile tab as a
/// list of bare strings with nothing to say what any of them were.
struct ProfileFields: View {
    @Binding var profile: Profile
    var isEditing = true

    var body: some View {
        Section("About") {
            if isEditing {
                TextField("Name", text: $profile.name)
            } else {
                LabeledContent("Name", value: profile.name.isEmpty ? "Not set" : profile.name)
            }
        }

        Section("Education") {
            if isEditing {
                Toggle("Currently studying?", isOn: $profile.isStudying)
                if profile.isStudying {
                    TextField("College", text: $profile.college)
                }
            } else if profile.isStudying {
                LabeledContent("College", value: profile.college.isEmpty ? "Not set" : profile.college)
            } else {
                Text("Not currently studying").foregroundStyle(.inkMuted)
            }
        }

        Section("Work") {
            if isEditing {
                Toggle("Currently working?", isOn: $profile.isWorking)
                if profile.isWorking {
                    TextField("Company", text: $profile.company)
                    TextField("Position", text: $profile.position)
                }
            } else if profile.isWorking {
                LabeledContent("Company", value: profile.company.isEmpty ? "Not set" : profile.company)
                LabeledContent("Position", value: profile.position.isEmpty ? "Not set" : profile.position)
            } else {
                Text("Not currently working").foregroundStyle(.inkMuted)
            }
        }

        Section {
            if isEditing {
                TextField("Google Drive Link", text: $profile.resumeLink)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            } else if profile.resumeLink.isEmpty {
                Text("No resume link").foregroundStyle(.inkMuted)
            } else if let url = URL(string: profile.resumeLink), url.scheme?.hasPrefix("http") == true {
                // A link, as it is in Contacts: tap to check it's the right
                // file, hold to copy it.
                Link(destination: url) {
                    LabeledContent {
                        HStack(spacing: 4) {
                            Text(url.host() ?? profile.resumeLink)
                                .lineLimit(1)
                            Image(systemName: "arrow.up.forward")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(.clay)
                    } label: {
                        Text("Link").foregroundStyle(.ink)
                    }
                }
                .contextMenu {
                    Button("Copy Link", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = profile.resumeLink
                    }
                }
            } else {
                LabeledContent("Link", value: profile.resumeLink)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Resume")
        } footer: {
            // Templates can reference {Resume-Link}; an unset one renders as a gap
            // in every mail that does, which is invisible from the mail itself.
            if !isEditing && profile.resumeLink.isEmpty {
                Text("Templates using {Resume-Link} will send with a blank space here.")
            }
        }
    }
}
