import SwiftUI

/// The splash / sign-in screen. The app is gated behind a Gmail connection —
/// everything (companies, sent state, profile) is keyed to the signed-in address.
struct LoginView: View {
    @Environment(GmailAuthStore.self) private var gmail
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // The mark, on a raised tile like the app icon's.
            AuroraMark(accent: .clay, bead: .ink, line: .inkFaint)
                .padding(12)
                .frame(width: 88, height: 88)
                .background(Color.paperRaised, in: .rect(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.hairline, lineWidth: 1))
                // The one piece of idle motion in the app, and only here: the
                // sign-in screen has nothing else on it, and a mark that breathes
                // says the app is running before anything has been tapped.
                .phaseAnimator(reduceMotion ? [false] : [false, true]) { mark, lifted in
                    mark.scaleEffect(lifted ? 1.03 : 1)
                } animation: { _ in .easeInOut(duration: 2.4) }
                .scaleEffect(gmail.isConnecting ? 0.92 : 1)
                .animation(Theme.Motion.bouncy, value: gmail.isConnecting)
                .accessibilityHidden(true)

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
        // Grain on the ground, under the controls, like the splash before it.
        .background { FilmGrain().ignoresSafeArea() }
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
