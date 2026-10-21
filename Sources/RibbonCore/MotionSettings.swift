import Foundation

/// User-facing gesture tuning. Every write and decode is bounded so corrupt
/// preferences cannot introduce non-finite deltas or runaway momentum.
public struct RibbonMotionSettings: Codable, Equatable, Sendable {
    public static let speedRange = 0.5...5.0
    public static let sensitivityRange = 0.5...2.0
    public static let accelerationRange = 0.0...1.0
    public static let momentumRange = 0.0...1.0

    public var speed: Double { didSet { speed = Self.bound(speed, to: Self.speedRange, fallback: 2) } }
    public var sensitivity: Double { didSet { sensitivity = Self.bound(sensitivity, to: Self.sensitivityRange, fallback: 1) } }
    public var acceleration: Double { didSet { acceleration = Self.bound(acceleration, to: Self.accelerationRange, fallback: 0.15) } }
    public var momentum: Double { didSet { momentum = Self.bound(momentum, to: Self.momentumRange, fallback: 0.35) } }

    public static let `default` = RibbonMotionSettings()
    /// Unscaled contact math, useful for deterministic gesture fixtures.
    public static let linear = RibbonMotionSettings(speed: 1, acceleration: 0, momentum: 1)

    public init(speed: Double = 2, sensitivity: Double = 1, acceleration: Double = 0.15, momentum: Double = 0.35) {
        self.speed = Self.bound(speed, to: Self.speedRange, fallback: 2)
        self.sensitivity = Self.bound(sensitivity, to: Self.sensitivityRange, fallback: 1)
        self.acceleration = Self.bound(acceleration, to: Self.accelerationRange, fallback: 0.15)
        self.momentum = Self.bound(momentum, to: Self.momentumRange, fallback: 0.35)
    }

    public func normalized() -> Self {
        Self(speed: speed, sensitivity: sensitivity, acceleration: acceleration, momentum: momentum)
    }

    /// Higher sensitivity starts a swipe with less physical finger travel.
    public var activationThreshold: Double { 0.0015 / sensitivity }

    /// Acceleration adds a bounded response to fast finger motion. At zero,
    /// travel is exactly linear at every sampling rate and finger velocity.
    public func travelGain(forVelocity velocity: Double) -> Double {
        guard velocity.isFinite else { return speed }
        return speed * (1 + acceleration * min(abs(velocity) / 1200, 2.5))
    }

    private static func bound(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }

    private enum CodingKeys: String, CodingKey { case speed, sensitivity, acceleration, momentum }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(speed: try values.decodeIfPresent(Double.self, forKey: .speed) ?? 2,
                  sensitivity: try values.decodeIfPresent(Double.self, forKey: .sensitivity) ?? 1,
                  acceleration: try values.decodeIfPresent(Double.self, forKey: .acceleration) ?? 0.15,
                  momentum: try values.decodeIfPresent(Double.self, forKey: .momentum) ?? 0.35)
    }
}
