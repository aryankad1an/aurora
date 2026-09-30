import SwiftUI

/// A noun with singular/plural forms, so selection UI copy reads correctly
/// ("1 company" vs "3 companies") without each screen hand-rolling the grammar.
struct SelectionNoun {
    let singular: String
    let plural: String

    func phrase(_ count: Int) -> String { count == 1 ? singular : plural }
}

extension View {
    /// The standard multi-select chrome shared by every list screen, laid out the
    /// way the system's own apps (Photos, Files, Mail) lay out theirs:
    ///
    /// - the tab bar steps aside and the **bottom toolbar** takes its place,
    ///   carrying the bulk actions and the count — native toolbar items, so
    ///   they get the same rounded Liquid Glass, grouping and motion as the tab
    ///   bar they replace;
    /// - the navigation bar swaps to **Select All** on the leading side and
    ///   **Done** on the trailing side, hiding the back button meanwhile;
    /// - destructive bulk actions confirm in an alert.
    ///
    /// Screens therefore draw no selection chrome of their own: they show their
    /// normal toolbar items only while `selection.isSelecting` is false.
    ///
    /// It used to be a hand-built glass bar in `safeAreaInset`, with a
    /// card-radius corner rather than the capsule the tab bar has, floating
    /// *above* the tab bar instead of replacing it, and animated by hand.
    ///
    /// - Parameter all: every row "Select All" should tick — the rows on screen,
    ///   after search.
    /// - Parameter deleteMessage: overrides the default warning copy for lists
    ///   whose delete cascades (e.g. removing a company drops its mails too).
    /// - Parameter onSend: when provided, a Send button appears in the toolbar
    ///   (used by lists whose items can be mailed).
    /// - Parameter confirmsDelete: when false, Delete runs `onDelete` immediately
    ///   with no alert — for reversible removals that offer an Undo instead.
    /// - Parameter deletableCount: how many of the selection can actually be
    ///   deleted, when that differs from the count (some rows are protected).
    ///   Drives the confirmation copy so it never promises more than it will do.
    /// - Parameter sendableCount: how many of the selection can actually be
    ///   mailed, when that differs from the count (invalid contacts can't).
    /// - Parameter bulkAction: the screen's own constructive bulk action, with its
    ///   own label so one slot can read "Track"/"Untrack" or "Mark Invalid"/"Mark
    ///   Valid" depending on what's selected.
    func selectionActions<ID: Hashable>(
        _ selection: ListSelection<ID>,
        all: [ID],
        noun: SelectionNoun,
        confirmingDelete: Binding<Bool> = .constant(false),
        deleteMessage: String? = nil,
        confirmsDelete: Bool = true,
        deletableCount: Int? = nil,
        sendableCount: Int? = nil,
        onSend: (() -> Void)? = nil,
        bulkAction: SelectionBulkAction? = nil,
        onDelete: (() -> Void)? = nil
    ) -> some View {
        modifier(SelectionActions(
            selection: selection,
            all: all,
            noun: noun,
            confirmingDelete: confirmingDelete,
            deleteMessage: deleteMessage,
            confirmsDelete: confirmsDelete,
            deletableCount: deletableCount,
            sendableCount: sendableCount,
            onSend: onSend,
            bulkAction: bulkAction,
            onDelete: onDelete
        ))
    }
}

/// A labelled bulk action for the selection toolbar, so one slot can present
/// itself as "Track"/"Untrack" or "Mark Invalid"/"Mark Valid" depending on
/// what's selected. `tint` colours it when the action carries a meaning of its
/// own — orange for ruling contacts out, green for putting them back.
struct SelectionBulkAction {
    let title: String
    let systemImage: String
    var tint: Color? = nil
    let action: () -> Void
}

/// Whether a list is in selection mode right now, for chrome that lives above
/// the screens. `RootView` reads it to put the send queue's shelf away: with the
/// tab bar gone, the shelf drops into its place and covers the selection toolbar.
@Observable
final class SelectionChrome {
    var isSelecting = false
}

private struct SelectionActions<ID: Hashable>: ViewModifier {
    @Environment(SelectionChrome.self) private var chrome: SelectionChrome?
    let selection: ListSelection<ID>
    let all: [ID]
    let noun: SelectionNoun
    @Binding var confirmingDelete: Bool
    let deleteMessage: String?
    let confirmsDelete: Bool
    let deletableCount: Int?
    let sendableCount: Int?
    let onSend: (() -> Void)?
    let bulkAction: SelectionBulkAction?
    let onDelete: (() -> Void)?

