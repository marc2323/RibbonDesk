import Foundation

/// Native readiness and the optional animation can finish in either order.
/// Keep the covering panel until both refer to the selected window.
struct RibbonHandoffGate {
    let targetID: Int32
    private(set) var nativeReady = false
    var animationFinished: Bool
    var canReveal: Bool { nativeReady && animationFinished }
    mutating func acknowledge(_ id: Int32) { if id == targetID { nativeReady = true } }
}

enum RibbonWindowAction: String, Sendable {
    case close
    case quitApp = "quit-app"
}

/// Keep selection nearby when a native close/quit removes a preview.
func ribbonSelection(after windows: [RibbonWindow], previous: [RibbonWindow], selectedID: Int32?) -> Int32? {
    if let selectedID, windows.contains(where: { $0.id == selectedID }) { return selectedID }
    let index = previous.firstIndex { $0.id == selectedID } ?? 0
    return windows.isEmpty ? nil : windows[min(index, windows.count - 1)].id
}

/// Subscription packets are newline-delimited and may arrive in partial chunks.
/// Frozen previews don't need subprocess queries for title/focus-only changes.
final class RibbonOverviewChanges: @unchecked Sendable {
    private struct Envelope: Decodable { let event: String }
    private let lock = NSLock()
    private var buffer = Data()
    func consume(_ data: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        guard buffer.count <= 8 * 1024 * 1024 else { buffer.removeAll(); return true }
        var refresh = false
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[..<newline]
            if let event = try? JSONDecoder().decode(Envelope.self, from: line).event {
                if ["windows_changed", "on_screen_changed", "virtual_workspace_changed", "display_changed"].contains(event) { refresh = true }
            }
            buffer.removeSubrange(...newline)
        }
        return refresh
    }
}

/// Engine order is authoritative; native frames of parked windows cannot recover it.
struct RibbonSnapshot: Decodable, Sendable {
    struct Active: Decodable, Sendable {
        let display_id: UInt32?
        let native_workspace_id: UInt64?
        let virtual_workspace_number: UInt32?
    }
    struct Workspace: Decodable, Sendable {
        let number: UInt32
        let native_workspace_id: UInt64
        let active: Bool
        let windows: [RibbonWindow]
    }
    let active: Active
    let virtual_workspaces: [Workspace]
    var ribbon: [RibbonWindow] {
        virtual_workspaces.first {
            $0.active && $0.native_workspace_id == active.native_workspace_id && $0.number == active.virtual_workspace_number
        }?.windows.filter { !$0.floating } ?? []
    }
    func sharesWorkspace(with other: RibbonSnapshot) -> Bool {
        active.native_workspace_id == other.active.native_workspace_id && active.display_id == other.active.display_id
            && active.virtual_workspace_number == other.active.virtual_workspace_number
    }
}

struct RibbonWindow: Decodable, Identifiable, Equatable, Sendable {
    struct Frame: Decodable, Equatable, Sendable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }
    let window_id: Int32
    let bundle_id: String
    let app_name: String
    let title: String
    let focused: Bool
    let floating: Bool
    let visible: Bool
    let frame: Frame?
    let ribbon_frame: Frame?
    var id: Int32 { window_id }
    var label: String { title.isEmpty ? app_name : title }
}

/// Plan against the latest engine order, skipping siblings in the same column.
struct RibbonReorderQueue {
    struct Move: Equatable { let id: Int32; let target: Int32; let after: Bool }
    private var steps: [(id: Int32, delta: Int)] = []
    mutating func append(id: Int32, delta: Int) {
        if delta != 0, steps.count < 32 { steps.append((id, delta < 0 ? -1 : 1)) }
    }
    mutating func clear() { steps.removeAll() }
    mutating func next(windows: [RibbonWindow]) -> Move? {
        while !steps.isEmpty {
            let step = steps.removeFirst()
            guard let index = windows.firstIndex(where: { $0.id == step.id }) else { continue }
            let column = windows[index].ribbon_frame
            var target = index + step.delta
            while windows.indices.contains(target), let column, let candidate = windows[target].ribbon_frame,
                  max(column.x, candidate.x) < min(column.x + column.width, candidate.x + candidate.width) {
                target += step.delta
            }
            if windows.indices.contains(target) {
                return Move(id: step.id, target: windows[target].id, after: step.delta > 0)
            }
        }
        return nil
    }
}

