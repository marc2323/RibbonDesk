import Foundation

/// Coordinates are display points, with the origin at the upper left (AX convention).
public struct Frame: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var isUsable: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0
    }
    public func approximatelyEquals(_ other: Frame, tolerance: Double = 4) -> Bool {
        abs(x - other.x) <= tolerance && abs(y - other.y) <= tolerance &&
        abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}

public struct StripItem: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var appName: String
    public var width: Double
    public var isFloating: Bool
    public init(id: String, title: String, appName: String, width: Double, isFloating: Bool = false) {
        self.id = id; self.title = title; self.appName = appName
        self.width = width; self.isFloating = isFloating
    }
}

public struct Placement: Equatable, Sendable {
    public var id: String
    public var frame: Frame
    public var isParked: Bool
}

/// Freeform preserves captured widths. Half-screen uses one or two grid slots,
/// with one inter-window gap included in the pitch so two halves fit exactly.
public enum StripLayoutMode: String, Codable, Equatable, Sendable {
    case freeform
    case halfScreen
}

/// Pure layout model: no AppKit, Accessibility, persistence, or other window access.
public struct StripState: Equatable, Sendable {
    public private(set) var items: [StripItem]
    public private(set) var focusedID: String?
    public private(set) var scrollOffset: Double = 0
    public let edgeInset: Double
    public let layoutMode: StripLayoutMode
    public static let gap = 8.0
    public static let inset = 16.0
    public static let edgeHandle = 5.0
    public init(items: [StripItem] = [], focusedID: String? = nil, edgeInset: Double = Self.inset,
                layoutMode: StripLayoutMode = .freeform) {
        self.edgeInset = edgeInset.isFinite ? max(0, edgeInset) : Self.inset
        self.layoutMode = layoutMode
        self.items = items
        self.focusedID = items.first(where: { $0.id == focusedID && !$0.isFloating })?.id
            ?? items.first(where: { !$0.isFloating })?.id
    }
    public var tiledItems: [StripItem] { items.filter { !$0.isFloating } }
    public var focusedItem: StripItem? { items.first { $0.id == focusedID } }
    public mutating func focus(_ id: String) {
        guard items.contains(where: { $0.id == id && !$0.isFloating }) else { return }
        focusedID = id
    }
    public mutating func stepFocus(_ direction: Int) {
        let tiles = tiledItems
        guard !tiles.isEmpty else { focusedID = nil; return }
        let index = tiles.firstIndex(where: { $0.id == focusedID }) ?? 0
        let next = max(0, min(tiles.count - 1, index + direction.signum()))
        focusedID = tiles[next].id
    }
    public mutating func reorderFocused(_ direction: Int) {
        let indices = items.indices.filter { !items[$0].isFloating }
        guard let position = indices.firstIndex(where: { items[$0].id == focusedID }) else { return }
        let next = position + direction.signum()
        guard indices.indices.contains(next) else { return }
        items.swapAt(indices[position], indices[next])
    }
    /// The actual half-window width, including room for the central gap.
    /// With no edge inset, two halves fill the usable screen exactly.
    public static func halfScreenWidth(in viewport: Frame, edgeInset: Double = 0) -> Double {
        guard viewport.isUsable, edgeInset.isFinite, edgeInset >= 0 else { return 0 }
        let available = viewport.width - edgeInset * 2
        guard available > 0 else { return 0 }
        return (available - gridGap(for: available)) / 2
    }

    /// Half-screen mode offers half and full widths. A native minimum just above
    /// a half must promote to full even when the requested preset is still 0.5.
    public mutating func setWidth(fraction: Double, viewport: Frame, minimumWidth: Double = 0) {
        guard let geometry = geometry(in: viewport), fraction.isFinite, fraction > 0,
              let index = items.firstIndex(where: { $0.id == focusedID }) else { return }
        let minimum = minimumWidth.isFinite ? max(0, minimumWidth) : 0
        if layoutMode == .halfScreen {
            let half = Self.halfScreenWidth(in: viewport, edgeInset: edgeInset)
            items[index].width = fraction <= 0.5 && minimum <= half + 0.001 ? half : geometry.available
        } else {
            items[index].width = min(geometry.available, max(max(min(240, geometry.available),
                geometry.available * min(1, fraction)), minimum))
        }
    }
    public mutating func toggleFloating(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isFloating.toggle()
        if items[index].isFloating && focusedID == id {
            focusedID = tiledItems.first?.id
        } else if focusedID == nil {
            focusedID = tiledItems.first?.id
        }
    }

