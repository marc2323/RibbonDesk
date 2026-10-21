import AppKit
import Carbon

enum DeskAction: UInt32, CaseIterable {
    // Preserve existing values for menu tags and integrations.
    case focusLeft = 1, focusRight, moveLeft, moveRight, narrow, medium, wide, full, float, pause
    case first, last, cycleWidth, jump1, jump2, jump3, jump4, jump5, jump6, jump7, jump8, jump9
    var jumpIndex: Int? {
        guard rawValue >= Self.jump1.rawValue, rawValue <= Self.jump9.rawValue else { return nil }
        return Int(rawValue - Self.jump1.rawValue)
    }
}

struct ShortcutBinding: Identifiable, Equatable {
    let id: UInt32
    let action: DeskAction
    let keyCode: UInt32
    let keyEquivalent: String
    let modifiers: UInt32
    let title: String
    let keyLabel: String
    let isPrimary: Bool
    var modifierMask: NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { result.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { result.insert(.option) }
        if modifiers & UInt32(cmdKey) != 0 { result.insert(.command) }
        if modifiers & UInt32(shiftKey) != 0 { result.insert(.shift) }
        return result
    }
    var display: String {
        (modifiers & UInt32(controlKey) != 0 ? "⌃" : "") +
        (modifiers & UInt32(optionKey) != 0 ? "⌥" : "") +
        (modifiers & UInt32(shiftKey) != 0 ? "⇧" : "") +
        (modifiers & UInt32(cmdKey) != 0 ? "⌘" : "") + keyLabel
    }
}

/// Registration, menu equivalents, and help share this catalog.
enum ShortcutBindings {
    private static let base = UInt32(controlKey | optionKey)
    static let all: [ShortcutBinding] = {
        var result: [ShortcutBinding] = []
        func add(_ action: DeskAction, _ key: Int, _ equivalent: String, _ label: String,
                 _ title: String, extra: UInt32 = 0, primary: Bool = true) {
            result.append(ShortcutBinding(id: UInt32(result.count + 1), action: action,
                keyCode: UInt32(key), keyEquivalent: equivalent, modifiers: base | extra,
                title: title, keyLabel: label, isPrimary: primary))
        }
        add(.focusLeft, kVK_ANSI_H, "h", "H", "Focus Previous Window")
        add(.focusRight, kVK_ANSI_L, "l", "L", "Focus Next Window")
        add(.moveLeft, kVK_ANSI_H, "h", "H", "Move Window Left", extra: UInt32(shiftKey))
        add(.moveRight, kVK_ANSI_L, "l", "L", "Move Window Right", extra: UInt32(shiftKey))
        let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        let right = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        add(.first, kVK_LeftArrow, left, "←", "Focus First Window", extra: UInt32(cmdKey))
        add(.last, kVK_RightArrow, right, "→", "Focus Last Window", extra: UInt32(cmdKey))
        let numbers = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                       kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (index, key) in numbers.enumerated() {
            let action = DeskAction(rawValue: DeskAction.jump1.rawValue + UInt32(index))!
            add(action, key, String(index + 1), String(index + 1), "Focus Window \(index + 1)")
        }
        add(.cycleWidth, kVK_ANSI_R, "r", "R", "Cycle Half / Full Width")
        add(.full, kVK_ANSI_F, "f", "F", "Width: Full")
        add(.float, kVK_ANSI_T, "t", "T", "Float Focused Window")
        add(.pause, kVK_ANSI_Q, "q", "Q", "Pause / Restore")
        // Optional arrows may already belong to Rectangle or another utility.
        add(.focusLeft, kVK_LeftArrow, left, "←", "Focus Previous Window", primary: false)
        add(.focusRight, kVK_RightArrow, right, "→", "Focus Next Window", primary: false)
        add(.moveLeft, kVK_LeftArrow, left, "←", "Move Window Left", extra: UInt32(shiftKey), primary: false)
        add(.moveRight, kVK_RightArrow, right, "→", "Move Window Right", extra: UInt32(shiftKey), primary: false)
        // Preserve established width, floating, pause, and reorder shortcuts.
        add(.medium, kVK_ANSI_2, "2", "2", "Width: Half", extra: UInt32(cmdKey), primary: false)
        add(.full, kVK_ANSI_0, "0", "0", "Width: Full", extra: UInt32(cmdKey), primary: false)
        add(.float, kVK_ANSI_F, "f", "F", "Float Focused Window", extra: UInt32(cmdKey), primary: false)
        add(.pause, kVK_ANSI_P, "p", "P", "Pause / Restore", extra: UInt32(cmdKey), primary: false)
        add(.moveLeft, kVK_LeftArrow, left, "←", "Move Window Left", extra: UInt32(cmdKey | shiftKey), primary: false)
        add(.moveRight, kVK_RightArrow, right, "→", "Move Window Right", extra: UInt32(cmdKey | shiftKey), primary: false)
        return result
    }()
    static var menu: [ShortcutBinding] {
        all.filter { ($0.isPrimary && $0.action.jumpIndex == nil) || $0.action == .medium }
    }
    static var jumps: [ShortcutBinding] { all.filter { $0.isPrimary && $0.action.jumpIndex != nil } }
    static func preferred(_ action: DeskAction) -> ShortcutBinding? {
        all.first { $0.action == action && $0.isPrimary } ?? all.first { $0.action == action }
    }
    static func help(_ action: DeskAction) -> String { preferred(action)?.display ?? "" }
}

