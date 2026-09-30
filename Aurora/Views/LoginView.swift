import SwiftUI

/// The splash / sign-in screen. The app is gated behind a Gmail connection —
/// everything (companies, sent state, profile) is keyed to the signed-in address.
struct LoginView: View {
    @Environment(GmailAuthStore.self) private var gmail

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "paperplane.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
                // The one piece of idle motion in the app, and only here: the
                // sign-in screen has nothing else on it, and a mark that breathes
                // says the app is running before anything has been tapped.
                .symbolEffect(.bounce.up.byLayer, options: .repeat(.periodic(delay: 2.4)))
                .scaleEffect(gmail.isConnecting ? 0.92 : 1)
                .animation(Theme.Motion.bouncy, value: gmail.isConnecting)

            VStack(spacing: 8) {
                Text("Aurora")
                    .font(.display(38, weight: .bold))
                    .foregroundStyle(.ink)
                Text("Track and send mails from your Gmail.")
                    .font(.subheadline)
                    .foregroundStyle(.inkMuted)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            Button {
                Haptics.press()
                Task { await gmail.connect() }
            } label: {
                HStack(spacing: 8) {
                    if gmail.isConnecting {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "envelope.badge")
                    }
                    Text(gmail.isConnecting ? "Connecting…" : "Sign in with Gmail")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .primaryButton()
            .controlSize(.large)
            .disabled(gmail.isConnecting)

            Text("You need to sign in to continue.")
                .font(.footnote)
                .foregroundStyle(.inkMuted)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .paperScreen()
        // Connecting hands off to a Google sheet and comes back minutes later in
        // the worst case, so the outcome is announced rather than only shown.
        .sensoryFeedback(trigger: gmail.errorMessage != nil) { _, failed in
            failed ? .error : nil
        }
        .sensoryFeedback(trigger: gmail.isConnected) { _, connected in
            connected ? .success : nil
        }
        .messageAlert("Couldn't connect Gmail", message: gmail.errorMessage) {
            gmail.errorMessage = nil
        }
    }
}