    private var isSelecting: Bool { selection.isSelecting }
    private var count: Int { selection.count }

    /// What the delete will really remove.
    private var effectiveDeleteCount: Int { deletableCount ?? count }

    /// How many of the selection can actually be mailed.
    private var effectiveSendCount: Int { sendableCount ?? count }

    private var isAllSelected: Bool {
        !all.isEmpty && all.allSatisfy(selection.contains)
    }

    private var deleteTitle: String {
        let deletable = effectiveDeleteCount
        guard let deletableCount, deletableCount != count else {
            return "Delete \(deletable) \(noun.phrase(deletable))?"
        }
        return "Delete \(deletableCount) of \(count) \(noun.phrase(count))?"
    }

    func body(content: Content) -> some View {
        content
            // Selection mode owns the bottom edge, as it does in Photos: the tab
            // bar leaves and the toolbar that acts on the selection arrives in
            // its place, instead of a second bar stacked on top of it.
            //
            // `.automatic`, not `.visible`, when not selecting: a list's
            // `.visible` outranks the `.hidden` of a screen pushed on top of it,
            // so a company opened from Home or Companies kept its tab bar over
            // the selection toolbar.
            .toolbar(isSelecting ? .hidden : .automatic, for: .tabBar)
            .navigationBarBackButtonHidden(isSelecting)
            .onChange(of: isSelecting) { _, selecting in chrome?.isSelecting = selecting }
            // A screen that leaves mid-selection mustn't keep the shelf away.
            .onDisappear { if isSelecting { chrome?.isSelecting = false } }
            .toolbar {
                if isSelecting {
                    navigationItems
                    bottomItems
                }
            }
            // Every tick and untick of a row is a detent, felt through the count
            // rather than through each row separately.
            .sensoryFeedback(.selection, trigger: count)
            .uniformDeleteAlert(
                title: deleteTitle,
                message: deleteMessage ?? "Are you sure you want to permanently delete the selected \(noun.plural)? This action cannot be undone.",
                isPresented: $confirmingDelete,
                onDelete: { onDelete?() }
            )
    }

    @ToolbarContentBuilder
    private var navigationItems: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(isAllSelected ? "Deselect All" : "Select All") {
                withAnimation(Theme.Motion.snappy) {
                    if isAllSelected {
                        selection.ids.subtract(all)
                    } else {
                        selection.ids.formUnion(all)
                    }
                }
            }
            .disabled(all.isEmpty)
        }
        ToolbarItem(placement: .topBarTrailing) {
            DoneButton { selection.exit() }
        }
    }

    /// Bulk action on the leading edge, the count in the middle, Send and Delete
    /// trailing — the system groups adjacent items into one glass capsule, the
    /// way Photos pairs Share and Delete.
    @ToolbarContentBuilder
    private var bottomItems: some ToolbarContent {
        if let bulkAction {
            ToolbarItem(placement: .bottomBar) {
                Button(action: bulkAction.action) {
                    Label(bulkAction.title, systemImage: bulkAction.systemImage)
                        .labelStyle(.titleAndIcon)
                }
                .tint(bulkAction.tint ?? .clay)
                .disabled(count == 0)
            }
        }

        BottomBarStatus(text: count == 0
                        ? "Select \(noun.plural.capitalized)"
                        : "\(count) \(noun.phrase(count).capitalized)")

        if let onSend {
            ToolbarItem(placement: .bottomBar) {
                Button {
                    Haptics.press()
                    onSend()
                } label: {
                    Label("Send", systemImage: "paperplane")
                }
                .disabled(count == 0 || effectiveSendCount == 0)
            }
        }
        if let onDelete {
            ToolbarItem(placement: .bottomBar) {
                Button(role: .destructive) {
                    if confirmsDelete {
                        Haptics.warning()
                        confirmingDelete = true
                    } else {
                        Haptics.thud()
                        onDelete()
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.danger)
                .disabled(count == 0 || effectiveDeleteCount == 0)
            }
        }
    }
}

/// A line of status in the middle of the bottom toolbar — "3 Companies",
/// "Select Contacts" — set as plain text between flexible spaces, with no glass
/// of its own, the way Photos shows "3 Photos Selected". Shared by the selection
/// toolbar and Quick Actions' send toolbar.
struct BottomBarStatus: ToolbarContent {
    let text: String

    var body: some ToolbarContent {
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.ink)
                .lineLimit(1)
                .contentTransition(.numericText())
                .animation(Theme.Motion.snappy, value: text)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.flexible, placement: .bottomBar)
    }
}