    /// Keep an existing desktop's order, widths, focus and offset while updating
    /// its eligible window set. New windows join beside the focused column.
    public mutating func reconcile(_ discovered: [StripItem]) {
        let wanted = Set(discovered.map(\.id))
        items.removeAll { !wanted.contains($0.id) }
        let existing = Set(items.map(\.id))
        let additions = discovered.filter { !existing.contains($0.id) }
        let insertion = items.firstIndex { $0.id == focusedID }.map { $0 + 1 } ?? items.count
        items.insert(contentsOf: additions, at: insertion)
        if !items.contains(where: { $0.id == focusedID && !$0.isFloating }) { focusedID = tiledItems.first?.id }
    }

    /// A true virtual strip. Park only fully offscreen columns at a narrow edge
    /// handle; partially visible columns keep their exact shared strip position.
    /// With edgeInset zero, every tiled window uses the full usable screen height.
    /// During a gesture, revealFocused false preserves continuous presentation;
    /// settled layouts and keyboard navigation use the same half-screen grid.
    public mutating func layout(in viewport: Frame, revealFocused: Bool = true) -> [Placement] {
        guard let geometry = geometry(in: viewport) else { return [] }
        guard !geometry.columns.isEmpty else { scrollOffset = 0; return [] }
        scrollOffset = geometry.clamp(scrollOffset)
        if revealFocused {
            if layoutMode == .halfScreen {
                scrollOffset = settledOffset(in: geometry)
            } else if let focused = geometry.columns.first(where: { $0.id == focusedID }) {
                if focused.x < scrollOffset { scrollOffset = focused.x }
                if focused.maxX > scrollOffset + geometry.available {
                    scrollOffset = focused.maxX - geometry.available
                }
                scrollOffset = geometry.clamp(scrollOffset)
            }
        }
        let left = viewport.x + edgeInset
        let right = left + geometry.available
        return geometry.columns.map { column in
            let idealX = left + column.x - scrollOffset
            let handle = min(Self.edgeHandle, column.width)
            let outsideLeft = idealX + column.width <= left
            let outsideRight = idealX >= right
            let boundedX = outsideLeft ? left - column.width + handle
                : outsideRight ? right - handle : idealX
            return Placement(id: column.id,
                             frame: Frame(x: boundedX, y: viewport.y + edgeInset,
                                          width: column.width, height: geometry.height),
                             isParked: outsideLeft || outsideRight)
        }
    }

    /// Pan continuously without activating an app or snapping back to old focus.
    /// Positive delta reveals columns to the right. Width and order stay intact.
    @discardableResult
    public mutating func scroll(by delta: Double, in viewport: Frame) -> Bool {
        guard delta.isFinite, let geometry = geometry(in: viewport) else { return false }
        let previous = scrollOffset
        scrollOffset = geometry.clamp(scrollOffset + delta)
        return abs(scrollOffset - previous) > 0.001
    }

    /// Nearest settled position that fully reveals the selected column. In grid
    /// mode every target is a half-screen pitch, including both strip endpoints.
    public func snapOffset(in viewport: Frame) -> Double {
        guard let geometry = geometry(in: viewport) else { return scrollOffset }
        return settledOffset(in: geometry)
    }

    /// Gesture settlement follows the viewport rather than the previously
    /// focused column. A deliberate short flick reaches the next grid boundary;
    /// slow drags still choose the nearest one. Current offset already includes
    /// generated momentum, so release velocity supplies direction only.
    public func gestureSnapOffset(in viewport: Frame, startingAt start: Double,
                                  completion: RibbonSwipeCompletion? = nil) -> Double {
        guard let geometry = geometry(in: viewport) else { return scrollOffset }
        guard let pitch = geometry.pitch else { return settledOffset(in: geometry) }
        let current = geometry.clamp(scrollOffset)
        let nearest = geometry.clamp((current / pitch).rounded() * pitch)
        guard start.isFinite, let completion else { return nearest }
        let start = geometry.clamp(start)
        switch completion.flickDirection {
        case 1:
            let next = geometry.clamp((floor(start / pitch + 0.000000001) + 1) * pitch)
            return max(nearest, next)
        case -1:
            let next = geometry.clamp((ceil(start / pitch - 0.000000001) - 1) * pitch)
            return min(nearest, next)
        default:
            return nearest
        }
    }

