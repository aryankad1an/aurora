import ActivityKit
import SwiftUI
import UIKit

/// Writing help through the user's own "Aurora Writer" shortcut, the app's only
/// source of written text. Shortcuts' Use Model action does the writing: the
/// app hands the request to the shortcut with an x-callback-url, Shortcuts runs
/// it and opens `aurora://writing/<id>/done?result=…` with the answer, and
/// `RootView` passes that link to `receive(_:)`.
///
/// While the app is behind Shortcuts the Dynamic Island shows it's still writing
/// (`WritingActivityAttributes`). If the user comes back to Aurora and nothing
/// was sent back, the request is given up as `.noReply`.
@MainActor
final class ShortcutsWriter {
    static let shared = ShortcutsWriter()

    /// The shortcut's name, which the user has to match exactly.
    nonisolated static let shortcutName = "Aurora Writer"
    /// Whether writing help goes to the shortcut, in UserDefaults.
    static let enabledKey = "writing.viaShortcuts"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Opens Shortcuts on a new, empty shortcut, for setting it up.
    static let newShortcutURL = URL(string: "shortcuts://create-shortcut")!

    nonisolated enum Failure: Error, Equatable {
        /// The user stopped the shortcut in Shortcuts.
        case cancelled
        /// The shortcut stopped with an error, in Shortcuts' words if it gave any.
        case failed(String?)
        /// The user came back without the shortcut sending an answer: it isn't
        /// there, isn't named right, or doesn't end with Stop and Output.
        case noReply
        /// Shortcuts couldn't be opened.
        case unavailable

        var message: String {
            switch self {
            case .cancelled:
                "The \(ShortcutsWriter.shortcutName) shortcut was stopped."
            case .failed(let reason?):
                "The \(ShortcutsWriter.shortcutName) shortcut stopped: \(reason)"
            case .failed(nil):
                "The \(ShortcutsWriter.shortcutName) shortcut stopped with an error."
            case .noReply:
                "The \(ShortcutsWriter.shortcutName) shortcut didn't send an answer back. Check it's named exactly that and ends with Stop and Output."
            case .unavailable:
                "Couldn't open Shortcuts."
            }
        }
    }

    private var pending: (id: UUID, continuation: CheckedContinuation<String, any Error>)?
    private var observers: [any NSObjectProtocol] = []
    /// Whether the app has gone behind Shortcuts since the request went out.
    private var leftApp = false

    /// How long after coming back to Aurora the answer may still arrive: the
    /// callback link can land just after the app is active again.
    private static let grace: Duration = .seconds(2.5)
    /// How long a request may be out at all.
    private static let timeout: Duration = .seconds(180)

    /// Hand `prompt` to the shortcut and wait for its answer. `title` is what was
    /// asked, for the Dynamic Island. Throws a `Failure`, or `CancellationError`
    /// when the task is cancelled.
    func ask(_ prompt: String, title: String) async throws -> String {
        resume(pending?.id, with: .failure(CancellationError()))
        let id = UUID()
        guard let url = Self.runURL(prompt, id: id) else { throw Failure.unavailable }
        let activity = startActivity(title)
        defer { end(activity) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = (id, continuation)
                watch(id)
                Task {
                    if await !UIApplication.shared.open(url) { resume(id, with: .failure(Failure.unavailable)) }
                }
            }
        } onCancel: {
            Task { @MainActor in self.resume(id, with: .failure(CancellationError())) }
        }
    }

    /// A callback from Shortcuts: `aurora://writing/<id>/done?result=…`, `…/error?errorMessage=…`
    /// or `…/cancel`. Links for a request that's no longer waiting are ignored.
    func receive(_ url: URL) {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, let id = UUID(uuidString: parts[0]), id == pending?.id else { return }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            query.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        switch parts[1] {
        case "done":
            if let result = value("result") {
                resume(id, with: .success(result))
            } else {
                resume(id, with: .failure(Failure.noReply))
            }
        case "cancel":
            resume(id, with: .failure(Failure.cancelled))
        case "error":
            resume(id, with: .failure(Failure.failed(value("errorMessage"))))
        default:
            break
        }
    }

    private func resume(_ id: UUID?, with result: Result<String, any Error>) {
        guard let id, let pending, pending.id == id else { return }
        self.pending = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        pending.continuation.resume(with: result)
    }

    /// Give the request up when the user comes back from Shortcuts without an
    /// answer, or when it's been out too long.
    private func watch(_ id: UUID) {
        leftApp = false
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.leftApp = true }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    guard self.leftApp else { return }
                    Task {
                        try? await Task.sleep(for: Self.grace)
                        self.resume(id, with: .failure(Failure.noReply))
                    }
                }
            },
        ]
        Task {
            try? await Task.sleep(for: Self.timeout)
            resume(id, with: .failure(Failure.noReply))
        }
    }

    /// `shortcuts://x-callback-url/run-shortcut?name=Aurora%20Writer&input=text&text=…`
    /// with callbacks that carry the request's id. Built by hand: URLComponents
    /// leaves `&`, `+` and `=` in a value as they are, which would cut the prompt.
    private static func runURL(_ prompt: String, id: UUID) -> URL? {
        let callback = "aurora://writing/\(id.uuidString)/"
        let fields = [
            ("name", shortcutName),
            ("input", "text"),
            ("text", prompt),
            ("x-success", callback + "done"),
            ("x-cancel", callback + "cancel"),
            ("x-error", callback + "error"),
        ]
        let query = fields.compactMap { name, value in
            value.addingPercentEncoding(withAllowedCharacters: unreserved).map { "\(name)=\($0)" }
        }
        guard query.count == fields.count else { return nil }
        return URL(string: "shortcuts://x-callback-url/run-shortcut?" + query.joined(separator: "&"))
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    // MARK: - Dynamic Island

    private func startActivity(_ title: String) -> Activity<WritingActivityAttributes>? {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return nil }
        // Any left up: by a request this one replaced, or a launch closed mid-request.
        for leftover in Activity<WritingActivityAttributes>.activities {
            Task { await leftover.end(nil, dismissalPolicy: .immediate) }
        }
        let attributes = WritingActivityAttributes(accent: SendLiveActivity.rgb(Palette.clay))
        let state = WritingActivityAttributes.ContentState(request: title, startedAt: .now)
        return try? Activity.request(attributes: attributes, content: .init(state: state, staleDate: nil),
                                     pushType: nil)
    }

    private func end(_ activity: Activity<WritingActivityAttributes>?) {
        guard let activity else { return }
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
