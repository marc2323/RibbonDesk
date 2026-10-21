import Foundation
import RibbonCore

/// Regression scenarios taken from brief swipes, fast reversals, and interrupted
/// snapping. These operate only on pure input/layout models.
func runGestureSettlementChecks() -> (assertions: Int, failures: Int) {
    var assertions = 0, failures = 0
    func expect(_ value: Bool, _ message: String) {
        assertions += 1
        if !value { failures += 1; print("FAIL Gesture settlement: \(message)") }
    }
    func close(_ a: Double, _ b: Double, tolerance: Double = 0.000001) -> Bool {
        a.isFinite && b.isFinite && abs(a - b) <= tolerance
    }
    func contacts(_ x: Double, y: Double = 0.5, count: Int = 3) -> [ThreeFingerSwipe.Contact] {
        (0..<count).map { .init(id: $0, x: x + Double($0) * 0.03, y: y) }
    }
    let tuned = RibbonMotionSettings(speed: 1.05, sensitivity: 0.7, acceleration: 0.1, momentum: 0.25)
    let viewport = Frame(x: -1868, y: 30, width: 1868, height: 1050)
    let half = StripState.halfScreenWidth(in: viewport), pitch = half + StripState.gap
    func strip() -> StripState {
        StripState(items: (0..<8).map { .init(id: "w\($0)", title: "Test", appName: "Test", width: half) },
                   edgeInset: 0, layoutMode: .halfScreen)
    }
    func target(travel: Double, start: Double = 0, completion: RibbonSwipeCompletion?) -> Double {
        var state = strip()
        state.scroll(by: travel, in: viewport)
        return state.gestureSnapOffset(in: viewport, startingAt: start, completion: completion)
    }

    var short = ThreeFingerSwipe(settings: tuned)
    _ = short.consume(contacts(0.5), at: 1)
    let shortMotion = short.consume(contacts(0.496), at: 1.012)
    let shortEnd = short.consume(contacts(0.496), at: 1.018, phase: .ended)
    expect(shortMotion.began && shortMotion.delta > 8 && shortMotion.delta < 20,
           "A one-sample flick is recognized with the user's saved low speed and sensitivity")
    expect(shortEnd.finished && shortEnd.completion?.flickDirection == 1,
           "A stationary lift preserves a recent short flick's release velocity")
    expect(close(target(travel: shortMotion.delta, completion: shortEnd.completion), pitch),
           "Recognized short flick advances one half-screen instead of rounding back to its starting slot")

    for finalCount in [2, 3] {
        var releaseOnly = ThreeFingerSwipe(settings: tuned)
        _ = releaseOnly.consume(contacts(0.5), at: 2)
        let result = releaseOnly.consume(contacts(0.496, count: finalCount), at: 2.012, phase: .ended)
        expect(result.began && result.finished && result.delta > 8 && result.completion?.flickDirection == 1,
               "A final \(finalCount)-contact release sample retains short swipe travel and intent")
        expect(close(target(travel: result.delta, completion: result.completion), pitch),
               "Final release movement can reach the next grid slot")
        let laterLift = releaseOnly.consume(contacts(0.49, count: 1), at: 2.02, phase: .ended)
        expect(!laterLift.began && !laterLift.finished && laterLift.delta == 0,
               "Remaining staggered lifts cannot finish or move the ribbon twice")
    }

    var split = ThreeFingerSwipe(settings: tuned)
    _ = split.consume(contacts(0.5), at: 3)
    let below = split.consume(contacts(0.4985), at: 3.006)
    let crossed = split.consume(contacts(0.496), at: 3.012)
    let splitEnd = split.consume([], at: 3.02, phase: .ended)
    expect(!below.began && below.delta == 0 && crossed.began && crossed.delta > 8,
           "Two brief samples accumulate through activation without losing early travel")
    expect(splitEnd.completion?.flickDirection == 1, "Two-sample flick retains release intent")

    var noise = ThreeFingerSwipe(settings: tuned)
    _ = noise.consume(contacts(0.5), at: 4)
    _ = noise.consume(contacts(0.4997), at: 4.005)
    let noiseEnd = noise.consume(contacts(0.4997), at: 4.012, phase: .ended)
    expect(!noiseEnd.began && !noiseEnd.finished && noiseEnd.completion == nil,
           "Subthreshold contact noise cannot gain one-slot flick intent")
    expect(target(travel: 3, completion: .init(directTravel: 3, releaseVelocity: 1200)) == 0,
           "A tiny fast movement below deliberate travel does not advance")

    var slow = ThreeFingerSwipe(settings: tuned)
    _ = slow.consume(contacts(0.5), at: 5)
    let slowMotion = slow.consume(contacts(0.496), at: 5.2)
    let slowEnd = slow.consume([], at: 5.21, phase: .ended)
    expect(slowMotion.began && slowEnd.completion?.flickDirection == 0,
           "A small slow drag has no automatic advance")
    expect(target(travel: slowMotion.delta, completion: slowEnd.completion) == 0,
           "Small slow drag settles back to its nearest grid slot")
    var paused = ThreeFingerSwipe(settings: tuned)
    _ = paused.consume(contacts(0.5), at: 6)
    _ = paused.consume(contacts(0.496), at: 6.012)
    expect(paused.consume([], at: 6.2, phase: .ended).completion?.flickDirection == 0,
           "A hold before lift expires old flick intent")

    var reversal = ThreeFingerSwipe(settings: tuned)
    _ = reversal.consume(contacts(0.5), at: 7)
    let forward = reversal.consume(contacts(0.48), at: 7.02)
    let back = reversal.consume(contacts(0.487), at: 7.025)
    let reverseEnd = reversal.consume([], at: 7.03, phase: .ended)
    expect(forward.delta > 0 && back.delta < 0 && reverseEnd.velocity < 0,
           "Direction changes take effect on their first sample")
    expect(reverseEnd.completion?.flickDirection == 0 &&
           target(travel: forward.delta + back.delta, completion: reverseEnd.completion) == 0,
           "A reversal against net travel cannot force an unwanted advance")

    var vertical = ThreeFingerSwipe(settings: tuned)
    _ = vertical.consume(contacts(0.5), at: 8)
    _ = vertical.consume(contacts(0.496, y: 0.47), at: 8.012)
    let verticalEnd = vertical.consume(contacts(0.48, y: 0.47), at: 8.02, phase: .ended)
    expect(!verticalEnd.began && !verticalEnd.finished && verticalEnd.delta == 0,
           "Release motion preserves vertical axis lock")
    var two = ThreeFingerSwipe(settings: tuned)
    _ = two.consume(contacts(0.5, count: 2), at: 9)
    let twoEnd = two.consume(contacts(0.48, count: 2), at: 9.012, phase: .ended)
    expect(!twoEnd.began && !twoEnd.finished && twoEnd.delta == 0,
           "Two-finger input cannot become a three-finger flick at lift")
    var cancelled = ThreeFingerSwipe(settings: tuned)
    _ = cancelled.consume(contacts(0.5), at: 10)
    _ = cancelled.consume(contacts(0.48), at: 10.012)
    let cancellation = cancelled.consume([], at: 10.02, phase: .cancelled)
    expect(cancellation.velocity == 0 && cancellation.completion?.cancelled == true &&
           cancellation.completion?.flickDirection == 0, "Cancellation never produces flick bias or inertia")

    let right = RibbonSwipeCompletion(directTravel: 12, releaseVelocity: 600)
    let left = RibbonSwipeCompletion(directTravel: -12, releaseVelocity: -600)
    expect(target(travel: 0, completion: left) == 0, "Outward flick at the first slot stays bounded")
    expect(close(target(travel: 99_999, start: 6 * pitch, completion: right), 6 * pitch),
           "Outward flick at the last slot stays bounded")
    expect(close(target(travel: 0.8 * pitch, start: 0.7 * pitch, completion: right), pitch),
           "Forward flick during unfinished settling reaches the next boundary without skipping a slot")
    expect(target(travel: 0.6 * pitch, start: 0.7 * pitch, completion: left) == 0,
           "Reverse flick during unfinished settling reaches the preceding boundary")
    expect(close(target(travel: 2.7 * pitch, completion: .init(directTravel: 100, releaseVelocity: 8000)), 3 * pitch),
           "Momentum already delivered to the offset is rounded once, without a second velocity projection")
    expect(close(target(travel: 2.7 * pitch, completion: nil), 3 * pitch),
           "Gesture grid settlement is independent of the old focused window")
    for invalid in [RibbonSwipeCompletion(directTravel: .nan, releaseVelocity: 1000),
                    RibbonSwipeCompletion(directTravel: 10, releaseVelocity: .infinity)] {
        expect(invalid.flickDirection == 0 && target(travel: 10, completion: invalid) == 0,
               "Malformed completion cannot introduce a slot advance")
    }

    expect(StripState.gap == 8 && close(2 * half + StripState.gap, viewport.width),
           "The reduced 8-point air gap keeps two halves fitted exactly")
    for hz in [60.0, 120.0] {
        for (start, end) in [(0.0, pitch), (pitch, 0.0), (200.0, 201.0)] {
            let snap = StripSnap(start: start, target: end)
            expect(snap.duration >= 0.12 && snap.duration <= 0.2,
                   "Snap duration is bounded to 120–200 ms")
            var previous = start
            for index in 1...Int(ceil(snap.duration * hz)) {
                let position = snap.position(after: Double(index) / hz)
                expect(position >= min(start, end) && position <= max(start, end),
                       "Settling never crosses either endpoint at \(hz) Hz")
                expect((position - previous) * (end - start) >= 0,
                       "Settling never reverses direction at \(hz) Hz")
                previous = position
            }
            expect(close(snap.position(after: snap.duration), end), "Snap lands exactly on its grid target")
        }
    }
    func filtered(hz: Double, frames: Int) -> Double {
        (0..<frames).reduce(0.0) { value, _ in StripSmoothing.offset(from: value, to: 100, seconds: 1 / hz) }
    }
    expect(filtered(hz: 60, frames: 1) > 60, "The first displayed frame follows more than 60% of input travel")
    expect(close(filtered(hz: 60, frames: 3), filtered(hz: 120, frames: 6)) && filtered(hz: 60, frames: 3) > 93,
           "Lower-latency smoothing has the same 50 ms response at 60 and 120 Hz")
    let reversed = StripSmoothing.offset(from: 80, to: -100, seconds: 1 / 120)
    expect(reversed < 80 && reversed > -100, "Presentation reverses immediately without overshooting")
    var coast = SwipeMomentum(velocity: 8000, amount: tuned.momentum), elapsed = 0.0
    while !coast.finished && elapsed < 2 {
        _ = coast.step(seconds: 1 / 120)
        elapsed += 1 / 120
    }
    expect(coast.finished && elapsed <= 0.26, "The user's 25% momentum ends within a quarter second")
    expect(tuned == RibbonMotionSettings(speed: 1.05, sensitivity: 0.7, acceleration: 0.1, momentum: 0.25),
           "Gesture refinements preserve saved user motion settings")
    print("\(failures == 0 ? "PASS" : "FAIL") Gesture settlement (\(assertions) assertions; \(failures) failures)")
    return (assertions, failures)
}