struct ShortcutDiagnostics {
    var registeredCount = 0
    var receivedCount = 0
    var dispatchedCount = 0
    var lastAction: DeskAction?
    var summary: String {
        "\(registeredCount) shortcuts ready · \(receivedCount) received · \(dispatchedCount) dispatched"
    }
}

/// Carbon hot keys avoid keyboard event taps and Input Monitoring permission.
/// Register and dispatch on the application's main event loop.
protocol ShortcutHandling: AnyObject {
    var onAction: ((DeskAction) -> Void)? { get set }
    var registrationWarnings: [String] { get }
    var diagnostics: ShortcutDiagnostics { get }
    func register() throws
    func unregister()
}
extension ShortcutHandling {
    var registrationWarnings: [String] { [] }
    var diagnostics: ShortcutDiagnostics { ShortcutDiagnostics() }
}

/// Injected to check lifecycle and collisions without posting OS input or
/// taking over the user's keyboard shortcuts.
protocol HotKeyBackend: AnyObject {
    func install(_ receive: @escaping (EventHotKeyID) -> OSStatus) -> OSStatus
    func register(_ binding: ShortcutBinding, signature: OSType) -> OSStatus
    func unregister(_ id: UInt32)
    func uninstall()
}

final class CarbonHotKeyBackend: HotKeyBackend {
    private var references: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private var receive: ((EventHotKeyID) -> OSStatus)?
    func install(_ receive: @escaping (EventHotKeyID) -> OSStatus) -> OSStatus {
        self.receive = receive
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var hotKey = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            guard status == noErr else { return status }
            let owner = Unmanaged<CarbonHotKeyBackend>.fromOpaque(context).takeUnretainedValue()
            return owner.receive?(hotKey) ?? OSStatus(eventNotHandledErr)
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr, handler != nil else {
            self.receive = nil
            return status == noErr ? OSStatus(paramErr) : status
        }
        return noErr
    }
    func register(_ binding: ShortcutBinding, signature: OSType) -> OSStatus {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(binding.keyCode, binding.modifiers,
            EventHotKeyID(signature: signature, id: binding.id), GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &reference)
        guard status == noErr, let reference else { return status == noErr ? OSStatus(paramErr) : status }
        references[binding.id] = reference
        return noErr
    }
    func unregister(_ id: UInt32) {
        if let reference = references.removeValue(forKey: id) { UnregisterEventHotKey(reference) }
    }
    func uninstall() {
        for id in Array(references.keys) { unregister(id) }
        if let handler { RemoveEventHandler(handler) }
        handler = nil; receive = nil
    }
    deinit { uninstall() }
}

final class GlobalShortcuts: ShortcutHandling {
    private let backend: any HotKeyBackend
    private let bindings: [ShortcutBinding]
    private var registered: [UInt32: DeskAction] = [:]
    private var generation: UInt = 0
    private(set) var registrationWarnings: [String] = []
    private(set) var diagnostics = ShortcutDiagnostics()
    var onAction: ((DeskAction) -> Void)?
    static let signature: OSType = 0x5242444B // RBDK

    init(backend: any HotKeyBackend = CarbonHotKeyBackend(), bindings: [ShortcutBinding] = ShortcutBindings.all) {
        self.backend = backend; self.bindings = bindings
    }
    func register() throws {
        unregister()
        diagnostics = ShortcutDiagnostics(); registrationWarnings = []
        let token = generation
        let result = backend.install { [weak self] hotKey in
            guard let self, self.generation == token else { return OSStatus(eventNotHandledErr) }
            return self.receive(hotKey)
        }
        guard result == noErr else {
            backend.uninstall()
            throw WindowControlError.message("Could not install the keyboard handler (\(result)). No windows moved.")
        }
        for binding in bindings {
            let status = backend.register(binding, signature: Self.signature)
            if status == noErr { registered[binding.id] = binding.action }
            else { registrationWarnings.append("\(binding.display) · \(binding.title): unavailable (\(status)).") }
        }
        // A conflicting optional alias must not disable the working shortcuts.
        guard registered.values.contains(.focusLeft), registered.values.contains(.focusRight) else {
            let detail = registrationWarnings.joined(separator: " ")
            unregister()
            throw WindowControlError.message("Keyboard navigation is unavailable. \(detail) No windows moved.")
        }
        diagnostics.registeredCount = registered.count
        RuntimeDiagnostics.shared.record("shortcuts.registered", ["count": registered.count,
            "unavailable": registrationWarnings.count])
    }
    private func receive(_ hotKey: EventHotKeyID) -> OSStatus {
        guard hotKey.signature == Self.signature, let action = registered[hotKey.id] else {
            return OSStatus(eventNotHandledErr)
        }
        diagnostics.receivedCount += 1; diagnostics.lastAction = action
        RuntimeDiagnostics.shared.record("shortcuts.received", ["binding": hotKey.id, "action": action.rawValue])
        if let onAction {
            diagnostics.dispatchedCount += 1
            onAction(action)
        }
        return noErr
    }
    func unregister() {
        generation &+= 1
        for id in registered.keys.sorted() { backend.unregister(id) }
        registered.removeAll(); backend.uninstall(); diagnostics.registeredCount = 0
    }
    deinit { unregister() }
}
