import SwiftUI

extension View {
    /// The app's confirmation: a centred alert with Cancel and one other button.
    /// Used in place of `confirmationDialog`, which on iPhone floats as a
    /// popover with no Cancel, pointing at whatever view it happened to be
    /// attached to rather than at the button that asked.
    ///
    /// - Parameter role: `.destructive` for anything that throws something away;
    ///   nil for a step that's merely final (sending mail).
    func confirmAlert(
        _ title: String,
        message: String,
        confirmLabel: String,
        role: ButtonRole? = nil,
        isPresented: Binding<Bool>,
        onConfirm: @escaping () -> Void
    ) -> some View {
        alert(title, isPresented: isPresented) {
            Button("Cancel", role: .cancel) {}
            Button(confirmLabel, role: role, action: onConfirm)
        } message: {
            Text(message)
        }
    }

    /// The confirmation every delete in the app asks with.
    /// - Parameter confirmLabel: the destructive button's title, for actions that
    ///   destroy something without being called "delete" (a merge).
    func uniformDeleteAlert(
        title: String,
        message: String,
        confirmLabel: String = "Delete",
        isPresented: Binding<Bool>,
        onDelete: @escaping () -> Void
    ) -> some View {
        confirmAlert(title, message: message, confirmLabel: confirmLabel, role: .destructive,
                     isPresented: isPresented, onConfirm: onDelete)
    }
}

extension View {
    /// The same alert, driven by the item it's about: shown while `item` is set,
    /// and `item` is cleared however it's dismissed.
    func uniformDeleteAlert<Item>(
        item: Binding<Item?>,
        title: (Item) -> String,
        message: String,
        confirmLabel: String = "Delete",
        onDelete: @escaping (Item) -> Void
    ) -> some View {
        uniformDeleteAlert(
            title: item.wrappedValue.map(title) ?? "",
            message: message,
            confirmLabel: confirmLabel,
            isPresented: Binding(get: { item.wrappedValue != nil },
                                 set: { if !$0 { item.wrappedValue = nil } })
        ) {
            if let value = item.wrappedValue { onDelete(value) }
            item.wrappedValue = nil
        }
    }
}

extension View {
    /// An OK-only alert that's up while `message` is set — a failure or a result
    /// to report. `onDismiss` clears the message.
    func messageAlert(_ title: String, message: String?, onDismiss: @escaping () -> Void) -> some View {
        alert(title, isPresented: Binding(get: { message != nil }, set: { if !$0 { onDismiss() } })) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(message ?? "")
        }
    }
}

/// Contacts about to be ruled in or out, waiting on the user's say-so. Validity
/// lives on the shared contact row, so the change lands for every user.
struct ValidityChange: Identifiable {
    let id = UUID()
    let ids: [Contact.ID]
    /// The one name to put in the title when there's a single contact.
    let name: String?
    let isValid: Bool

    init(_ contacts: [Contact], isValid: Bool) {
        ids = contacts.map(\.id)
        name = contacts.count == 1 ? contacts.first?.displayName : nil
        self.isValid = isValid
    }

    var title: String {
        let who = name.map { "“\($0)”" } ?? "\(ids.count) contacts"
        return isValid ? "Mark \(who) valid?" : "Mark \(who) invalid?"
    }

    var message: String {
        let they = ids.count == 1 ? "They" : "These contacts"
        return isValid
            ? "\(they) go back into Suggested and can be mailed again — for every user."
            : "\(they) drop out of Suggested and can't be mailed — for every user. Sent mail is kept, and you can mark them valid again later."
    }
}

extension View {
    /// Asks before ruling contacts in or out — every screen that offers Mark
    /// Invalid or Mark Valid routes it through here, so none of them can change
    /// the shared catalog on a single tap (or a full swipe).
    ///
    /// `perform` runs only on confirm, and does the write; the haptic for the
    /// act itself is played here, so it lands on the decision rather than on the
    /// tap that asked.
    func validityAlert(_ change: Binding<ValidityChange?>,
                       perform: @escaping (ValidityChange) -> Void) -> some View {
        alert(change.wrappedValue?.title ?? "",
              isPresented: Binding(get: { change.wrappedValue != nil },
                                   set: { if !$0 { change.wrappedValue = nil } }),
              presenting: change.wrappedValue) { pending in
            Button("Cancel", role: .cancel) {}
            Button(pending.isValid ? "Mark Valid" : "Mark Invalid",
                   role: pending.isValid ? nil : .destructive) {
                if pending.isValid { Haptics.success() } else { Haptics.thud() }
                perform(pending)
            }
        } message: { pending in
            Text(pending.message)
        }
    }
}

extension View {
    /// The Cancel of a sheet that edits something. With nothing changed it
    /// closes at once; with changes it asks before throwing them away — as
    /// Calendar, Reminders and Contacts do — and the sheet can't be swiped
    /// down with unsaved work in it. Every editing sheet in the app uses this
    /// instead of a bare Cancel, which lost a half-written template or a
    /// hand-edited batch of mails to one mistaken tap.
    func discardableEdits(_ hasChanges: Bool, message: String = "Your changes won't be saved.") -> some View {
        modifier(DiscardableEdits(hasChanges: hasChanges, message: message))
    }
}

private struct DiscardableEdits: ViewModifier {
    let hasChanges: Bool
    let message: String
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasChanges {
                            Haptics.warning()
                            confirming = true
                        } else {
                            dismiss()
                        }
                    }
                }
            }
            .interactiveDismissDisabled(hasChanges)
            .alert("Discard your changes?", isPresented: $confirming) {
                Button("Keep Editing", role: .cancel) {}
                Button("Discard Changes", role: .destructive) { dismiss() }
            } message: {
                Text(message)
            }
    }
}
