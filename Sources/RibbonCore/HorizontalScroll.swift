import Foundation

/// Input normalization only. AppKit already applies the user's natural-scroll
/// direction, so do not invert it again using directionInvertedFromDevice.
public enum HorizontalScroll {
    public static func viewportDelta(x: Double, y: Double, precise: Bool, momentum: Bool) -> Double? {
        guard !momentum, x.isFinite, y.isFinite, abs(x) > 0, abs(x) > abs(y) else { return nil }
        return -x * (precise ? 1 : 20)
    }
}

/// Decide the axis once per finger gesture. A mostly vertical gesture must not
/// move desktop windows when one later sample happens to wobble horizontally.
public struct HorizontalScrollGesture {
    public enum Phase { case none, mayBegin, began, changed, ended, cancelled }
    public struct Update {
        public let delta: Double?
        public let finished: Bool
    }
    private enum Axis { case undecided, horizontal, vertical }
    private var axis = Axis.undecided
    private var pendingX = 0.0
    private var pendingY = 0.0

    public init() {}
    public mutating func reset() { self = Self() }

    public mutating func consume(x: Double, y: Double, precise: Bool,
                                 momentum: Bool, phase: Phase) -> Update {
        guard !momentum else { return Update(delta: nil, finished: false) }
        if phase == .began || phase == .mayBegin { reset() }
        if phase == .none {
            reset()
            let delta = HorizontalScroll.viewportDelta(x: x, y: y, precise: precise, momentum: false)
            return Update(delta: delta, finished: delta != nil)
        }
        if phase == .cancelled {
            let finished = axis == .horizontal
            reset()
            return Update(delta: nil, finished: finished)
        }
        let ending = phase == .ended
        defer { if ending { reset() } }
        guard x.isFinite, y.isFinite else {
            return Update(delta: nil, finished: ending && axis == .horizontal)
        }
        var dx = x
        if axis == .undecided {
            pendingX += x; pendingY += y
            // Accumulate tiny samples instead of discarding slow finger motion.
            guard ending || max(abs(pendingX), abs(pendingY)) >= (precise ? 2 : 0) else {
                return Update(delta: nil, finished: false)
            }
            guard abs(pendingX) != abs(pendingY) else {
                return Update(delta: nil, finished: false)
            }
            axis = abs(pendingX) > abs(pendingY) ? .horizontal : .vertical
            dx = pendingX
            pendingX = 0; pendingY = 0
        }
        let delta = axis == .horizontal && dx != 0 ? -dx * (precise ? 1 : 20) : nil
        return Update(delta: delta, finished: ending && axis == .horizontal)
    }
}
