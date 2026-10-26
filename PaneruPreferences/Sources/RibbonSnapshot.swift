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

/// Pixel-space inertia for raw three-finger input. The controller schedules
/// frames only between a moving release and the first idle/boundary frame.
struct RibbonOverviewMomentum {
    private(set) var velocity = 0.0
    private(set) var touching = false
    private(set) var coasting = false
    private var sampleTime = 0.0
    private var moveTime = 0.0
    private var frameTime = 0.0
    private var hasSample = false

    mutating func cancel() { self = Self() }
    mutating func begin(at time: TimeInterval) {
        cancel()
        touching = true
        sampleTime = time
    }
    mutating func move(by delta: Double, at time: TimeInterval) {
        guard delta.isFinite, time.isFinite, delta != 0 else { return }
        if !touching { begin(at: time) }
        let dt = max(hasSample ? 0.001 : 1.0 / 60, time - sampleTime)
        let sample = min(8000, max(-8000, delta / dt))
        let alpha = 1 - exp(-dt / 0.035)
        velocity = !hasSample || velocity * sample <= 0 ? sample : velocity + alpha * (sample - velocity)
        sampleTime = time
        moveTime = time
        hasSample = true
    }
    mutating func end(at time: TimeInterval) {
        guard touching else { return }
        touching = false
        if !hasSample || time - moveTime > 0.1 || abs(velocity) < 20 {
            cancel()
            return
        }
        frameTime = time
        coasting = true
    }
    mutating func advance(at time: TimeInterval) -> Double? {
        guard coasting, time.isFinite else { return nil }
        let elapsed = max(0, time - frameTime)
        frameTime = time
        let dt = min(elapsed, 1.0 / 30)
        // Integrate the exponential exactly, so 60/120 Hz cover the same
        // distance. A delayed frame sheds velocity without a large jump.
        let distance = velocity * (1 - exp(-5 * dt)) / 5
        velocity *= exp(-5 * elapsed)
        if abs(velocity) < 4 { cancel() }
        return distance
    }
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
        let focused_window_id: Int32?
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
    var overviewOriginID: Int32? {
        let windows = ribbon
        if let id = active.focused_window_id, windows.contains(where: { $0.id == id }) { return id }
        return windows.first(where: \.focused)?.id ?? windows.first(where: \.visible)?.id
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
    struct Instance: Identifiable {
        struct ID: Hashable { let windowID: Int32; let lap: Int }
        let id: ID
        let index: Int
        let frame: RibbonWindow.Frame
    }
    struct Overview {
        let scale: Double
        let x: Double
        let y: Double
        let maxOffset: Double
        let availableWidth: Double
        let loopPeriod: Double?
        var scrollExtent: Double { loopPeriod.map { $0 * scale } ?? maxOffset }
        func clamped(_ offset: Double) -> Double { min(maxOffset, max(0, offset)) }
        func resolvedOffset(_ offset: Double) -> Double {
            guard offset.isFinite else { return 0 }
            guard let loopPeriod else { return clamped(offset) }
            let period = loopPeriod * scale
            let remainder = offset.truncatingRemainder(dividingBy: period)
            return remainder < 0 ? remainder + period : remainder
        }
    }
    let placements: [Placement]
    let bounds: RibbonWindow.Frame
    let focusedID: Int32?
    let loopPeriod: Double?
    private let firstCenter: Double
    private let lastCenter: Double
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
        let centers = placements.map { $0.frame.x + $0.frame.width / 2 }
        firstCenter = centers.min() ?? minX + bounds.width / 2
        lastCenter = centers.max() ?? firstCenter
        // Merge overlapping stack/tab members into columns, then carry the
        // ordinary column gap across the join. Preview copies share one image.
        var columns: [(left: Double, right: Double)] = []
        for placement in placements.sorted(by: { $0.frame.x < $1.frame.x }) {
            let frame = placement.frame
            if let last = columns.last, frame.x < last.right {
                columns[columns.count - 1].right = max(last.right, frame.x + frame.width)
            } else { columns.append((frame.x, frame.x + frame.width)) }
        }
        let gaps = zip(columns, columns.dropFirst()).map { max(0, $1.left - $0.right) }.sorted()
        loopPeriod = columns.count > 1 ? bounds.width + (gaps.isEmpty ? 0 : gaps[gaps.count / 2]) : nil
    }
    func fit(width: Double, height: Double, inset: Double = 40) -> (scale: Double, x: Double, y: Double) {
        let scale = min(1, min(max(1, width - inset * 2) / bounds.width, max(1, height - inset * 2) / bounds.height))
        return (scale, (width - bounds.width * scale) / 2 - bounds.x * scale,
                (height - bounds.height * scale) / 2 - bounds.y * scale)
    }
    /// Use one-third size, with horizontal panning for long ribbons.
    /// Height can impose a smaller scale on unusually short displays.
    func overview(width: Double, height: Double, inset: Double = 48, infinite: Bool = false) -> Overview {
        let availableWidth = max(1, width - inset * 2)
        let scale = min(1.0 / 3.0, max(1, height - inset * 2) / bounds.height)
        // End padding lets even the first/last preview reach screen center.
        let x = width / 2 - firstCenter * scale
        return Overview(scale: scale, x: x, y: (height - bounds.height * scale) / 2 - bounds.y * scale,
                        maxOffset: (lastCenter - firstCenter) * scale, availableWidth: availableWidth, loopPeriod: infinite ? loopPeriod : nil)
    }
    func initialOffset(_ overview: Overview, viewportX: Double, width: Double, originID: Int32? = nil) -> Double {
        let center = placements.first(where: { $0.id == originID }).map { $0.frame.x + $0.frame.width / 2 }
            ?? (viewportX + width / 2)
        return overview.resolvedOffset(overview.x + center * overview.scale - width / 2)
    }
    /// AppKit callers convert their pointer to top-left panel coordinates first.
    func windowAt(x: Double, y: Double, width: Double, height: Double, offset: Double, infinite: Bool = false) -> Int32? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let overview = overview(width: width, height: height, infinite: infinite)
        var logicalX = (x - overview.x + overview.resolvedOffset(offset)) / overview.scale
        if let period = overview.loopPeriod {
            let remainder = (logicalX - bounds.x).truncatingRemainder(dividingBy: period)
            logicalX = bounds.x + (remainder < 0 ? remainder + period : remainder)
        }
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
    /// Cull individual copies rather than repeating a whole long ribbon.
    func instances(scale: Double, x: Double, width: Double, period: Double?, margin: Double = 100) -> [Instance] {
        let laps: ClosedRange<Int>
        if let period {
            let start = Int(floor(((-margin - x) / scale - bounds.x - bounds.width) / period))
            let end = Int(ceil(((width + margin - x) / scale - bounds.x) / period))
            laps = start...max(start, end)
        } else { laps = 0...0 }
        return laps.flatMap { lap in
            placements.enumerated().compactMap { index, placement in
                let frame = placement.frame
                let left = frame.x + Double(lap) * (period ?? 0)
                guard (left + frame.width) * scale + x >= -margin, left * scale + x <= width + margin else { return nil }
                return Instance(id: .init(windowID: placement.id, lap: lap), index: index,
                                frame: .init(x: left, y: frame.y, width: frame.width, height: frame.height))
            }
        }
    }
    func sceneInstances(overview: Overview, offset: Double, width: Double, destinationX: Double) -> [Instance] {
        let visible = instances(scale: overview.scale, x: overview.x - overview.resolvedOffset(offset), width: width, period: overview.loopPeriod)
        let destination = instances(scale: 1, x: destinationX, width: width, period: overview.loopPeriod)
        let ids = Set(visible.map(\.id))
        return visible + destination.filter { !ids.contains($0.id) }
    }
    func originInstance(id: Int32?, instances: [Instance], scale: Double, x: Double, width: Double) -> Instance? {
        instances.filter {
            $0.id.windowID == id && ($0.frame.x + $0.frame.width) * scale + x > 0 && $0.frame.x * scale + x < width
        }.min {
            abs(($0.frame.x + $0.frame.width / 2) * scale + x - width / 2)
                < abs(($1.frame.x + $1.frame.width / 2) * scale + x - width / 2)
        }
    }
    func sceneShift(id: Int32, overview: Overview, offset: Double, width: Double, preferredX: Double) -> Double {
        guard let period = overview.loopPeriod else { return 0 }
        let x = overview.x - overview.resolvedOffset(offset)
        let instance = instances(scale: overview.scale, x: x, width: width, period: period, margin: 0)
            .filter { $0.id.windowID == id }
            .min { abs(($0.frame.x + $0.frame.width / 2) * overview.scale + x - preferredX)
                < abs(($1.frame.x + $1.frame.width / 2) * overview.scale + x - preferredX) }
        return Double(instance?.id.lap ?? 0) * period
    }
    func revealingOffset(id: Int32, overview: Overview, offset: Double, width: Double) -> Double {
        guard let frame = placements.first(where: { $0.id == id })?.frame else { return offset }
        let origin = overview.x - overview.resolvedOffset(offset)
        let center = (width / 2 - origin) / overview.scale
        let lap = overview.loopPeriod.map { ((center - frame.x - frame.width / 2) / $0).rounded() * $0 } ?? 0
        let left = (frame.x + lap) * overview.scale + origin
        let right = left + frame.width * overview.scale
        if left < 48 { return overview.resolvedOffset(offset + left - 48) }
        if right > width - 48 { return overview.resolvedOffset(offset + min(left - 48, right - width + 48)) }
        return overview.resolvedOffset(offset)
    }
    func destination(id: Int32?, viewportX: Double, width: Double) -> Double {
        guard let frame = placements.first(where: { $0.id == id })?.frame else { return viewportX }
        if frame.x < viewportX { return frame.x }
        if frame.x + frame.width > viewportX + width { return frame.width >= width ? frame.x : frame.x + frame.width - width }
        return viewportX
    }
}
