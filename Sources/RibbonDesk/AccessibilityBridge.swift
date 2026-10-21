import AppKit
import ApplicationServices
import RibbonCore

struct VisibleWindow {
    let number: CGWindowID
    let pid: pid_t
    let frame: Frame
}

struct ManagedWindow: @unchecked Sendable {
    let id: String
    let number: CGWindowID
    let pid: pid_t
    let element: AXUIElement
    let original: Frame
    let title: String
    let appName: String
    var originalSpaces: [UInt64] = []
    var destinationSpace: UInt64? = nil
    var isLocal = false
    var requiresResolution = false
    var stagedFromOtherDesktop = false
    var preservesDesktop = true
}

enum WindowControlError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

/// A cached AX object can expire while its native window remains alive. Only
/// these failures permit a single exact-identity refresh at a drained boundary.
struct WindowElementFailure: LocalizedError {
    enum Reason: Equatable { case invalidElement, cannotComplete, missingGeometry }
    let windowID: String
    let appName: String
    let reason: Reason
    var operation: String? = nil
    var axCode: Int32? = nil
    var errorDescription: String? {
        if let operation, let axCode {
            return "\(appName) rejected \(operation) (AX \(axCode))."
        }
        return "\(appName) no longer exposes its window geometry."
    }
}

/// Refresh never uses titles or geometry to choose an AX proxy. Keep these
/// predicates separate so identity refusals can be tested without AX access.
enum WindowRefreshIdentity {
    static func permits(window: ManagedWindow, saved: SavedWindow, currentPID: pid_t,
                        bundleID: String?, launchDate: Date?, kernelStart: Date?,
                        capturedAt: Date) -> Bool {
        !window.isLocal && window.id == saved.id && window.pid == saved.pid &&
            window.number == saved.number && window.original == saved.original &&
            currentPID == saved.pid && bundleID == saved.bundleID &&
            ProcessIdentity.matches(savedLaunch: saved.launchDate, currentLaunch: launchDate,
                kernelStart: kernelStart, capturedAt: saved.capturedAt ?? capturedAt)
    }

    static func exactCandidate(numbers: [CGWindowID?], savedNumber: CGWindowID) -> Int? {
        let matches = numbers.indices.filter { numbers[$0] == savedNumber }
        return matches.count == 1 ? matches[0] : nil
    }
}

/// The app accepted a resize but its stable native frame has a size limit.
/// The controller can adapt one column while preserving the live session.
struct WindowFrameConstraint: LocalizedError {
    let windowID: String
    let actual: Frame
    let target: Frame
    var errorDescription: String? { "A native window size limit prevented the requested ribbon slot." }
}

/// All AX operations are called only by an explicitly enabled live session.
/// No prompting, screen capture, Apple events, or preference changes.
@MainActor
protocol WindowBridge: AnyObject {
    var inventory: [WindowAccount] { get }
    var desktopOverviewActive: Bool { get }
    func currentDesktops(_ displays: [DisplayInfo]) throws -> [String: UInt64]
    func isTrusted() -> Bool
    func visibleWindows() -> [VisibleWindow]
    func availableWindows() -> [VisibleWindow]
    func discover(in viewport: Frame, excluding bundleIDs: Set<String>) throws -> [ManagedWindow]
    func discoverySignature(excluding bundleIDs: Set<String>) -> Set<String>
    func eligible(_ window: AXUIElement) -> Bool
    func eligible(_ window: ManagedWindow) -> Bool
    func frame(of window: AXUIElement) -> Frame?
    func minimumWidth(of window: ManagedWindow) -> Double
    func setFrame(_ target: Frame, of window: ManagedWindow) async throws
    func focus(_ window: ManagedWindow) throws
    func focusedWindowIdentity() -> (pid: pid_t, number: CGWindowID)?
    func topWindowIdentity(at point: CGPoint) -> (pid: pid_t, number: CGWindowID)?
    func raiseVisibleWindows(_ windows: [ManagedWindow]) async throws
    func movePositions(_ targets: [(ManagedWindow, Frame)]) async throws
    func movePositions(_ targets: [(ManagedWindow, Frame)], raising: [ManagedWindow]) async throws
    func drainMotion() async
    func recover(_ saved: [SavedWindow], capturedAt: Date) -> [ManagedWindow]
    func refreshWindow(_ window: ManagedWindow, saved: SavedWindow, capturedAt: Date) async throws -> ManagedWindow?
    func gather(_ windows: [ManagedWindow]) async throws -> [ManagedWindow]
    func restoreSpace(_ window: ManagedWindow) async throws
    func restoreWindow(_ window: ManagedWindow) async throws
    func desktopsMatch(_ windows: [ManagedWindow], displays: [DisplayInfo]) -> Bool
}

