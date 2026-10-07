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

/// The shared profile fields, used by onboarding and by Edit Profile in
/// Settings.
struct ProfileFields: View {
    @Binding var profile: Profile

    var body: some View {
        Section("About") {
            TextField("Name", text: $profile.name)
        }

        Section("Education") {
            Toggle("Currently studying?", isOn: $profile.isStudying)
            if profile.isStudying {
                TextField("College", text: $profile.college)
            }
        }

        Section("Work") {
            Toggle("Currently working?", isOn: $profile.isWorking)
            if profile.isWorking {
                TextField("Company", text: $profile.company)
                TextField("Position", text: $profile.position)
            }
        }

        Section {
            TextField("Google Drive Link", text: $profile.resumeLink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
        } header: {
            Text("Resume")
        } footer: {
            // Templates can reference {Resume-Link}; an unset one renders as a
            // gap in every mail that does, which is invisible from the mail.
            if profile.resumeLink.isEmpty {
                Text("Templates using {Resume-Link} send with a blank space until this is filled in.")
            }
        }
    }
}
