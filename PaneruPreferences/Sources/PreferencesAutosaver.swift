import Foundation

/// Applies the latest settings in order, coalescing rapid input without
/// cancelling a file write, login registration, or layout refresh in progress.
@MainActor
final class PreferencesAutosaver {
    private(set) var applied: Preferences
    private var desired: Preferences
    private var worker: Task<Void, Never>?
    private let interval: UInt64
    private let apply: (Preferences, Preferences) async throws -> Void
    var onBusy: () -> Void = {}
    var onStart: (Preferences, Preferences) -> Void = { _, _ in }
    var onApplied: (Preferences, Preferences) -> Void = { _, _ in }
    var onFailure: (Error, Preferences, Bool) -> Void = { _, _, _ in }
    var onIdle: () -> Void = {}

    init(initial: Preferences, interval: UInt64 = 80_000_000,
         apply: @escaping (Preferences, Preferences) async throws -> Void) {
        applied = initial
        desired = initial
        self.interval = interval
        self.apply = apply
    }

    var isBusy: Bool { worker != nil }

    func replaceApplied(_ value: Preferences) {
        precondition(!isBusy)
        applied = value
        desired = value
    }

    func submit(_ value: Preferences) {
        desired = value
        guard worker == nil, desired != applied else { return }
        onBusy()
        worker = Task { await drain() }
    }

    func waitUntilIdle() async { await worker?.value }

    private func drain() async {
        while desired != applied {
            // Throttle instead of waiting for a drag to stop: even a continuous
            // slider/color-picker movement gets periodic live updates.
            try? await Task.sleep(nanoseconds: interval)
            let next = desired, previous = applied
            if next == previous { break }
            onStart(next, previous)
            do {
                try await apply(next, previous)
                applied = next
                onApplied(next, previous)
            } catch {
                let hasNewerEdit = desired != next
                if !hasNewerEdit { desired = applied }
                onFailure(error, applied, hasNewerEdit)
            }
        }
        worker = nil
        onIdle()
    }
}