    /// Select the column nearest the viewport center when fingers lift. Panning
    /// itself never activates apps; the controller may activate this after snap.
    public mutating func focusNearestToCenter(in viewport: Frame) {
        guard let geometry = geometry(in: viewport) else { return }
        let center = geometry.clamp(scrollOffset) + geometry.available / 2
        focusedID = geometry.columns.min {
            abs($0.x + $0.width / 2 - center) < abs($1.x + $1.width / 2 - center)
        }?.id
    }

    private struct Column {
        var id: String
        var x: Double
        var width: Double
        var maxX: Double { x + width }
    }
    private struct Geometry {
        var available: Double
        var height: Double
        var pitch: Double?
        var columns: [Column]
        var maximum: Double
        func clamp(_ offset: Double) -> Double { max(0, min(maximum, offset)) }
    }
    private static func gridGap(for available: Double) -> Double {
        // Keep even tiny valid viewports usable; normal displays retain 8 pt.
        min(Self.gap, available / 3)
    }
    private func geometry(in viewport: Frame) -> Geometry? {
        guard viewport.isUsable, viewport.width > edgeInset * 2,
              viewport.height > edgeInset * 2 else { return nil }
        let available = viewport.width - edgeInset * 2
        let gap = layoutMode == .halfScreen ? Self.gridGap(for: available) : Self.gap
        let pitch = layoutMode == .halfScreen ? (available + gap) / 2 : nil
        var columns: [Column] = []
        columns.reserveCapacity(items.count)
        var x = 0.0
        var slots = 0
        for item in items where !item.isFloating {
            let width: Double
            if let pitch {
                let half = pitch - gap
                let wantsFull = item.width.isFinite && item.width > half + 0.001
                width = wantsFull ? available : half
                x = Double(slots) * pitch
                slots += wantsFull ? 2 : 1
            } else {
                width = item.width.isFinite && item.width > 0 ? min(available, item.width) : min(600, available)
            }
            columns.append(Column(id: item.id, x: x, width: width))
            x += width + gap
        }
        // Compute grid endpoints by slot count, avoiding fractional drift at an
        // odd tail or after a mixture of half- and full-screen columns.
        let total = max(0, x - gap)
        let maximum: Double
        if let pitch {
            maximum = Double(max(0, slots - 2)) * pitch
        } else {
            maximum = max(0, total - available)
        }
        return Geometry(available: available, height: viewport.height - edgeInset * 2,
                        pitch: pitch, columns: columns, maximum: maximum)
    }
    private func settledOffset(in geometry: Geometry) -> Double {
        let current = geometry.clamp(scrollOffset)
        let focused = geometry.columns.first(where: { $0.id == focusedID })
        if let pitch = geometry.pitch {
            let lower = geometry.clamp((((focused?.maxX ?? 0) - geometry.available) / pitch).rounded() * pitch)
            let upper = geometry.clamp(((focused?.x ?? geometry.maximum) / pitch).rounded() * pitch)
            let nearest = (current / pitch).rounded() * pitch
            return max(lower, min(upper, geometry.clamp(nearest)))
        }
        guard let focused else { return current }
        return [focused.x, focused.maxX - geometry.available].map(geometry.clamp)
            .min { abs($0 - current) < abs($1 - current) } ?? current
    }

}

/// Monotonic edge settling with a quick response and no overshoot. A new swipe
/// can replace this animation from its current position without jumping.
public struct StripSnap {
    public let start: Double
    public let target: Double
    public let duration: Double
    public init(start: Double, target: Double) {
        self.start = start; self.target = target
        duration = 0.12 + min(0.08, abs(target - start) / 5000)
    }
    public func position(after seconds: Double) -> Double {
        let t = max(0, min(1, seconds / duration))
        return start + (target - start) * (1 - pow(1 - t, 3))
    }
}

/// A short, frame-rate-independent filter removes uneven raw contact sampling.
/// Only presentation is filtered; logical travel and reversal remain immediate.
public enum StripSmoothing {
    public static func offset(from start: Double, to target: Double, seconds: Double) -> Double {
        guard start.isFinite, target.isFinite, seconds.isFinite, seconds > 0 else { return start }
        let value = start + (target - start) * (1 - exp(-seconds / 0.018))
        return abs(target - value) < 0.1 ? target : value
    }
}
