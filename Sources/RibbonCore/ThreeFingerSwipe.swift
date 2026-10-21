import Foundation

/// Finger travel excludes generated momentum, so a short flick can express
/// navigation intent without projecting the same release velocity twice.
public struct RibbonSwipeCompletion: Equatable, Sendable {
    public var directTravel: Double
    public var releaseVelocity: Double
    public var cancelled: Bool
    public init(directTravel: Double = 0, releaseVelocity: Double = 0, cancelled: Bool = false) {
        self.directTravel = directTravel
        self.releaseVelocity = releaseVelocity
        self.cancelled = cancelled
    }
    public var flickDirection: Int {
        guard !cancelled, directTravel.isFinite, releaseVelocity.isFinite,
              abs(directTravel) >= 8, abs(releaseVelocity) >= 180,
              directTravel * releaseVelocity > 0 else { return 0 }
        return directTravel > 0 ? 1 : -1
    }
}

/// Normalized contacts, independent of AppKit. Identity matching prevents jumps
/// when fingers land, lift, or are replaced.
public struct ThreeFingerSwipe {
    public struct Contact {
        public let id: AnyHashable
        public let x: Double
        public let y: Double
        public init(id: AnyHashable, x: Double, y: Double) { self.id = id; self.x = x; self.y = y }
    }
    public enum Phase { case changed, ended, cancelled }
    public struct Update {
        public var began = false
        public var delta = 0.0
        public var finished = false
        public var velocity = 0.0
        public var completion: RibbonSwipeCompletion? = nil
    }
    private enum Axis { case undecided, horizontal, vertical }
    private var previous: [AnyHashable: Contact] = [:]
    private var axis = Axis.undecided
    private var pendingX = 0.0, pendingY = 0.0
    private var lastTime = 0.0, lastMotion = 0.0, velocity = 0.0
    private var directTravel = 0.0
    public var isHorizontal: Bool { axis == .horizontal }
    public var hasThreeFingerContact: Bool { previous.count == 3 }
    public var settings: RibbonMotionSettings
    public init(settings: RibbonMotionSettings = .linear) { self.settings = settings.normalized() }
    public mutating func reset() { self = Self(settings: settings) }

    public mutating func consume(_ contacts: [Contact], at time: Double, phase: Phase = .changed) -> Update {
        if phase != .changed {
            // A short flick may only produce a baseline and a lift sample.
            // Consume its final positions before ending, including the first
            // staggered lift, but only after tracking three actual contacts.
            var result = Update()
            if phase == .ended, time.isFinite, time > lastTime, hasThreeFingerContact,
               contacts.count >= 2, contacts.count <= 3,
               contacts.allSatisfy({ $0.x.isFinite && $0.y.isFinite && previous[$0.id] != nil }),
               Set(contacts.map(\.id)).count == contacts.count {
                let count = Double(contacts.count)
                let dx = contacts.reduce(0.0) { $0 + $1.x - previous[$1.id]!.x } / count
                let dy = contacts.reduce(0.0) { $0 + $1.y - previous[$1.id]!.y } / count
                result = motion(dx: dx, dy: dy, seconds: time - lastTime, at: time)
            }
            result.finished = isHorizontal
            result.velocity = phase == .ended && time.isFinite && time >= lastMotion && time - lastMotion <= 0.09 ? velocity : 0
            if result.finished {
                result.completion = RibbonSwipeCompletion(directTravel: directTravel,
                    releaseVelocity: result.velocity, cancelled: phase == .cancelled)
            }
            reset(); return result
        }
        // AppKit interleaves empty non-ending events. They are not finger lifts.
        guard !contacts.isEmpty else { return Update() }
        guard time.isFinite, contacts.count == 3,
              contacts.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              Set(contacts.map(\.id)).count == 3 else {
            let result = interruption()
            reset(); return result
        }
        let current = Dictionary(uniqueKeysWithValues: contacts.map { ($0.id, $0) })
        guard Set(current.keys) == Set(previous.keys), time > lastTime else {
            let result = interruption()
            reset(); previous = current; lastTime = time
            return result
        }
        let dx = contacts.reduce(0.0) { $0 + $1.x - previous[$1.id]!.x } / 3
        let dy = contacts.reduce(0.0) { $0 + $1.y - previous[$1.id]!.y } / 3
        let dt = time - lastTime
        previous = current; lastTime = time
        return motion(dx: dx, dy: dy, seconds: dt, at: time)
    }

    private func interruption() -> Update {
        Update(finished: isHorizontal, completion: isHorizontal
            ? RibbonSwipeCompletion(directTravel: directTravel, cancelled: true) : nil)
    }

    private mutating func motion(dx: Double, dy: Double, seconds dt: Double, at time: Double) -> Update {
        var movement = dx
        var began = false
        if axis == .undecided {
            pendingX += dx; pendingY += dy
            guard max(abs(pendingX), abs(pendingY)) >= settings.activationThreshold else { return Update() }
            guard abs(pendingX) != abs(pendingY) else { return Update() }
            axis = abs(pendingX) > abs(pendingY) ? .horizontal : .vertical
            movement = pendingX; pendingX = 0; pendingY = 0
            began = isHorizontal
        }
        guard isHorizontal else { return Update() }
        // Moving fingers left reveals columns to the right (natural direction).
        let rawVelocity = -dx * 2400 / max(dt, 0.004)
        let gain = settings.travelGain(forVelocity: rawVelocity)
        let delta = -movement * 2400 * gain
        let instantaneous = max(-8000, min(8000, rawVelocity * gain))
        // Stationary lift samples must not erase the velocity of a fresh flick.
        if abs(dx) > 0.00003 {
            if instantaneous * velocity <= 0 { velocity = instantaneous }
            else { velocity = velocity * 0.55 + instantaneous * 0.45 }
            lastMotion = time
        }
        directTravel += delta
        return Update(began: began, delta: delta)
    }
}

/// Raw three-contact gestures have no scroll-wheel momentum stream. Integrating
/// this bounded exponential makes coasting distance independent of frame rate.
public struct SwipeMomentum {
    public private(set) var velocity: Double
    private var elapsed = 0.0
    private let decayRate: Double
    private let durationLimit: Double
    public var finished: Bool { abs(velocity) < 20 || elapsed >= durationLimit }
    public init(velocity: Double, amount: Double = 1) {
        let boundedAmount = amount.isFinite ? max(0, min(1, amount)) : 0
        self.velocity = velocity.isFinite && boundedAmount > 0 ? max(-8000, min(8000, velocity)) : 0
        // Preserve lift velocity, with a firmer decay and shorter tail. Amount
        // still scales both distance and duration; default coast is <=350 ms.
        decayRate = 5 / max(0.001, boundedAmount)
        durationLimit = boundedAmount
    }
    public mutating func step(seconds: Double) -> Double {
        guard !finished, seconds.isFinite, seconds > 0 else { return 0 }
        let dt = min(seconds, 0.05, durationLimit - elapsed)
        let decay = exp(-decayRate * dt)
        let delta = velocity * -expm1(-decayRate * dt) / decayRate
        velocity *= decay; elapsed += dt
        return delta
    }
}
