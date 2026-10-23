import Foundation

@MainActor
func waitFor(_ condition: () -> Bool) async {
    for _ in 0..<1000 {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    preconditionFailure("timed out waiting for a settings apply")
}

enum TestFailure: Error { case rejected }

@MainActor
func runAutosaveChecks() async {
    let original = Preferences.defaults
    var first = original
    first.momentum = 1.2
    var latest = first
    latest.threeFingerPaging = false
    latest.momentumDecay = 70
    latest.snapAnimation = 2.5
    latest.snapFullWidth = false
    latest.snapHalfWidth = false
    latest.snapBack = true
    latest.snapExitDistance = 0.3
    latest.speed = 0.8
    latest.snapSpeed = 1.1
    latest.snapVisible = 0.7
    latest.gap = 10
    latest.focusMode = .click
    latest.launchAtLogin = true
    latest.disabledSpaceUUIDs = ["desktop-test"]
    latest.borderEnabled = false
    latest.borderColor = "#112233"

    var calls: [(Preferences, Preferences)] = []
    let coalesced = PreferencesAutosaver(initial: original, interval: 1_000_000) { next, previous in
        calls.append((next, previous))
    }
    coalesced.submit(first)
    coalesced.submit(latest)
    await coalesced.waitUntilIdle()
    assert(calls.count == 1 && calls[0].0 == latest && calls[0].1 == original)
    assert(coalesced.applied == latest && !coalesced.isBusy)
    coalesced.replaceApplied(original)
    coalesced.submit(original)
    assert(calls.count == 1 && !coalesced.isBusy, "refreshing/restoring a saved snapshot must not write it again")

    var release: CheckedContinuation<Void, Never>?
    var serialCalls: [(Preferences, Preferences)] = []
    var concurrent = 0, maximumConcurrent = 0
    let serial = PreferencesAutosaver(initial: original, interval: 1_000_000) { next, previous in
        concurrent += 1
        maximumConcurrent = max(maximumConcurrent, concurrent)
        serialCalls.append((next, previous))
        if serialCalls.count == 1 { await withCheckedContinuation { release = $0 } }
        concurrent -= 1
    }
    serial.submit(first)
    await waitFor { release != nil }
    var intermediate = first
    intermediate.momentum = 1.5
    serial.submit(intermediate)
    serial.submit(latest)
    release?.resume()
    await serial.waitUntilIdle()
    assert(serialCalls.count == 2 && maximumConcurrent == 1)
    assert(serialCalls[1].0 == latest && serialCalls[1].1 == first, "newer edits must survive a slow apply and use the last committed snapshot")
    assert(serial.applied == latest)

    release = nil
    var reversals: [Preferences] = []
    let reversal = PreferencesAutosaver(initial: original, interval: 1_000_000) { next, _ in
        reversals.append(next)
        if reversals.count == 1 { await withCheckedContinuation { release = $0 } }
    }
    reversal.submit(first)
    await waitFor { release != nil }
    reversal.submit(original)
    release?.resume()
    await reversal.waitUntilIdle()
    assert(reversals == [first, original], "reverting during an apply must restore the original after that apply finishes")

    release = nil
    var attempts = 0
    var newerOnFailure: Bool?
    let recovering = PreferencesAutosaver(initial: original, interval: 1_000_000) { next, previous in
        attempts += 1
        if attempts == 1 {
            await withCheckedContinuation { release = $0 }
            throw TestFailure.rejected
        }
        assert(next == latest && previous == original)
    }
    recovering.onFailure = { _, applied, hasNewerEdit in
        assert(applied == original)
        newerOnFailure = hasNewerEdit
    }
    recovering.submit(first)
    await waitFor { release != nil }
    recovering.submit(latest)
    release?.resume()
    await recovering.waitUntilIdle()
    assert(attempts == 2 && newerOnFailure == true && recovering.applied == latest)

    var failures = 0
    let failing = PreferencesAutosaver(initial: original, interval: 1_000_000) { _, _ in
        throw TestFailure.rejected
    }
    failing.onFailure = { _, applied, hasNewerEdit in
        failures += 1
        assert(applied == original && !hasNewerEdit)
    }
    failing.submit(first)
    await failing.waitUntilIdle()
    assert(failures == 1 && failing.applied == original && !failing.isBusy, "failures roll back once without a retry loop")

    var liveCalls = 0
    let continuous = PreferencesAutosaver(initial: original, interval: 1_000_000) { _, _ in
        liveCalls += 1
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    var moving = original
    for step in 1...20 {
        moving.momentum = Double(step) / 10
        continuous.submit(moving)
        try? await Task.sleep(nanoseconds: 3_000_000)
    }
    assert(liveCalls > 1, "continuous dragging must apply before the drag stops")
    await continuous.waitUntilIdle()
    assert(continuous.applied == moving)
    print("Autosave: coalescing all settings, serial writes, pending edits, reversals, rollback, recovery, and continuous live updates passed.")
}

Task { @MainActor in
    await runAutosaveChecks()
    exit(0)
}
dispatchMain()
