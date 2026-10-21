import Foundation
import RibbonCore

/// Pure tuning checks run with the layout suite; no preferences, AppKit, input
/// tap, or user windows are touched.
func runMotionSettingsChecks() -> (assertions: Int, failures: Int) {
    var assertions = 0, failures = 0
    func expect(_ value: Bool, _ message: String) {
        assertions += 1
        if !value { failures += 1; print("FAIL Motion tuning: \(message)") }
    }
    func close(_ a: Double, _ b: Double, tolerance: Double = 0.000001) -> Bool { abs(a - b) <= tolerance }
    func contacts(_ x: Double, y: Double = 0.5, count: Int = 3, identity: Int = 0) -> [ThreeFingerSwipe.Contact] {
        (0..<count).map { .init(id: $0 + identity, x: x + Double($0) * 0.03, y: y) }
    }
    func sample(settings: RibbonMotionSettings, displacement: Double, duration: Double) -> ThreeFingerSwipe.Update {
        var gesture = ThreeFingerSwipe(settings: settings)
        _ = gesture.consume(contacts(0.5), at: 1)
        return gesture.consume(contacts(0.5 - displacement), at: 1 + duration)
    }

    let bad = RibbonMotionSettings(speed: .infinity, sensitivity: .nan, acceleration: -100, momentum: 100)
    expect(bad.speed == 2 && bad.sensitivity == 1 && bad.acceleration == 0 && bad.momentum == 1,
           "Initial values are finite and bounded")
    var mutated = RibbonMotionSettings()
    mutated.speed = -10; mutated.sensitivity = 100; mutated.acceleration = .nan; mutated.momentum = -.infinity
    expect(mutated.speed == 0.5 && mutated.sensitivity == 2 && mutated.acceleration == 0.15 && mutated.momentum == 0.35,
           "Direct slider or preference writes remain bounded")
    expect(mutated.normalized() == mutated, "Normalization is stable")
    do {
        let settings = RibbonMotionSettings(speed: 2.5, sensitivity: 1.5, acceleration: 0.75, momentum: 0)
        let decoded = try JSONDecoder().decode(RibbonMotionSettings.self, from: JSONEncoder().encode(settings))
        expect(decoded == settings, "Settings round trip without losing momentum off")
        let partial = try JSONDecoder().decode(RibbonMotionSettings.self, from: Data("{\"speed\":999}".utf8))
        expect(partial.speed == 5 && partial.sensitivity == 1 && partial.acceleration == 0.15 && partial.momentum == 0.35,
               "Older partial settings decode with bounded defaults")
    } catch { expect(false, "Settings Codable failed: \(error)") }

    let linear = RibbonMotionSettings.linear
    let once = sample(settings: linear, displacement: 0.02, duration: 0.02).delta
    let doubled = sample(settings: .init(speed: 2, acceleration: 0), displacement: 0.02, duration: 0.02).delta
    expect(close(once, 48) && close(doubled, once * 2), "Speed multiplies travel exactly once")
    let slow = sample(settings: linear, displacement: 0.02, duration: 0.1).delta
    expect(close(slow, once), "Acceleration zero stays linear at slow and fast finger velocities")
    let acceleratedSlow = sample(settings: .init(speed: 1, acceleration: 1), displacement: 0.02, duration: 0.1).delta
    let acceleratedFast = sample(settings: .init(speed: 1, acceleration: 1), displacement: 0.02, duration: 0.01).delta
    expect(acceleratedFast > acceleratedSlow && acceleratedSlow > once && acceleratedFast <= once * 3.5,
           "Acceleration responds to velocity and remains bounded")
    expect(RibbonMotionSettings(speed: 5, acceleration: 1).travelGain(forVelocity: .infinity).isFinite,
           "Non-finite velocity cannot produce non-finite tuning gain")

    let sensitive = sample(settings: .init(speed: 1, sensitivity: 2, acceleration: 0), displacement: 0.001, duration: 0.01)
    let deliberate = sample(settings: .init(speed: 1, sensitivity: 0.5, acceleration: 0), displacement: 0.001, duration: 0.01)
    expect(sensitive.began && !deliberate.began && deliberate.delta == 0,
           "Sensitivity controls activation threshold with higher meaning easier activation")
    var accumulator = ThreeFingerSwipe(settings: .init(speed: 2.5, sensitivity: 0.5, acceleration: 0, momentum: 0))
    _ = accumulator.consume(contacts(0.5), at: 1)
    var travel = 0.0
    for index in 1...20 {
        travel += accumulator.consume(contacts(0.5 - Double(index) * 0.0002), at: 1 + Double(index) * 0.01).delta
    }
    expect(close(travel, 24), "Threshold delays activation without discarding accumulated finger travel")
    let retainedSettings = accumulator.settings
    accumulator.reset()
    expect(accumulator.settings == retainedSettings, "Gesture reset retains user tuning")
    _ = accumulator.consume(contacts(0.5), at: 2)
    expect(accumulator.consume(contacts(0.45, y: 0.7), at: 2.02).delta == 0,
           "Sensitivity preserves vertical gesture pass-through")
    _ = accumulator.consume([], at: 2.03, phase: .ended)
    _ = accumulator.consume(contacts(0.5), at: 3)
    _ = accumulator.consume(contacts(0.45), at: 3.02)
    expect(accumulator.consume(contacts(0.4, identity: 10), at: 3.03).delta == 0,
           "Tuning preserves identity replacement without jumps")
    expect(accumulator.consume([], at: 3.04, phase: .cancelled).velocity == 0,
           "Cancellation suppresses coasting at all tuning values")

    func coastDistance(amount: Double, hz: Double) -> Double {
        var momentum = SwipeMomentum(velocity: 1500, amount: amount), travel = 0.0
        for _ in 0..<400 where !momentum.finished { travel += momentum.step(seconds: 1 / hz) }
        expect(momentum.finished, "Coasting terminates at \(hz) Hz / amount \(amount)")
        return travel
    }
    var off = SwipeMomentum(velocity: 8000, amount: 0)
    expect(off.finished && off.step(seconds: 1 / 60) == 0, "Momentum off never coasts")
    var invalid = SwipeMomentum(velocity: .nan, amount: 1)
    expect(invalid.finished && invalid.step(seconds: 1) == 0, "Non-finite momentum velocity is stopped")
    invalid = SwipeMomentum(velocity: 8000, amount: .infinity)
    expect(invalid.finished, "Non-finite momentum amount is stopped")
    let full = coastDistance(amount: 1, hz: 60), half = coastDistance(amount: 0.5, hz: 60)
    expect(half > 0 && half < full * 0.51 && half > full * 0.48,
           "Momentum amount meaningfully reduces travel after release")
    let standard60 = coastDistance(amount: 0.35, hz: 60), standard120 = coastDistance(amount: 0.35, hz: 120)
    expect(close(standard60, standard120, tolerance: 0.5), "User momentum amount remains frame-rate independent")
    var quick = SwipeMomentum(velocity: 8000, amount: 0.35), elapsed = 0.0
    expect(quick.velocity == 8000, "Low momentum preserves continuous velocity at lift")
    for _ in 0..<110 where !quick.finished { _ = quick.step(seconds: 0.005); elapsed += 0.005 }
    expect(quick.finished && elapsed <= 0.350001, "Strongest default flick finishes within 0.35 seconds")
    var legacy = SwipeMomentum(velocity: 4000), explicitFull = SwipeMomentum(velocity: 4000, amount: 1)
    var identical = true
    for _ in 0..<200 {
        identical = identical && legacy.step(seconds: 1 / 120) == explicitFull.step(seconds: 1 / 120)
    }
    expect(identical && legacy.finished && explicitFull.finished, "Momentum amount one preserves legacy coasting")
    print("\(failures == 0 ? "PASS" : "FAIL") Motion tuning (\(assertions) assertions; \(failures) failures)")
    return (assertions, failures)
}
