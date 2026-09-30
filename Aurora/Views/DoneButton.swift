import SwiftUI

/// The "Done" that leaves a multi-select mode.
///
/// A plain toolbar button: the toolbar already gives every item its own glass,
/// so a second `glassEffect` inside it was glass on glass — two panes to render
/// and morph whenever the bar swapped between this and the `⋯` menu.
struct DoneButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Done").fontWeight(.semibold)
        }
        .accessibilityHint("Leaves selection")
    }
}
