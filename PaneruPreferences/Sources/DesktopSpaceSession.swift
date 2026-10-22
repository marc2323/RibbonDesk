// Decides whether the companion should run its engine as desktops change.
// Manual pauses remain distinct from pauses caused by a desktop exclusion.
struct DesktopSpaceSession {
    private(set) var requested = true
    private var initialized = false
    private var suspended = false
    private var explicit = false

    mutating func request(_ enabled: Bool) {
        requested = enabled
        explicit = true
    }

    mutating func policyChanged() { explicit = true }

    mutating func shouldRun(running: Bool, excluded: Bool) -> Bool {
        if initialized && !suspended && !running && !explicit { requested = false }
        explicit = false
        suspended = excluded
        initialized = true
        return requested && !excluded
    }
}
