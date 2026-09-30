import Foundation
import SwiftUI

/// A single pending undo action.
struct UndoItem: Identifiable {
    let id = UUID()
    let message: String
    let revertAction: () async -> Void
}

/// A centralized coordinator that manages 5-second undo intervals for user edits.
/// Displays a uniform confirmation message with an active countdown and executes
/// upstream reverts if the user requests undo before expiration.
///
/// One slot: staging a new edit replaces the previous one, the way the system's
/// own undo toasts behave.
@MainActor
@Observable
final class UndoCoordinator {
    static let shared = UndoCoordinator()

    private(set) var activeItem: UndoItem?
    /// Whole seconds left, for the countdown pill. Ticked once a second rather
    /// than continuously: the pill only ever shows whole seconds, and a finer
    /// tick re-rendered every screen observing this twenty times a second.
    private(set) var secondsRemaining = 0

    private var countdownTask: Task<Void, Never>?

    /// Stage an edit for undo with a specific duration (default 5 seconds).
    func stage(message: String, duration: Int = 5, revert: @escaping () async -> Void) {
        countdownTask?.cancel()
        let item = UndoItem(message: message, revertAction: revert)
        activeItem = item
        secondsRemaining = duration

        countdownTask = Task { [weak self] in
            for remaining in stride(from: duration - 1, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.secondsRemaining = remaining
            }
            guard let self, self.activeItem?.id == item.id else { return }
            self.activeItem = nil
        }
    }

    /// Trigger the undo action: reverts changes locally and upstream.
    func undo() async {
        countdownTask?.cancel()
        guard let item = activeItem else { return }
        activeItem = nil
        secondsRemaining = 0
        Haptics.tap()
        await item.revertAction()
    }

    /// Explicitly dismiss the undo banner without reverting.
    func dismiss() {
        countdownTask?.cancel()
        activeItem = nil
        secondsRemaining = 0
    }
}