extension WindowBridge {
    func discoverySignature(excluding bundleIDs: Set<String>) -> Set<String> {
        Set(visibleWindows().map { "\($0.pid):\($0.number)" })
    }
    func minimumWidth(of window: ManagedWindow) -> Double { 240 }
    var inventory: [WindowAccount] { [] }
    var desktopOverviewActive: Bool { false }
    func currentDesktops(_ displays: [DisplayInfo]) throws -> [String: UInt64] {
        Dictionary(uniqueKeysWithValues: displays.map { ($0.id, 0) })
    }
    func availableWindows() -> [VisibleWindow] { visibleWindows() }
    func eligible(_ window: ManagedWindow) -> Bool { eligible(window.element) }
    func gather(_ windows: [ManagedWindow]) async throws -> [ManagedWindow] { windows }
    func restoreSpace(_ window: ManagedWindow) async throws {}
    func restoreWindow(_ window: ManagedWindow) async throws {
        try await setFrame(window.original, of: window)
        if !window.preservesDesktop { try await restoreSpace(window) }
    }
    func desktopsMatch(_ windows: [ManagedWindow], displays: [DisplayInfo]) -> Bool { false }
    func movePositions(_ targets: [(ManagedWindow, Frame)]) async throws {
        for (window, target) in targets { try await setFrame(target, of: window) }
    }
    func movePositions(_ targets: [(ManagedWindow, Frame)], raising: [ManagedWindow]) async throws {
        try await movePositions(targets)
        try await raiseVisibleWindows(raising)
    }
    func drainMotion() async {}
    func focusedWindowIdentity() -> (pid: pid_t, number: CGWindowID)? { nil }
    func topWindowIdentity(at point: CGPoint) -> (pid: pid_t, number: CGWindowID)? { nil }
    func raiseVisibleWindows(_ windows: [ManagedWindow]) async throws {}
    func recover(_ saved: [SavedWindow], capturedAt: Date) -> [ManagedWindow] { [] }
    func refreshWindow(_ window: ManagedWindow, saved: SavedWindow, capturedAt: Date) async throws -> ManagedWindow? { nil }
}

@MainActor
final class AccessibilityBridge: WindowBridge {
    private(set) var inventory: [WindowAccount] = []
    private let motionTransport = MotionBatchTransport(trace: { RuntimeDiagnostics.shared.record($0, $1) })
    private var motionPrimaryTop = NSScreen.screens.first?.frame.maxY ?? 0
    private(set) var lastMotionMilliseconds = 0.0
    private let spaces = SpaceService()
    private var mutated: Set<String> = []
    private let desktopActivity = DesktopActivity()
    var desktopOverviewActive: Bool { desktopActivity.isActive }
    func currentDesktops(_ displays: [DisplayInfo]) throws -> [String: UInt64] {
        let desktops = try spaces.desktops()
        return Dictionary(uniqueKeysWithValues: displays.map { ($0.id, SpaceService.destination(for: $0, in: desktops) ?? 0) })
    }
    private func localWindow(_ window: ManagedWindow) -> NSWindow? {
        guard window.isLocal, window.pid == getpid() else { return nil }
        return NSApp.window(withWindowNumber: Int(window.number))
    }

    func minimumWidth(of window: ManagedWindow) -> Double {
        if window.isLocal { return Double(localWindow(window)?.minSize.width ?? 240) }
        // A few AX providers expose this optional attribute. Most do not;
        // stable resize readback handles their native constraints separately.
        if let value = attribute(window.element, "AXMinSize"), CFGetTypeID(value) == AXValueGetTypeID() {
            let sizeValue = value as! AXValue
            var size = CGSize.zero
            if AXValueGetType(sizeValue) == .cgSize, AXValueGetValue(sizeValue, .cgSize, &size),
               size.width.isFinite, size.width > 0 { return Double(size.width) }
        }
        return 240
    }
    private func localFrame(_ window: NSWindow) -> Frame {
        let rect = window.frame
        return Frame(x: rect.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - rect.maxY,
                     width: rect.width, height: rect.height)
    }
    private func setLocalFrame(_ target: Frame, of window: NSWindow) {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        window.setFrame(NSRect(x: target.x, y: top - target.maxY, width: target.width, height: target.height), display: false, animate: false)
    }
    func isTrusted() -> Bool { AXIsProcessTrusted() }

