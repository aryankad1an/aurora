import Foundation

extension Task where Success == Never, Failure == Never {
    /// Wait out a pause in typing. Meant for work driven by `.task(id:)`, which
    /// cancels the previous run on every keystroke: only the run that survives
    /// the pause gets `true` and goes on to hit the network.
    static func debounce(_ duration: Duration) async -> Bool {
        try? await sleep(for: duration)
        return !isCancelled
    }
}
