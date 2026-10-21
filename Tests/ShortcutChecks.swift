import AppKit
import Carbon

private final class FixtureHotKeyBackend: HotKeyBackend {
    var receive: ((EventHotKeyID) -> OSStatus)?
    var installedReceivers: [(EventHotKeyID) -> OSStatus] = []
    var installStatus: OSStatus = noErr
    var failures: [UInt32: OSStatus] = [:]
    var active: Set<UInt32> = []
    var unregistered: [UInt32] = []
    var installCount = 0
    var uninstallCount = 0
    func install(_ receive: @escaping (EventHotKeyID) -> OSStatus) -> OSStatus {
        installCount += 1
        if installStatus == noErr { self.receive = receive; installedReceivers.append(receive) }
        return installStatus
    }
    func register(_ binding: ShortcutBinding, signature: OSType) -> OSStatus {
        if let status = failures[binding.id] { return status }
        active.insert(binding.id); return noErr
    }
    func unregister(_ id: UInt32) { active.remove(id); unregistered.append(id) }
    func uninstall() { uninstallCount += 1; receive = nil }
    @discardableResult func send(_ id: UInt32, signature: OSType = GlobalShortcuts.signature) -> OSStatus {
        receive?(EventHotKeyID(signature: signature, id: id)) ?? OSStatus(eventNotHandledErr)
    }
}

enum ShortcutChecks {
    static func run(_ expect: (Bool, String) -> Void) {
        let bindings = ShortcutBindings.all
        let ids = bindings.map(\.id)
        let combinations = bindings.map { "\($0.keyCode):\($0.modifiers)" }
        expect(Set(ids).count == ids.count && Set(combinations).count == combinations.count,
               "Shortcut IDs and physical combinations are unique")
        expect(ShortcutBindings.preferred(.focusLeft)?.keyCode == UInt32(kVK_ANSI_H) &&
               ShortcutBindings.preferred(.focusRight)?.keyCode == UInt32(kVK_ANSI_L),
               "H/L are the primary navigation keys")
        expect(ShortcutBindings.jumps.map(\.action.jumpIndex) == (0..<9).map(Optional.some),
               "Number keys select tiled windows instead of changing widths")
        expect(ShortcutBindings.preferred(.focusLeft)?.modifierMask == [.control, .option] &&
               ShortcutBindings.preferred(.moveRight)?.modifierMask == [.control, .option, .shift],
               "Menu modifier masks match registered Carbon modifiers")

        let backend = FixtureHotKeyBackend()
        let keys = GlobalShortcuts(backend: backend)
        var received: [DeskAction] = []
        keys.onAction = { received.append($0) }
        do { try keys.register() }
        catch { expect(false, "Fixture shortcuts register: \(error)"); return }
        expect(backend.active.count == bindings.count && keys.diagnostics.registeredCount == bindings.count,
               "All successful shortcut registrations are retained")
        let right = ShortcutBindings.preferred(.focusRight)!.id
        expect(backend.send(right) == noErr && received == [.focusRight],
               "A registered native hotkey ID dispatches its action once")
        expect(keys.diagnostics.receivedCount == 1 && keys.diagnostics.dispatchedCount == 1 &&
               keys.diagnostics.lastAction == .focusRight, "Delivery and dispatch have separate observable counters")
        expect(backend.send(right, signature: 1) == OSStatus(eventNotHandledErr) &&
               backend.send(UInt32.max) == OSStatus(eventNotHandledErr) && received.count == 1,
               "Foreign signatures and unknown hotkey IDs cannot dispatch")
        let staleReceiver = backend.installedReceivers[0]
        keys.unregister()
        expect(backend.active.isEmpty && keys.diagnostics.registeredCount == 0,
               "Unregister removes every hotkey reference and handler")
        expect(staleReceiver(EventHotKeyID(signature: GlobalShortcuts.signature, id: right)) == OSStatus(eventNotHandledErr)
               && received.count == 1, "A stale queued callback cannot dispatch after unregister")
        keys.unregister()
        expect(backend.unregistered.count == bindings.count, "Repeated unregister never releases a hotkey twice")

        // Rectangle commonly owns the arrow aliases. Keep working H/L usable.
        let arrows = bindings.filter { !$0.isPrimary && ($0.keyCode == UInt32(kVK_LeftArrow) || $0.keyCode == UInt32(kVK_RightArrow)) }
        for binding in arrows { backend.failures[binding.id] = OSStatus(eventHotKeyExistsErr) }
        do { try keys.register() }
        catch { expect(false, "Optional collisions permit a session: \(error)"); return }
        expect(keys.registrationWarnings.count == arrows.count && backend.active.count == bindings.count - arrows.count,
               "Optional shortcut conflicts are reported without discarding working keys")
        backend.send(right)
        expect(received.last == .focusRight && keys.diagnostics.dispatchedCount == 1,
               "Navigation still dispatches after optional arrow collisions")
        keys.unregister()

        for binding in bindings where binding.action == .focusLeft {
            backend.failures[binding.id] = OSStatus(eventHotKeyExistsErr)
        }
        var failed = false
        do { try keys.register() } catch { failed = true }
        expect(failed && backend.active.isEmpty && backend.receive == nil,
               "Missing an entire navigation direction rolls back partial registration")

        let installationFailure = FixtureHotKeyBackend(); installationFailure.installStatus = OSStatus(paramErr)
        let unavailable = GlobalShortcuts(backend: installationFailure)
        failed = false
        do { try unavailable.register() } catch { failed = true }
        expect(failed && installationFailure.active.isEmpty && installationFailure.receive == nil,
               "Handler installation failure leaves no active keys")

        let lifecycle = FixtureHotKeyBackend()
        var released: GlobalShortcuts? = GlobalShortcuts(backend: lifecycle)
        do { try released?.register() } catch { expect(false, "Lifecycle fixture registers") }
        released = nil
        expect(lifecycle.active.isEmpty && lifecycle.receive == nil,
               "Deinitialization removes registrations even without an explicit stop")
    }
}