    func visibleWindows() -> [VisibleWindow] {
        windowList(options: [.optionOnScreenOnly, .excludeDesktopElements])
    }
    func availableWindows() -> [VisibleWindow] {
        windowList(options: [.optionAll, .excludeDesktopElements])
    }
    private func windowList(options: CGWindowListOption) -> [VisibleWindow] {
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let layer = item[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = item[kCGWindowOwnerPID as String] as? Int32,
                  let number = item[kCGWindowNumber as String] as? UInt32,
                  let bounds = item[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width > 0, rect.height > 0 else { return nil }
            return VisibleWindow(number: number, pid: pid,
                                 frame: Frame(x: rect.minX, y: rect.minY,
                                              width: rect.width, height: rect.height))
        }
    }

    private func includesApplication(_ app: NSRunningApplication, excluding bundleIDs: Set<String>) -> Bool {
        guard !bundleIDs.contains(app.bundleIdentifier ?? "") else { return false }
        // The canonical utility and isolated preview use accessory activation
        // policies, but their normal windows still belong in desktop strips.
        return app.activationPolicy == .regular ||
            app.bundleIdentifier == "local.prototype.RibbonDesk" ||
            app.bundleIdentifier == "local.prototype.RibbonDesk.preview"
    }

    /// WindowServer identities only: no AX traversal in the idle change check.
    /// Include already-accounted dialogs too, so an unsupported window does not
    /// cause rediscovery every second. Minimized/hidden windows stay unchanged.
    func discoverySignature(excluding bundleIDs: Set<String>) -> Set<String> {
        guard let desktops = try? spaces.desktops(),
              let unminimized = try? spaces.nonMinimizedWindows(in: desktops) else { return [] }
        let active = Set(desktops.map(\.current))
        let applications = Set(NSWorkspace.shared.runningApplications.filter {
            !$0.isHidden && includesApplication($0, excluding: bundleIDs)
        }.map(\.processIdentifier))
        return Set(availableWindows().compactMap { window in
            guard applications.contains(window.pid), unminimized.contains(window.number),
                  window.frame.width >= 160, window.frame.height >= 100,
                  let membership = spaces.spaces(for: window.number),
                  !active.isDisjoint(with: membership) else { return nil }
            return "\(window.pid):\(window.number)"
        })
    }

    func discover(in viewport: Frame, excluding bundleIDs: Set<String>) throws -> [ManagedWindow] {
        guard isTrusted() else {
            throw WindowControlError.message("Accessibility is not granted. Live control remains disabled. This app never opens a permission prompt; authorization must be coordinated separately.")
        }
        let visible = availableWindows()
        let desktops = try spaces.desktops()
        let connected = DisplayInfo.current(NSScreen.screens)
        motionPrimaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        desktopActivity.start()
        inventory = []
        var captured: [ManagedWindow] = []
        var accounted: Set<UInt32> = []
        for app in NSWorkspace.shared.runningApplications where
            includesApplication(app, excluding: []) && app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, 0.25)
            guard let windows = attribute(axApp, kAXWindowsAttribute) as? [AXUIElement] else {
                inventory.append(WindowAccount(id: "app-\(app.processIdentifier)", app: app.localizedName ?? "Application",
                    title: "Window list unavailable", reason: "No accessible window list", frame: nil))
                continue
            }
            for window in windows {
                AXUIElementSetMessagingTimeout(window, 0.25)
                let nativeNumber = spaces.windowNumber(window)
                if let nativeNumber { accounted.insert(nativeNumber) }
                let id = UUID().uuidString
                let title = (attribute(window, kAXTitleAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled window"
                let geometry = frame(of: window)
                func account(_ reason: String) {
                    inventory.append(WindowAccount(id: id, app: app.localizedName ?? "Application",
                                                   title: title, reason: reason, frame: geometry))
                }
                if app.isHidden { account("Hidden application — unchanged"); continue }
                if bundleIDs.contains(app.bundleIdentifier ?? "") { account("Excluded application — unchanged"); continue }
                if boolean(window, kAXMinimizedAttribute) { account("Minimized — unchanged"); continue }
                if boolean(window, "AXFullScreen") { account("Fullscreen — unchanged"); continue }
                guard eligible(window), let frame = geometry, frame.isUsable,
                      frame.width >= 160, frame.height >= 100 else {
                    account("Dialog, fixed-size, or unsupported window — unchanged"); continue
                }
                // Prefer the native identity: windows on different Spaces often
                // have identical geometry. Geometry is only a unique fallback.
                let matches = visible.filter { cg in
                    cg.pid == app.processIdentifier && (nativeNumber.map { cg.number == $0 } ?? cg.frame.approximatelyEquals(frame, tolerance: 3))
                }
                guard matches.count == 1,
                      !captured.contains(where: { $0.number == matches[0].number }) else {
                    account("Unavailable window identity, or duplicate native tab — unchanged"); continue
                }
                let number = matches[0].number
                accounted.insert(number)
                guard let originals = spaces.spaces(for: number), !originals.isEmpty,
                      originals.allSatisfy({ id in desktops.contains { $0.userSpaces.contains(id) } }),
                      let owner = DisplayInfo.owner(of: frame, among: connected),
                      let destination = SpaceService.destination(for: owner, in: desktops),
                      originals.count == 1 || originals.contains(destination) else {
                    account("Fullscreen or unsupported desktop membership — unchanged"); continue
                }
                guard originals.contains(destination) else { account("Other desktop — separate strip"); continue }
                captured.append(ManagedWindow(id: id, number: matches[0].number,
                                              pid: app.processIdentifier, element: window,
                                              original: frame, title: title,
                                              appName: app.localizedName ?? "Application",
                                              originalSpaces: originals, destinationSpace: destination))
            }
            for cg in visible where cg.pid == app.processIdentifier && !accounted.contains(cg.number) {
                guard let owner = DisplayInfo.owner(of: cg.frame, among: connected),
                      let desktop = SpaceService.destination(for: owner, in: desktops),
                      spaces.spaces(for: cg.number)?.contains(desktop) == true else { continue }
                inventory.append(WindowAccount(id: "cg-\(cg.number)", app: app.localizedName ?? "Application",
                    title: "Window \(cg.number)", reason: "No accessible standard window — unchanged", frame: cg.frame))
            }
        }

        for window in NSApp.windows where window.styleMask.contains(.titled) &&
            !(window is NSPanel) && window.level == .normal && window.isVisible && !window.isMiniaturized {
            let frame = localFrame(window), number = UInt32(window.windowNumber)
            guard let originals = spaces.spaces(for: number), !originals.isEmpty,
                  let owner = DisplayInfo.owner(of: frame, among: connected),
                  let destination = SpaceService.destination(for: owner, in: desktops),
                  originals.contains(destination) else { continue }
            captured.append(ManagedWindow(id: UUID().uuidString, number: number, pid: getpid(),
                element: AXUIElementCreateApplication(getpid()), original: frame, title: window.title,
                appName: Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "RibbonDesk",
                originalSpaces: originals, destinationSpace: destination, isLocal: true))
        }
        return captured.sorted {
            if abs($0.original.x - $1.original.x) > 4 { return $0.original.x < $1.original.x }
            return $0.number < $1.number
        }
    }

    /// Resolve only the same still-running application instance and CG window.
    /// A restarted app/PID reuse or ambiguous AX proxy never inherits a snapshot.
    func recover(_ saved: [SavedWindow], capturedAt: Date) -> [ManagedWindow] {
        guard isTrusted() else { return [] }
        let visible = availableWindows()
        return saved.compactMap { item in
            guard let app = NSRunningApplication(processIdentifier: item.pid),
                  app.bundleIdentifier == item.bundleID,
                  ProcessIdentity.matches(savedLaunch: item.launchDate, currentLaunch: app.launchDate,
                                          kernelStart: ProcessIdentity.startTime(item.pid), capturedAt: item.capturedAt ?? capturedAt),
                  let cg = visible.first(where: { $0.pid == item.pid && $0.number == item.number }) else { return nil }
            mutated.insert(item.id) // Recovery must treat pre-crash writes as unknown.
            let axApp = AXUIElementCreateApplication(item.pid)
            AXUIElementSetMessagingTimeout(axApp, 0.25)
            let windows = (attribute(axApp, kAXWindowsAttribute) as? [AXUIElement] ?? []).filter {
                AXUIElementSetMessagingTimeout($0, 0.25)
                return eligible($0) && (spaces.windowNumber($0).map { $0 == cg.number } ?? (frame(of: $0)?.approximatelyEquals(cg.frame, tolerance: 3) == true))
            }
            guard let index = RecoveryIdentity.candidate(titles: windows.map {
                attribute($0, kAXTitleAttribute) as? String ?? "Untitled window"
            }, savedTitle: item.title) else {
                // AX may withhold this window until its desktop becomes active.
                // Preserve its exact CG/process identity for saved-first recovery.
                return ManagedWindow(id: item.id, number: item.number, pid: item.pid, element: axApp,
                    original: item.original, title: item.title, appName: item.appName,
                    originalSpaces: item.originalSpaces ?? [], requiresResolution: true,
                    stagedFromOtherDesktop: item.stagedFromOtherDesktop ?? false,
                    preservesDesktop: item.preservesDesktop ?? false)
            }
            return ManagedWindow(id: item.id, number: item.number, pid: item.pid, element: windows[index],
                                 original: item.original, title: item.title, appName: item.appName,
                                 originalSpaces: item.originalSpaces ?? [], stagedFromOtherDesktop: item.stagedFromOtherDesktop ?? false,
                    preservesDesktop: item.preservesDesktop ?? false)
        }
    }

    /// One fresh application/window enumeration, only after motion has drained.
    /// A missing or ambiguous exact native number leaves the original pending.
    func refreshWindow(_ window: ManagedWindow, saved: SavedWindow, capturedAt: Date) async throws -> ManagedWindow? {
        try Task.checkCancellation()
        guard isTrusted(), !window.isLocal,
              let app = NSRunningApplication(processIdentifier: saved.pid), !app.isTerminated, !app.isHidden,
              WindowRefreshIdentity.permits(window: window, saved: saved, currentPID: app.processIdentifier,
                bundleID: app.bundleIdentifier, launchDate: app.launchDate,
                kernelStart: ProcessIdentity.startTime(saved.pid), capturedAt: capturedAt),
              availableWindows().contains(where: { $0.pid == saved.pid && $0.number == saved.number }),
              let desktops = try? spaces.desktops(),
              (try? spaces.nonMinimizedWindows(in: desktops).contains(saved.number)) == true else { return nil }
        let axApp = AXUIElementCreateApplication(saved.pid)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        let candidates = attribute(axApp, kAXWindowsAttribute) as? [AXUIElement] ?? []
        for candidate in candidates { AXUIElementSetMessagingTimeout(candidate, 0.25) }
        guard let index = WindowRefreshIdentity.exactCandidate(
            numbers: candidates.map { spaces.windowNumber($0) }, savedNumber: saved.number) else { return nil }
        let element = candidates[index]
        var elementPID: pid_t = 0
        guard AXUIElementGetPid(element, &elementPID) == .success, elementPID == saved.pid,
              eligible(element), frame(of: element)?.isUsable == true else { return nil }
        try Task.checkCancellation()
        return ManagedWindow(id: window.id, number: window.number, pid: window.pid, element: element,
            original: window.original, title: window.title, appName: window.appName,
            originalSpaces: window.originalSpaces, destinationSpace: window.destinationSpace,
            stagedFromOtherDesktop: window.stagedFromOtherDesktop, preservesDesktop: window.preservesDesktop)
    }

    private func resolve(_ window: ManagedWindow) async throws -> ManagedWindow? {
        let axApp = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        for _ in 0..<30 {
            try Task.checkCancellation()
            let candidates = attribute(axApp, kAXWindowsAttribute) as? [AXUIElement] ?? []
            if let element = candidates.first(where: { spaces.windowNumber($0) == window.number }) {
                AXUIElementSetMessagingTimeout(element, 0.25)
                guard eligible(element) else { return nil }
                return ManagedWindow(id: window.id, number: window.number, pid: window.pid, element: element,
                    original: window.original, title: attribute(element, kAXTitleAttribute) as? String ?? window.title,
                    appName: window.appName, originalSpaces: window.originalSpaces, destinationSpace: window.destinationSpace,
                    stagedFromOtherDesktop: window.stagedFromOtherDesktop, preservesDesktop: window.preservesDesktop)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }
    func gather(_ windows: [ManagedWindow]) async throws -> [ManagedWindow] {
        var resolved: [ManagedWindow] = []
        for window in windows {
            try Task.checkCancellation()
            guard eligible(window) else { throw WindowControlError.message("A window was hidden, minimized, or changed before desktop gathering completed.") }
            if let target = window.destinationSpace, !window.originalSpaces.contains(target) {
                defer {
                    if spaces.spaces(for: window.number) != window.originalSpaces { mutated.insert(window.id) }
                }
                try await spaces.move(window.number, to: target)
            }
            if window.requiresResolution {
                if let bound = try await resolve(window) { resolved.append(bound) }
                else {
                    try await restoreSpace(window)
                    guard physicalFrame(of: window)?.approximatelyEquals(window.original, tolerance: 6) == true else {
                        throw WindowControlError.message("An unsupported window changed its geometry during desktop gathering. Its original arrangement remains saved.")
                    }
                    inventory.append(WindowAccount(id: window.id, app: window.appName, title: window.title,
                        reason: "Unsupported window — returned to its original desktop", frame: window.original))
                }
            } else { resolved.append(window) }
        }
        // AppKit can rebuild AX proxies after a Space transition. Give the
        // target apps a bounded settling interval before beginning frame writes.
        for attempt in 0..<50 {
            try Task.checkCancellation()
            let available = availableWindows()
            if let missing = resolved.first(where: { window in
                !available.contains { $0.pid == window.pid && $0.number == window.number } || !eligible(window)
            }) {
                if attempt == 49 { throw WindowControlError.message("\(missing.appName) became unavailable while gathering desktops.") }
                try await Task.sleep(nanoseconds: 16_000_000)
            } else { return resolved }
        }
        return resolved
    }
    func desktopsMatch(_ windows: [ManagedWindow], displays: [DisplayInfo]) -> Bool {
        guard let desktops = try? spaces.desktops() else { return false }
        return windows.allSatisfy { window in
            guard let target = window.destinationSpace,
                  let display = DisplayInfo.owner(of: window.original, among: displays) else { return false }
            return SpaceService.destination(for: display, in: desktops) == target
        }
    }
    func restoreSpace(_ window: ManagedWindow) async throws {
        guard window.originalSpaces.count == 1, let original = window.originalSpaces.first else { return }
        try await spaces.move(window.number, to: original)
    }
    func eligible(_ window: ManagedWindow) -> Bool {
        if window.isLocal {
            guard let local = localWindow(window) else { return false }
            return local.isVisible && !local.isMiniaturized && !local.styleMask.contains(.fullScreen)
        }
        if window.requiresResolution {
            guard let app = NSRunningApplication(processIdentifier: window.pid), !app.isHidden,
                  let desktops = try? spaces.desktops(),
                  let nonMinimized = try? spaces.nonMinimizedWindows(in: desktops) else { return false }
            return nonMinimized.contains(window.number)
        }
        return eligible(window.element)
    }
    func restoreWindow(_ window: ManagedWindow) async throws {
        // A failed gathering pass must not rewrite windows it never touched.
        // Recovered records are explicitly marked above because their prior
        // process may have exited between a native write and saving progress.
        guard mutated.contains(window.id) else { return }
        if window.preservesDesktop {
            if !window.isLocal {
                guard let app = NSRunningApplication(processIdentifier: window.pid), !app.isHidden,
                      let desktops = try? spaces.desktops(),
                      try spaces.nonMinimizedWindows(in: desktops).contains(window.number) else {
                    throw WindowControlError.message("\(window.appName) is hidden or minimized. Restore when it is available.")
                }
            }
            if window.requiresResolution {
                guard let resolved = try await resolve(window) else {
                    throw WindowControlError.message("Visit \(window.appName)'s desktop, then retry Restore Saved Arrangement.")
                }
                try await setFrame(window.original, of: resolved)
            } else { try await setFrame(window.original, of: window) }
            return
        }
        if window.isLocal { try await setFrame(window.original, of: window); try await restoreSpace(window); return }
        guard let app = NSRunningApplication(processIdentifier: window.pid), !app.isHidden,
              let desktops = try? spaces.desktops(),
              try spaces.nonMinimizedWindows(in: desktops).contains(window.number) else {
            throw WindowControlError.message("\(window.appName) is hidden, minimized, or unavailable. Its original arrangement remains saved.")
        }
        let onDesktop = visibleWindows().contains { $0.pid == window.pid && $0.number == window.number }
        if window.requiresResolution || !onDesktop || !eligible(window.element) {
            if physicalFrame(of: window)?.approximatelyEquals(window.original, tolerance: 6) == true {
                try await restoreSpace(window); return
            }
            let connected = DisplayInfo.current(NSScreen.screens)
            guard let frame = physicalFrame(of: window),
                  let display = DisplayInfo.owner(of: frame, among: connected),
                  let target = SpaceService.destination(for: display, in: desktops) else {
                throw WindowControlError.message("A desktop window is unavailable for recovery.")
            }
            try await spaces.move(window.number, to: target)
            guard let resolved = try await resolve(window) else { throw WindowControlError.message("A desktop window cannot be resolved for recovery.") }
            try await setFrame(window.original, of: resolved)
        } else { try await setFrame(window.original, of: window) }
        try await restoreSpace(window)
    }

    /// External applications receive the same frame concurrently, with ordered
    /// writes inside each PID. Local AppKit work joins the same completion barrier.
    /// No CG inventory, eligibility AX reads, resize, or focus occurs in this path.
    func movePositions(_ targets: [(ManagedWindow, Frame)]) async throws {
        try await movePositions(targets, raising: [])
    }

    func movePositions(_ targets: [(ManagedWindow, Frame)], raising: [ManagedWindow]) async throws {
        guard targets.allSatisfy({ $0.1.isUsable }) else {
            throw WindowControlError.message("Invalid scroll position.")
        }
        mutated.formUnion(targets.map { $0.0.id })
        var work: [pid_t: MotionBatchTransport.Work] = [:]
        var pidOrder: [pid_t] = []
        var local = MotionBatchTransport.LocalWork()
        let top = motionPrimaryTop
        func ensure(_ pid: pid_t) {
            if work[pid] == nil {
                work[pid] = MotionBatchTransport.Work(pid: pid); pidOrder.append(pid)
            }
        }
        for (window, target) in targets {
            if window.isLocal {
                guard let native = localWindow(window) else {
                    throw WindowControlError.message("RibbonDesk's dashboard is unavailable.")
                }
                local.positions.append(.init(window.id) {
                    try MainActor.assumeIsolated {
                        guard native.isVisible, !native.isMiniaturized else {
                            throw WindowControlError.message("RibbonDesk's dashboard is unavailable.")
                        }
                        native.setFrameOrigin(NSPoint(x: target.x, y: top - target.y - native.frame.height))
                    }
                })
            } else {
                ensure(window.pid)
                work[window.pid]!.positions.append(.init(window.id) {
                    var point = CGPoint(x: target.x, y: target.y)
                    guard let value = AXValueCreate(.cgPoint, &point) else {
                        throw WindowControlError.message("Invalid scroll position.")
                    }
                    let start = ProcessInfo.processInfo.systemUptime
                    let result = AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString, value)
                    // Retain baseline-compatible completion rows alongside the
                    // transport's explicit begin/end and per-application skew.
                    RuntimeDiagnostics.shared.record("move", ["pid": window.pid, "x": target.x,
                        "ms": (ProcessInfo.processInfo.systemUptime - start) * 1000, "result": result.rawValue])
                    guard result == .success else {
                        throw WindowControlError.message("\(window.appName) rejected scrolling (AX \(result.rawValue)).")
                    }
                })
            }
        }
        for window in raising {
            if window.isLocal {
                guard let native = localWindow(window) else { continue }
                local.raises.append(.init(window.id) {
                    MainActor.assumeIsolated { if native.isVisible { native.orderFront(nil) } }
                })
            } else {
                ensure(window.pid)
                work[window.pid]!.raises.append(.init(window.id) {
                    let result = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
                    RuntimeDiagnostics.shared.record("raise-visible", ["id": window.id,
                        "pid": window.pid, "result": result.rawValue])
                })
            }
        }
        guard !work.isEmpty || !local.positions.isEmpty || !local.raises.isEmpty else { return }
        let start = ProcessInfo.processInfo.systemUptime
        try await motionTransport.perform(pidOrder.compactMap { work[$0] }, local: local)
        lastMotionMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
    }

    func drainMotion() async {
        await motionTransport.drain()
        RuntimeDiagnostics.shared.flush()
    }

    /// The controller passes windows already validated against its active strip.
    /// Boundary-only raising never performs another WindowServer inventory read.
    func raiseVisibleWindows(_ windows: [ManagedWindow]) async throws {
        try await movePositions([], raising: windows)
    }

    func focusedWindowIdentity() -> (pid: pid_t, number: CGWindowID)? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        if app.processIdentifier == getpid(), let local = NSApp.keyWindow {
            return (getpid(), CGWindowID(local.windowNumber))
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.1)
        guard let value = attribute(element, kAXFocusedWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID(),
              let number = spaces.windowNumber(value as! AXUIElement) else { return nil }
        return (app.processIdentifier, number)
    }

    func topWindowIdentity(at point: CGPoint) -> (pid: pid_t, number: CGWindowID)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for item in list {
            guard (item[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let pid = item[kCGWindowOwnerPID as String] as? Int32,
                  let number = item[kCGWindowNumber as String] as? UInt32,
                  let bounds = item[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.contains(point) else { continue }
            return (pid, number)
        }
        return nil
    }

    func eligible(_ window: AXUIElement) -> Bool {
        guard attribute(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
              !boolean(window, kAXMinimizedAttribute), !boolean(window, "AXFullScreen"),
              !boolean(window, kAXModalAttribute) else { return false }
        let children = attribute(window, kAXChildrenAttribute) as? [AXUIElement] ?? []
        guard !children.contains(where: { attribute($0, kAXRoleAttribute) as? String == kAXSheetRole }) else { return false }
        var movable: DarwinBoolean = false
        var resizable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &movable) == .success && movable.boolValue &&
            AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &resizable) == .success && resizable.boolValue
    }

    func frame(of window: AXUIElement) -> Frame? {
        guard let position = attribute(window, kAXPositionAttribute),
              let size = attribute(window, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        let pValue = position as! AXValue
        let sValue = size as! AXValue
        guard AXValueGetType(pValue) == .cgPoint, AXValueGetType(sValue) == .cgSize else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(pValue, .cgPoint, &point), AXValueGetValue(sValue, .cgSize, &dimensions) else { return nil }
        return Frame(x: point.x, y: point.y, width: dimensions.width, height: dimensions.height)
    }

    func setFrame(_ target: Frame, of window: ManagedWindow) async throws {
        try Task.checkCancellation()
        guard target.isUsable else { throw WindowControlError.message("Rejected invalid geometry.") }
        mutated.insert(window.id)
        if window.isLocal {
            guard let local = localWindow(window), eligible(window) else { throw WindowControlError.message("RibbonDesk's dashboard is unavailable.") }
            setLocalFrame(target, of: local)
            guard localFrame(local).approximatelyEquals(target, tolerance: 6) else {
                throw WindowFrameConstraint(windowID: window.id, actual: localFrame(local), target: target)
            }
            return
        }
        var point = CGPoint(x: target.x, y: target.y)
        var size = CGSize(width: target.width, height: target.height)
        guard let p = AXValueCreate(.cgPoint, &point), let s = AXValueCreate(.cgSize, &size) else {
            throw WindowControlError.message("Could not encode window geometry.")
        }
        guard let reported = frame(of: window.element), let actual = physicalFrame(of: window) else {
            throw WindowElementFailure(windowID: window.id, appName: window.appName, reason: .missingGeometry)
        }
        if reported.approximatelyEquals(target, tolerance: 0.5), actual.approximatelyEquals(target, tolerance: 0.5) { return }
        let traceID = RuntimeDiagnostics.shared.isCapturing ? UUID().uuidString : nil
        func trace(_ step: String, requested: Frame) {
            guard let traceID else { return }
            func geometry(_ frame: Frame?) -> Any {
                guard let frame else { return NSNull() }
                return ["x": frame.x, "y": frame.y, "width": frame.width, "height": frame.height]
            }
            RuntimeDiagnostics.shared.record("resize-step", ["id": window.id, "pid": window.pid,
                "number": window.number, "operation": traceID, "step": step,
                "requested": geometry(requested), "ax": geometry(frame(of: window.element)),
                "cg": geometry(physicalFrame(of: window))])
        }
        var stageValidation: (() throws -> Void)?
        func write(_ name: String, _ value: AXValue) throws {
            try Task.checkCancellation()
            guard isTrusted() else { throw WindowControlError.message("Accessibility access changed during layout.") }
            try stageValidation?()
            let result = AXUIElementSetAttributeValue(window.element, name as CFString, value)
            guard result == .success else {
                if result == .invalidUIElement || result == .cannotComplete {
                    throw WindowElementFailure(windowID: window.id, appName: window.appName,
                        reason: result == .invalidUIElement ? .invalidElement : .cannotComplete,
                        operation: name, axCode: result.rawValue)
                }
                throw WindowControlError.message("\(window.appName) rejected \(name) (AX \(result.rawValue)).")
            }
        }
        trace("begin", requested: target)
        let connected = DisplayInfo.current(NSScreen.screens)
        if let display = DisplayInfo.owner(of: window.original, among: connected),
           WindowResizePolicy.stagingFrame(current: actual, target: target, viewport: display.usable) != nil {
            // Resizing a five-point parked sliver can be constrained by the OS
            // even when that app supports the requested size while visible.
            // Check the same desktop before a bounded settled-only safe stage.
            guard let app = NSRunningApplication(processIdentifier: window.pid), !app.isTerminated, !app.isHidden,
                  eligible(window.element),
                  let memberships = spaces.spaces(for: window.number),
                  let desktops = try? spaces.desktops(),
                  let activeDesktop = SpaceService.destination(for: display, in: desktops),
                  memberships.contains(activeDesktop),
                  (try? spaces.nonMinimizedWindows(in: desktops).contains(window.number)) == true,
                  !window.preservesDesktop || memberships == window.originalSpaces else {
                throw WindowControlError.message("\(window.appName) became unavailable before resizing. Its original frame remains saved.")
            }
            stageValidation = {
                try Task.checkCancellation()
                guard !self.desktopOverviewActive,
                      DisplayInfo.current(NSScreen.screens).contains(display),
                      let app = NSRunningApplication(processIdentifier: window.pid), !app.isTerminated, !app.isHidden,
                      self.eligible(window.element),
                      self.spaces.spaces(for: window.number) == memberships,
                      let currentDesktops = try? self.spaces.desktops(),
                      SpaceService.destination(for: display, in: currentDesktops) == activeDesktop,
                      (try? self.spaces.nonMinimizedWindows(in: currentDesktops).contains(window.number)) == true else {
                    throw WindowControlError.message("The desktop or window changed during resize staging. Its original frame remains saved.")
                }
            }
            try stageValidation?()
            _ = try await WindowResizeStaging.prepare(current: actual, target: target, viewport: display.usable,
                moveTo: { stage in
                    guard let current = self.physicalFrame(of: window) else {
                        throw WindowElementFailure(windowID: window.id, appName: window.appName, reason: .missingGeometry)
                    }
                    if abs(current.x - stage.x) > 1 || abs(current.y - stage.y) > 1 {
                        var origin = CGPoint(x: stage.x, y: stage.y)
                        guard let value = AXValueCreate(.cgPoint, &origin) else {
                            throw WindowControlError.message("Could not encode resize staging geometry.")
                        }
                        trace("stage-request", requested: stage)
                        try write(kAXPositionAttribute, value)
                        _ = try await self.awaitFrame(of: window) {
                            abs($0.x - stage.x) <= 1 && abs($0.y - stage.y) <= 1
                        }
                    }
                    trace("stage-ready", requested: stage)
                }, resizeTo: { stagedTarget in
                    trace("size-request", requested: stagedTarget)
                    try write(kAXSizeAttribute, s)
                    let resized = try await self.awaitFrame(of: window, returnAtDeadline: true) {
                        abs($0.width - target.width) <= 1 && abs($0.height - target.height) <= 1
                    }
                    try stageValidation?()
                    trace("size-ready", requested: stagedTarget)
                    guard abs(resized.width - target.width) <= 6, abs(resized.height - target.height) <= 6 else {
                        throw WindowFrameConstraint(windowID: window.id, actual: resized, target: target)
                    }
                })
        }
        // AppKit may return AX success before its window animation completes.
        // Issuing size and position back-to-back can cancel the first adjustment.
        // Visible destinations move first, await that app's response, then resize.
        // Offscreen size changes were already prepared at a safe origin above.
        // A superseded target-app animation can finish after a newer request.
        // Allow one correction of the current target, never an unbounded retry.
        for _ in 0..<2 {
            try Task.checkCancellation()
            guard let before = physicalFrame(of: window) else {
                throw WindowElementFailure(windowID: window.id, appName: window.appName, reason: .missingGeometry)
            }
            if abs(before.x - target.x) > 1 || abs(before.y - target.y) > 1 {
                trace("destination-request", requested: target)
                try write(kAXPositionAttribute, p)
                _ = try await awaitFrame(of: window, allowStable: true) {
                    abs($0.x - target.x) <= 1 && abs($0.y - target.y) <= 1
                }
            }
            guard let positioned = physicalFrame(of: window) else {
                throw WindowElementFailure(windowID: window.id, appName: window.appName, reason: .missingGeometry)
            }
            if abs(positioned.width - target.width) > 1 || abs(positioned.height - target.height) > 1 {
                trace("size-request", requested: target)
                try write(kAXSizeAttribute, s)
                _ = try await awaitFrame(of: window, returnAtDeadline: true) {
                    abs($0.width - target.width) <= 1 && abs($0.height - target.height) <= 1
                }
            }
            if let resized = physicalFrame(of: window),
               abs(resized.x - target.x) > 1 || abs(resized.y - target.y) > 1 {
                try write(kAXPositionAttribute, p)
            }
            let final = try await awaitFrame(of: window, allowStable: true, returnAtDeadline: true) {
                $0.approximatelyEquals(target, tolerance: 6)
            }
            trace("destination-ready", requested: target)
            if final.approximatelyEquals(target, tolerance: 6) { return }
        }
        guard let actual = physicalFrame(of: window), actual.isUsable else {
            throw WindowElementFailure(windowID: window.id, appName: window.appName, reason: .missingGeometry)
        }
        if abs(actual.width - target.width) > 6 || abs(actual.height - target.height) > 6 {
            throw WindowFrameConstraint(windowID: window.id, actual: actual, target: target)
        }
        throw WindowControlError.message("\(window.appName) did not accept the requested position. Live control stopped.")
    }

    private func physicalFrame(of window: ManagedWindow) -> Frame? {
        availableWindows().first { $0.pid == window.pid && $0.number == window.number }?.frame
    }

    private func awaitFrame(of window: ManagedWindow, allowStable: Bool = false,
                            returnAtDeadline: Bool = false,
                            matches: (Frame) -> Bool) async throws -> Frame {
        try await FrameConvergence.wait(appName: window.appName, allowStable: allowStable,
                                         returnAtDeadline: returnAtDeadline, matches: matches) {
            guard isTrusted() else { throw WindowControlError.message("Accessibility access changed during layout.") }
            guard let reported = frame(of: window.element),
                  let actual = physicalFrame(of: window) else {
                throw WindowElementFailure(windowID: window.id, appName: window.appName, reason: .missingGeometry)
            }
            return (reported, actual)
        }
    }

    func focus(_ window: ManagedWindow) throws {
        if window.isLocal {
            guard let local = localWindow(window) else { throw WindowControlError.message("RibbonDesk's dashboard is unavailable.") }
            NSApp.activate(ignoringOtherApps: true); local.makeKeyAndOrderFront(nil); return
        }
        guard let app = NSRunningApplication(processIdentifier: window.pid), !app.isTerminated else {
            throw WindowControlError.message("The selected app has closed.")
        }
        let axApp = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        // Select the already-onscreen window before activation, reducing the
        // chance that activating the app chooses a different document/desktop.
        let result = AXUIElementSetAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, window.element)
        guard result == .success else {
            if result == .invalidUIElement || result == .cannotComplete {
                throw WindowElementFailure(windowID: window.id, appName: window.appName,
                    reason: result == .invalidUIElement ? .invalidElement : .cannotComplete,
                    operation: kAXFocusedWindowAttribute, axCode: result.rawValue)
            }
            throw WindowControlError.message("\(window.appName) could not select this window (AX \(result.rawValue)).")
        }
        let raised = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        if raised == .invalidUIElement || raised == .cannotComplete {
            throw WindowElementFailure(windowID: window.id, appName: window.appName,
                reason: raised == .invalidUIElement ? .invalidElement : .cannotComplete,
                operation: kAXRaiseAction, axCode: raised.rawValue)
        }
        guard raised == .success, app.activate(options: []) else {
            throw WindowControlError.message("\(window.appName) did not accept keyboard focus.")
        }
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private func boolean(_ element: AXUIElement, _ name: String) -> Bool {
        (attribute(element, name) as? Bool) ?? false
    }
}

/// Readback timing is separate from AX transport so echoing values and late
/// target-app animations can be checked without any system permissions.
@MainActor
enum FrameConvergence {
    static func wait(appName: String, allowStable: Bool = false, returnAtDeadline: Bool = false,
                     matches: (Frame) -> Bool,
                     sample: () throws -> (reported: Frame, actual: Frame)) async throws -> Frame {
        let start = ProcessInfo.processInfo.systemUptime
        var previous: Frame?
        var stableSince = start
        var matchedSince: Double?
        while true {
            try Task.checkCancellation()
            let (reported, actual) = try sample()
            let now = ProcessInfo.processInfo.systemUptime
            // A brief target echo is insufficient: both sources must agree
            // across successive samples after older animations have finished.
            if matches(actual), matches(reported) {
                if let since = matchedSince, now - since >= 0.032 { return actual }
                if matchedSince == nil { matchedSince = now }
            } else { matchedSince = nil }
            if previous?.approximatelyEquals(actual, tolerance: 0.5) != true { stableSince = now }
            if allowStable, now - start >= 0.08, now - stableSince >= 0.064 { return actual }
            if now - start >= 0.6 {
                if allowStable || returnAtDeadline { return actual }
                throw WindowControlError.message("\(appName) did not settle at the requested frame. Live control stopped.")
            }
            previous = actual
            try await Task.sleep(nanoseconds: 16_000_000)
        }
    }
}
