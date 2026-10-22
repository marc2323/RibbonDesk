import AppKit
import ApplicationServices
import os

/// In Click mode, an inactive application window must be activated before it
/// receives a click or ordinary scrolling. Paneru continues to own strip gestures.
final class ActivationClickGuard {
    var shouldHandlePoint: (CGPoint) -> Bool = { _ in true }
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var swallowedButtons = Set<Int64>()
    private let systemWide = AXUIElementCreateSystemWide()
    private let diagnostics = UserDefaults.standard.bool(forKey: "ClickGuardDiagnostics")
    private let logger = Logger(subsystem: "local.paneru.preferences", category: "ClickGuard")

    static var isAuthorized: Bool { AXIsProcessTrusted() }

    static func requestAuthorization() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func configure(for mode: FocusMode) throws {
        guard mode == .click else { stop(); return }
        guard Self.isAuthorized else {
            throw CommandFailure(message: "Allow Accessibility for Paneru Settings to use Click mode.")
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: true); return }

        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                   .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                                   .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        // Keep Accessibility lookups within the event-tap watchdog deadline.
        AXUIElementSetMessagingTimeout(systemWide, 0.04)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                         options: .defaultTap, eventsOfInterest: mask,
                                         callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let guardObject = Unmanaged<ActivationClickGuard>.fromOpaque(context).takeUnretainedValue()
            return guardObject.handle(type, event: event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            throw CommandFailure(message: "Click protection could not start. Check Accessibility for Paneru Settings.")
        }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        swallowedButtons.removeAll()
    }

    deinit { stop() }

    private func handle(_ type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            swallowedButtons.removeAll()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        switch type {
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            if swallowedButtons.remove(button) != nil { return nil }
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            if swallowedButtons.contains(button) { return nil }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            guard shouldHandlePoint(event.location) else { return Unmanaged.passUnretained(event) }
            let target = inactiveWindow(at: event.location)
            if diagnostics { logger.notice("Mouse down received; activation required: \(target != nil, privacy: .public)") }
            if let target {
                swallowedButtons.insert(button)
                // Consume the complete activation click, including its mouse-up.
                // AX activation runs after the tap returns so apps cannot stall it.
                DispatchQueue.main.async { self.activate(target.window, pid: target.pid) }
                return nil
            }
        case .scrollWheel:
            guard shouldHandlePoint(event.location) else { return Unmanaged.passUnretained(event) }
            // Inactive windows cannot receive accidental two-finger scrolling.
            // Three-finger strip gestures are intercepted upstream by Paneru.
            if inactiveWindow(at: event.location) != nil { return nil }
        default: break
        }
        return Unmanaged.passUnretained(event)
    }

    private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func windowAttribute(_ name: String, of element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(name, of: element), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func inactiveWindow(at point: CGPoint) -> (window: AXUIElement, pid: pid_t)? {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element) == .success,
              let element else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.04)
        let window: AXUIElement
        if let owner = windowAttribute(kAXWindowAttribute, of: element) { window = owner }
        else if attribute(kAXRoleAttribute, of: element) as? String == kAXWindowRole { window = element }
        else { return nil }
        AXUIElementSetMessagingTimeout(window, 0.04)
        guard attribute(kAXRoleAttribute, of: window) as? String == kAXWindowRole else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success, pid != getpid() else { return nil }
        // Menus, desktop, and system UI retain their normal behavior.
        guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else { return nil }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid { return (window, pid) }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.04)
        guard let focused = windowAttribute(kAXFocusedWindowAttribute, of: application) else { return nil }
        return CFEqual(focused, window) ? nil : (window, pid)
    }

    private func activate(_ window: AXUIElement, pid: pid_t) {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.1)
        AXUIElementSetMessagingTimeout(window, 0.1)
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        AXUIElementSetAttributeValue(application, kAXFocusedWindowAttribute as CFString, window)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }
}