/// A single camera transform over the engine's real, unbounded ribbon geometry.
/// Every window uses this scale, preserving gaps, widths, heights, and stacks.
struct RibbonCamera {
    struct Placement { let id: Int32; let frame: RibbonWindow.Frame }
    struct Overview {
        let scale: Double
        let x: Double
        let y: Double
        let maxOffset: Double
        let availableWidth: Double
        func clamped(_ offset: Double) -> Double { min(maxOffset, max(0, offset)) }
    }
    let placements: [Placement]
    let bounds: RibbonWindow.Frame
    let focusedID: Int32?
    init(windows: [RibbonWindow]) {
        focusedID = windows.first(where: \.focused)?.id
        var cursor = 0.0
        placements = windows.map { window in
            let native = window.frame
            let frame = window.ribbon_frame ?? RibbonWindow.Frame(x: cursor, y: 0, width: max(1, native?.width ?? 900), height: max(1, native?.height ?? 700))
            cursor = max(cursor, frame.x + frame.width)
            return Placement(id: window.id, frame: frame)
        }
        let minX = placements.map { $0.frame.x }.min() ?? 0
        let minY = placements.map { $0.frame.y }.min() ?? 0
        let maxX = placements.map { $0.frame.x + $0.frame.width }.max() ?? 1
        let maxY = placements.map { $0.frame.y + $0.frame.height }.max() ?? 1
        bounds = .init(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
    }
    func fit(width: Double, height: Double, inset: Double = 40) -> (scale: Double, x: Double, y: Double) {
        let scale = min(1, min(max(1, width - inset * 2) / bounds.width, max(1, height - inset * 2) / bounds.height))
        return (scale, (width - bounds.width * scale) / 2 - bounds.x * scale,
                (height - bounds.height * scale) / 2 - bounds.y * scale)
    }
    /// Use one-third size, with horizontal panning for long ribbons.
    /// Height can impose a smaller scale on unusually short displays.
    func overview(width: Double, height: Double, inset: Double = 48) -> Overview {
        let availableWidth = max(1, width - inset * 2)
        let scale = min(1.0 / 3.0, max(1, height - inset * 2) / bounds.height)
        let overflow = max(0, bounds.width * scale - availableWidth)
        let x = overflow > 0 ? inset - bounds.x * scale : (width - bounds.width * scale) / 2 - bounds.x * scale
        return Overview(scale: scale, x: x, y: (height - bounds.height * scale) / 2 - bounds.y * scale,
                        maxOffset: overflow, availableWidth: availableWidth)
    }
    func initialOffset(_ overview: Overview, viewportX: Double, width: Double) -> Double {
        overview.clamped((viewportX + width / 2 - bounds.x) * overview.scale - overview.availableWidth / 2)
    }
    /// AppKit callers convert their pointer to top-left panel coordinates first.
    func windowAt(x: Double, y: Double, width: Double, height: Double, offset: Double) -> Int32? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let overview = overview(width: width, height: height)
        let logicalX = (x - overview.x + overview.clamped(offset)) / overview.scale
        let logicalY = (y - overview.y) / overview.scale
        let hits = placements.filter { placement in
            let frame = placement.frame
            return logicalX >= frame.x && logicalX < frame.x + frame.width
                && logicalY >= frame.y && logicalY < frame.y + frame.height
        }
        // Match the scene's z-order for overlapping tabs/windows.
        return hits.first(where: { $0.id == focusedID })?.id ?? hits.first?.id
    }
    func visibleIDs(scale: Double, x: Double, width: Double, margin: Double = 100) -> Set<Int32> {
        Set(placements.filter {
            ($0.frame.x + $0.frame.width) * scale + x >= -margin && $0.frame.x * scale + x <= width + margin
        }.map(\.id))
    }
    func destination(id: Int32?, viewportX: Double, width: Double) -> Double {
        guard let frame = placements.first(where: { $0.id == id })?.frame else { return viewportX }
        if frame.x < viewportX { return frame.x }
        if frame.x + frame.width > viewportX + width { return frame.width >= width ? frame.x : frame.x + frame.width - width }
        return viewportX
    }
}
