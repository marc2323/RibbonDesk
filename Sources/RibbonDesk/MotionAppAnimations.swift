import ApplicationServices

/// Confined to one application lane. Temporarily disable app-driven AX move
/// animation for a motion session, restoring the true value only after every
/// native write finishes, including cancellation and error paths.
/// Input handling itself never calls these synchronous cross-process APIs.
final class MotionAppAnimations: @unchecked Sendable {
    enum Read { case enabled(Bool), retry }
    private let read: (pid_t) -> Read
    private let write: (pid_t, Bool) -> Bool
    private var known: [pid_t: Bool] = [:]
    private var owed: Set<pid_t> = []

    init(read: @escaping (pid_t) -> Read = MotionAppAnimations.readNative,
         write: @escaping (pid_t, Bool) -> Bool = MotionAppAnimations.writeNative) {
        self.read = read; self.write = write
    }
    /// False means capability could not be read yet; retry on a later frame.
    /// Confirmed absence and an acquired lease are complete for this session.
    @discardableResult
    func prepare(_ pid: pid_t) -> Bool {
        guard !owed.contains(pid) else { return true }
        if known[pid] == nil {
            switch read(pid) {
            case let .enabled(value): known[pid] = value
            case .retry: return false
            }
        }
        guard known[pid] == true else { return true }
        // An AX setter can take effect and still report an error.
        owed.insert(pid)
        _ = write(pid, false)
        return true
    }
    func restore() {
        for pid in owed where write(pid, true) { owed.remove(pid) }
    }
    func reset() {
        restore()
        known = Dictionary(uniqueKeysWithValues: owed.map { ($0, true) })
    }
    private static func readNative(_ pid: pid_t) -> Read {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, "AXEnhancedUserInterface" as CFString, &value)
        if result == .attributeUnsupported || result == .noValue { return .enabled(false) }
        guard result == .success, let value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return .retry }
        return .enabled(CFEqual(value, kCFBooleanTrue))
    }
    private static func writeNative(_ pid: pid_t, _ enabled: Bool) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        return AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString,
                                          enabled ? kCFBooleanTrue : kCFBooleanFalse) == .success
    }
}
