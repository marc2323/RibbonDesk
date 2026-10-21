import Foundation
import Darwin
import RibbonCore

// Dependency-free checks: the installed Command Line Tools do not include XCTest.
private var failures = 0
private var assertions = 0
private func check(_ condition: Bool, _ detail: String, file: StaticString, line: UInt) {
    assertions += 1
    if !condition { failures += 1; print("FAIL \(file):\(line): \(detail)") }
}
private func XCTAssertEqual<T: Equatable>(_ lhs: T, _ rhs: T, file: StaticString = #filePath, line: UInt = #line) {
    check(lhs == rhs, "\(lhs) != \(rhs)", file: file, line: line)
}
private func XCTAssertNear(_ lhs: Double, _ rhs: Double, accuracy: Double = 0.000001,
                           file: StaticString = #filePath, line: UInt = #line) {
    check(lhs.isFinite && rhs.isFinite && abs(lhs - rhs) <= accuracy, "\(lhs) != \(rhs) ± \(accuracy)", file: file, line: line)
}
private func XCTAssertTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    check(value, "Expected true", file: file, line: line)
}
private func XCTAssertNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
    check(value == nil, "Expected nil", file: file, line: line)
}
private func XCTAssertGreaterThanOrEqual<T: Comparable>(_ lhs: T, _ rhs: T, file: StaticString = #filePath, line: UInt = #line) {
    check(lhs >= rhs, "\(lhs) < \(rhs)", file: file, line: line)
}
private func XCTAssertLessThanOrEqual<T: Comparable>(_ lhs: T, _ rhs: T, file: StaticString = #filePath, line: UInt = #line) {
    check(lhs <= rhs, "\(lhs) > \(rhs)", file: file, line: line)
}

final class StripLayoutTests {
    let display = Frame(x: 0, y: 25, width: 1440, height: 850)
    func items(_ widths: [Double]) -> [StripItem] {
        widths.enumerated().map { StripItem(id: "w\($0.offset)", title: "Test", appName: "Test", width: $0.element) }
    }

    func testAddingWindowPreservesExistingWidths() {
        var first = StripState(items: items([450, 620]))
        let initial = first.layout(in: display)
        var extended = StripState(items: items([450, 620, 500, 900]))
        let result = extended.layout(in: display)
        XCTAssertEqual(initial.map(\.frame.width), Array(result.prefix(2)).map(\.frame.width))
        XCTAssertEqual(result.map(\.frame.width), [450, 620, 500, 900])
    }

    func testFocusScrollsJustEnoughAndNeverLosesFocusedWindow() {
        var state = StripState(items: items([600, 600, 600, 600]))
        for _ in 0..<12 {
            let layout = state.layout(in: display)
            let focus = layout.first { $0.id == state.focusedID }!
            XCTAssertGreaterThanOrEqual(focus.frame.x, display.x + StripState.inset - 0.001)
            XCTAssertLessThanOrEqual(focus.frame.maxX, display.maxX - StripState.inset + 0.001)
            state.stepFocus(1)
        }
        XCTAssertEqual(state.focusedID, "w3")
        for _ in 0..<12 { state.stepFocus(-1); _ = state.layout(in: display) }
        XCTAssertEqual(state.focusedID, "w0")
        XCTAssertEqual(state.scrollOffset, 0)
    }

    func testVisibleNeighborsDoNotOverlapWhenTheyFit() {
        var state = StripState(items: items([400, 500, 450]))
        let layout = state.layout(in: display)
        XCTAssertEqual(layout[1].frame.x - layout[0].frame.maxX, StripState.gap)
        XCTAssertEqual(layout[2].frame.x - layout[1].frame.maxX, StripState.gap)
    }

    func testOverflowAlwaysKeepsReachableEdgeHandle() {
        var state = StripState(items: items(Array(repeating: 700, count: 12)))
        for _ in 0..<12 {
            let result = state.layout(in: display)
            for placement in result {
                let frame = placement.frame
                let intersection = min(frame.maxX, display.maxX - StripState.inset)
                    - max(frame.x, display.x + StripState.inset)
                if placement.isParked {
                    XCTAssertGreaterThanOrEqual(intersection, min(StripState.edgeHandle, frame.width) - 0.001)
                } else {
                    XCTAssertTrue(intersection > 0)
                }
                XCTAssertEqual(frame.y, display.y + StripState.inset)
                XCTAssertLessThanOrEqual(frame.maxY, display.maxY)
            }
            state.stepFocus(1)
        }
    }

    func testReorderRetainsFocusedIdentityAndWidths() {
        var state = StripState(items: items([300, 400, 500]))
        state.focus("w1"); state.reorderFocused(1)
        XCTAssertEqual(state.items.map(\.id), ["w0", "w2", "w1"])
        XCTAssertEqual(state.focusedID, "w1")
        XCTAssertEqual(state.focusedItem?.width, 400)
        state.reorderFocused(1)
        XCTAssertEqual(state.items.map(\.id), ["w0", "w2", "w1"])
        state.reorderFocused(-1)
        XCTAssertEqual(state.items.map(\.id), ["w0", "w1", "w2"])
    }

    func testFloatsAreAbsentFromLayoutAndNavigation() {
        var state = StripState(items: items([300, 400, 500]))
        state.toggleFloating("w1")
        state.stepFocus(1)
        XCTAssertEqual(state.focusedID, "w2")
        XCTAssertEqual(state.layout(in: display).map(\.id), ["w0", "w2"])
        state.reorderFocused(-1)
        XCTAssertEqual(state.items.map(\.id), ["w2", "w1", "w0"])
        state.toggleFloating("w2"); state.toggleFloating("w0")
        XCTAssertNil(state.focusedID)
        XCTAssertEqual(state.layout(in: display), [])
        state.toggleFloating("w1")
        XCTAssertEqual(state.focusedID, "w1")
    }

    func testWidthPresetsAffectOnlyFocusedItem() {
        var state = StripState(items: items([300, 400, 500]))
        state.focus("w1")
        state.setWidth(fraction: 0.5, viewport: display)
        XCTAssertEqual(state.items.map(\.width), [300, 704, 500])
        state.setWidth(fraction: 1, viewport: display)
        XCTAssertEqual(state.focusedItem?.width, 1408)
        let focus = state.layout(in: display).first { $0.id == "w1" }!
        XCTAssertEqual(focus.frame.x, 16)
        XCTAssertEqual(focus.frame.maxX, 1424)
    }

    func testOversizeAndInvalidInputsCannotProduceUnreachableFrames() {
        var state = StripState(items: items([99999, .nan, -20]))
        let result = state.layout(in: display)
        XCTAssertEqual(result[0].frame.width, 1408)
        XCTAssertTrue(result.allSatisfy { $0.frame.isUsable && $0.frame.width <= 1408 })
        XCTAssertEqual(state.layout(in: Frame(x: 0, y: 0, width: .infinity, height: 500)), [])
        XCTAssertEqual(state.layout(in: Frame(x: 0, y: 0, width: 20, height: 500)), [])
        var empty = StripState()
        empty.stepFocus(1); empty.reorderFocused(-1)
        XCTAssertEqual(empty.layout(in: display), [])
    }

    func testNonzeroDisplayOriginIsRespected() {
        let viewport = Frame(x: -1200, y: 100, width: 1000, height: 700)
        var state = StripState(items: items([400, 500, 600]))
        state.focus("w2")
        let focus = state.layout(in: viewport).first { $0.id == "w2" }!
        XCTAssertGreaterThanOrEqual(focus.frame.x, -1184)
        XCTAssertLessThanOrEqual(focus.frame.maxX, -216)
        XCTAssertEqual(focus.frame.y, 116)
    }

    func testLongNavigationSequenceMaintainsFiniteReachableLayout() {
        var seed: UInt64 = 0x524942424F4E
        func next() -> UInt64 {
            seed = seed &* 6364136223846793005 &+ 1
            return seed
        }
        var state = StripState(items: items((0..<12).map { Double(250 + $0 * 67) }))
        for _ in 0..<1000 {
            switch next() % 5 {
            case 0: state.stepFocus(next() % 2 == 0 ? -1 : 1)
            case 1: state.reorderFocused(next() % 2 == 0 ? -1 : 1)
            case 2: state.setWidth(fraction: [1.0/3, 0.5, 2.0/3, 1][Int(next() % 4)], viewport: display)
            case 3: state.toggleFloating("w\(next() % 12)")
            default: state.focus("w\(next() % 12)")
            }
            let result = state.layout(in: display)
            XCTAssertEqual(Set(result.map(\.id)).count, result.count)
            XCTAssertTrue(result.allSatisfy { $0.frame.isUsable })
            if let id = state.focusedID {
                let focus = result.first { $0.id == id }!
                XCTAssertGreaterThanOrEqual(focus.frame.x, display.x + 16 - 0.001)
                XCTAssertLessThanOrEqual(focus.frame.maxX, display.maxX - 16 + 0.001)
            }
        }
    }

    func testBurstNavigationUsesLatestIntentWithoutIntermediateLayouts() {
        var state = StripState(items: items(Array(repeating: 700, count: 12)))
        // Input can update intent repeatedly before a renderer commits geometry.
        for _ in 0..<1000 { state.stepFocus(1) }
        for _ in 0..<4 { state.stepFocus(-1) }
        XCTAssertEqual(state.focusedID, "w7")
        let committed = state.layout(in: display)
        let focus = committed.first { $0.id == "w7" }!
        XCTAssertEqual(committed.count, 12)
        XCTAssertGreaterThanOrEqual(focus.frame.x, display.x + StripState.inset)
        XCTAssertLessThanOrEqual(focus.frame.maxX, display.maxX - StripState.inset)
        XCTAssertEqual(focus.frame.width, 700)
    }

    func testPanMovesContinuouslyWithoutSnappingToOldFocus() {
        var state = StripState(items: items([700, 700, 700, 700]))
        let original = state.layout(in: display)
        XCTAssertTrue(state.scroll(by: 200, in: display))
        let first = state.layout(in: display, revealFocused: false)
        XCTAssertEqual(state.scrollOffset, 200)
        XCTAssertEqual(state.focusedID, "w0")
        XCTAssertEqual(first[0].frame.x, original[0].frame.x - 200)
        XCTAssertTrue(state.scroll(by: 20, in: display))
        let second = state.layout(in: display, revealFocused: false)
        XCTAssertEqual(second[0].frame.x, first[0].frame.x - 20)
        XCTAssertEqual(second.map(\.frame.width), original.map(\.frame.width))
        XCTAssertEqual(state.items.map(\.id), ["w0", "w1", "w2", "w3"])
        state.focusNearestToCenter(in: display)
        XCTAssertEqual(state.focusedID, "w1")
        let settled = state.layout(in: display).first { $0.id == state.focusedID }!
        XCTAssertGreaterThanOrEqual(settled.frame.x, display.x + StripState.inset)
        XCTAssertLessThanOrEqual(settled.frame.maxX, display.maxX - StripState.inset)
    }

    func testPanClampsBothEndsAndKeepsFloatsOut() {
        var state = StripState(items: items([700, 700, 700, 700]))
        state.scroll(by: 99999, in: display)
        XCTAssertEqual(state.scrollOffset, 4 * 700 + 3 * StripState.gap - (display.width - 2 * StripState.inset))
        state.focusNearestToCenter(in: display)
        // At the tighter gap both tail columns fit symmetrically; equal center
        // distances keep the first eligible column as the stable tie-breaker.
        XCTAssertEqual(state.focusedID, "w2")
        XCTAssertEqual(state.scroll(by: 1, in: display), false)
        state.scroll(by: -99999, in: display)
        XCTAssertEqual(state.scrollOffset, 0)
        state.focusNearestToCenter(in: display)
        XCTAssertEqual(state.focusedID, "w0")
        state.toggleFloating("w1")
        state.scroll(by: 700, in: display)
        let layout = state.layout(in: display, revealFocused: false)
        XCTAssertEqual(layout.map(\.id), ["w0", "w2", "w3"])
        XCTAssertEqual(state.scroll(by: .nan, in: display), false)
        XCTAssertEqual(state.scroll(by: 4, in: Frame(x: 0, y: 0, width: 20, height: 400)), false)
        var empty = StripState()
        XCTAssertEqual(empty.scroll(by: 400, in: display), false)
        empty.focusNearestToCenter(in: display)
        XCTAssertNil(empty.focusedID)
    }

    func testNativeScrollNormalizationRejectsVerticalAndMomentum() {
        XCTAssertEqual(HorizontalScroll.viewportDelta(x: -12, y: 2, precise: true, momentum: false), 12)
        XCTAssertEqual(HorizontalScroll.viewportDelta(x: 12, y: 2, precise: true, momentum: false), -12)
        XCTAssertEqual(HorizontalScroll.viewportDelta(x: 1, y: 0, precise: false, momentum: false), -20)
        XCTAssertNil(HorizontalScroll.viewportDelta(x: 2, y: 20, precise: true, momentum: false))
        XCTAssertNil(HorizontalScroll.viewportDelta(x: 12, y: 2, precise: true, momentum: true))
        XCTAssertNil(HorizontalScroll.viewportDelta(x: .nan, y: 2, precise: true, momentum: false))
        XCTAssertNil(HorizontalScroll.viewportDelta(x: 2, y: .infinity, precise: true, momentum: false))
        XCTAssertNil(HorizontalScroll.viewportDelta(x: 0, y: 0, precise: true, momentum: false))
    }

    func testBurstPanUsesAccumulatedLatestOffset() {
        var state = StripState(items: items(Array(repeating: 700, count: 12)))
        for _ in 0..<1000 { state.scroll(by: 1, in: display) }
        for _ in 0..<1000 { state.scroll(by: -0.75, in: display) }
        XCTAssertEqual(state.scrollOffset, 250)
        let layout = state.layout(in: display, revealFocused: false)
        XCTAssertEqual(layout[0].frame.x, 16 - 250)
        XCTAssertEqual(state.focusedID, "w0")
        for placement in layout {
            XCTAssertTrue(placement.frame.isUsable)
            let visible = min(placement.frame.maxX, display.maxX - 16) - max(placement.frame.x, display.x + 16)
            if placement.isParked { XCTAssertGreaterThanOrEqual(visible, min(StripState.edgeHandle, placement.frame.width)) }
            else { XCTAssertTrue(visible > 0) }
        }
    }

    func testPartlyVisibleWindowsTrackUntilFullyOutside() {
        let viewport = Frame(x: -1000.5, y: 35.5, width: 1440, height: 860.25)
        let half = StripState.halfScreenWidth(in: viewport)
        var state = StripState(items: items(Array(repeating: half, count: 5)), edgeInset: 0, layoutMode: .halfScreen)
        let initial = state.layout(in: viewport, revealFocused: false)
        XCTAssertEqual(StripState.edgeHandle, 5)
        var previousX = initial[0].frame.x
        // Last visible widths include 5, 1, and one eighth point. None may
        // freeze at the former 72-point edge handle while its neighbor moves.
        for offset in [100.0, 600, half - 5, half - 1, half - 0.125] {
            state.scroll(by: offset - state.scrollOffset, in: viewport)
            let layout = state.layout(in: viewport, revealFocused: false)
            let leading = layout[0]
            XCTAssertTrue(!leading.isParked)
            XCTAssertNear(leading.frame.x, viewport.x - offset)
            XCTAssertLessThanOrEqual(leading.frame.x, previousX)
            XCTAssertNear(layout[1].frame.x - leading.frame.maxX, StripState.gap)
            XCTAssertEqual(leading.frame.y, viewport.y)
            XCTAssertEqual(leading.frame.height, viewport.height)
            previousX = leading.frame.x
        }
        state.scroll(by: half - state.scrollOffset, in: viewport)
        let parked = state.layout(in: viewport, revealFocused: false)[0]
        XCTAssertTrue(parked.isParked)
        XCTAssertNear(parked.frame.maxX - viewport.x, 5)
        state.scroll(by: 100, in: viewport)
        XCTAssertEqual(state.layout(in: viewport, revealFocused: false)[0], parked)
        state.scroll(by: -99_999, in: viewport)
        XCTAssertEqual(state.layout(in: viewport, revealFocused: false), initial)
    }

    func testIncomingSliverAndEndpointRestorationKeepSharedGrid() {
        let viewport = Frame(x: 800.25, y: -865.5, width: 1440, height: 860.25)
        let half = StripState.halfScreenWidth(in: viewport), pitch = half + StripState.gap
        var state = StripState(items: items([half, half, half, half, half]), edgeInset: 0, layoutMode: .halfScreen)
        let initial = state.layout(in: viewport, revealFocused: false)
        XCTAssertTrue(initial[2].isParked)
        XCTAssertNear(viewport.maxX - initial[2].frame.x, 5)
        var previousX = Double.infinity
        // Column 2 starts at viewport.maxX + 8. As soon as any real sliver
        // enters, all visible columns share the exact same strip translation.
        for offset in [8.125, 9, 13, 50, 100] {
            state.scroll(by: offset - state.scrollOffset, in: viewport)
            let layout = state.layout(in: viewport, revealFocused: false)
            XCTAssertTrue(!layout[2].isParked)
            XCTAssertNear(layout[2].frame.x, viewport.x + 2 * pitch - offset)
            XCTAssertLessThanOrEqual(layout[2].frame.x, previousX)
            XCTAssertNear(layout[2].frame.x - layout[1].frame.maxX, StripState.gap)
            XCTAssertEqual(layout[2].frame.height, viewport.height)
            previousX = layout[2].frame.x
        }
        state.focus("w4")
        let tail = state.layout(in: viewport)
        XCTAssertNear(state.scrollOffset, 3 * pitch)
        XCTAssertNear(tail[3].frame.x, viewport.x)
        XCTAssertNear(tail[4].frame.maxX, viewport.maxX)
        XCTAssertTrue(!tail[3].isParked && !tail[4].isParked)
        state.focus("w0")
        XCTAssertEqual(state.layout(in: viewport), initial)
        XCTAssertEqual(state.scrollOffset, 0)
    }

    func testTwoHalfColumnsExactlyFillFullUsableHeight() {
        let viewport = Frame(x: -1440, y: 37, width: 1440, height: 863)
        let half = StripState.halfScreenWidth(in: viewport)
        XCTAssertEqual(half, 716)
        var state = StripState(items: items([half, half]), edgeInset: 0, layoutMode: .halfScreen)
        let layout = state.layout(in: viewport)
        XCTAssertEqual(layout[0].frame, Frame(x: -1440, y: 37, width: half, height: 863))
        XCTAssertEqual(layout[1].frame.x - layout[0].frame.maxX, StripState.gap)
        XCTAssertEqual(layout[1].frame.maxX, viewport.maxX)
        XCTAssertTrue(layout.allSatisfy { !$0.isParked })
        XCTAssertEqual(state.scroll(by: 300, in: viewport), false)
        XCTAssertEqual(state.snapOffset(in: viewport), 0)
        state.focus("w1")
        _ = state.layout(in: viewport)
        XCTAssertEqual(state.scrollOffset, 0)
    }

    func testGridOddTailAndFullWidthShareOnePitch() {
        let half = StripState.halfScreenWidth(in: display)
        let pitch = half + StripState.gap
        var odd = StripState(items: items(Array(repeating: half, count: 5)), edgeInset: 0, layoutMode: .halfScreen)
        odd.scroll(by: 99_999, in: display)
        XCTAssertEqual(odd.scrollOffset, 3 * pitch)
        odd.focus("w4")
        XCTAssertEqual(odd.snapOffset(in: display), 3 * pitch)
        let tail = odd.layout(in: display)
        XCTAssertEqual(tail[3].frame.x, display.x)
        XCTAssertEqual(tail[4].frame.maxX, display.maxX)
        XCTAssertTrue(!tail[3].isParked && !tail[4].isParked)
        var mixed = StripState(items: items([half, display.width, half, display.width]), edgeInset: 0, layoutMode: .halfScreen)
        mixed.focus("w1")
        let full = mixed.layout(in: display).first { $0.id == "w1" }!
        XCTAssertEqual(mixed.scrollOffset, pitch)
        XCTAssertEqual(full.frame.x, display.x)
        XCTAssertEqual(full.frame.width, display.width)
        mixed.focus("w3")
        let last = mixed.layout(in: display).first { $0.id == "w3" }!
        XCTAssertEqual(mixed.scrollOffset, 4 * pitch)
        XCTAssertEqual(last.frame.x, display.x)
        XCTAssertEqual(last.frame.maxX, display.maxX)
        mixed.stepFocus(-1)
        let neighbor = mixed.layout(in: display).first { $0.id == "w2" }!
        XCTAssertEqual(mixed.scrollOffset, 3 * pitch)
        XCTAssertEqual(neighbor.frame.x, display.x)
    }

    func testGridGestureIsContinuousAndSettlementSurvivesFocusReveal() {
        let half = StripState.halfScreenWidth(in: display)
        let pitch = half + StripState.gap
        var state = StripState(items: items(Array(repeating: half, count: 6)), edgeInset: 0, layoutMode: .halfScreen)
        let initial = state.layout(in: display)
        state.scroll(by: 201.25, in: display)
        let moving = state.layout(in: display, revealFocused: false)
        XCTAssertEqual(state.scrollOffset, 201.25)
        XCTAssertEqual(state.focusedID, "w0")
        XCTAssertEqual(moving[0].frame.x, initial[0].frame.x - 201.25)
        state.scroll(by: pitch * 1.2, in: display)
        state.focusNearestToCenter(in: display)
        let target = state.snapOffset(in: display)
        XCTAssertNear(target / pitch, (target / pitch).rounded())
        state.scroll(by: target - state.scrollOffset, in: display)
        let settled = state.layout(in: display)
        XCTAssertNear(state.scrollOffset, target)
        let focused = settled.first { $0.id == state.focusedID }!
        XCTAssertGreaterThanOrEqual(focused.frame.x, display.x - 0.000001)
        XCTAssertLessThanOrEqual(focused.frame.maxX, display.maxX + 0.000001)
        _ = state.layout(in: display)
        XCTAssertNear(state.scrollOffset, target)
    }

    func testGridPresetsAndNativeMinimumRoundUpToFullSlot() {
        let half = StripState.halfScreenWidth(in: display)
        var state = StripState(items: items([half, half, half]), edgeInset: 0, layoutMode: .halfScreen)
        state.focus("w1")
        state.setWidth(fraction: 0.5, viewport: display, minimumWidth: half + 0.1)
        XCTAssertEqual(state.items.map(\.width), [half, display.width, half])
        state.setWidth(fraction: 0.5, viewport: display, minimumWidth: half)
        XCTAssertEqual(state.focusedItem?.width, half)
        state.setWidth(fraction: 2.0 / 3, viewport: display)
        XCTAssertEqual(state.focusedItem?.width, display.width)
        state.setWidth(fraction: 1.0 / 3, viewport: display)
        XCTAssertEqual(state.focusedItem?.width, half)
        state.setWidth(fraction: 0.5, viewport: display, minimumWidth: display.width * 4)
        XCTAssertEqual(state.focusedItem?.width, display.width)
        state.setWidth(fraction: .nan, viewport: display)
        XCTAssertEqual(state.focusedItem?.width, display.width)
        // Discovery widths just above half also reserve two full grid slots.
        var discovered = StripState(items: items([half + 1, half]), edgeInset: 0, layoutMode: .halfScreen)
        let layout = discovered.layout(in: display)
        XCTAssertEqual(layout[0].frame.width, display.width)
        XCTAssertEqual(layout[1].frame.width, half)
        XCTAssertEqual(StripState.halfScreenWidth(in: Frame(x: 0, y: 0, width: .nan, height: 10)), 0)
    }

    func testGridEmptySingleInvalidAndTinyViewports() {
        var empty = StripState(edgeInset: 0, layoutMode: .halfScreen)
        XCTAssertEqual(empty.layout(in: display), [])
        XCTAssertEqual(empty.scroll(by: 100, in: display), false)
        empty.focusNearestToCenter(in: display)
        XCTAssertNil(empty.focusedID)
        XCTAssertEqual(empty.snapOffset(in: display), 0)
        let half = StripState.halfScreenWidth(in: display)
        for width in [half, display.width, Double.nan, Double.infinity, -4, 99_999] {
            var single = StripState(items: items([width]), edgeInset: 0, layoutMode: .halfScreen)
            let layout = single.layout(in: display)
            XCTAssertEqual(layout.count, 1)
            XCTAssertTrue(layout[0].frame.isUsable)
            XCTAssertEqual(layout[0].frame.x, display.x)
            XCTAssertEqual(layout[0].frame.height, display.height)
            XCTAssertEqual(single.scroll(by: 100, in: display), false)
            XCTAssertEqual(single.snapOffset(in: display), 0)
        }
        let tiny = Frame(x: -8, y: -2, width: 1, height: 3)
        let tinyHalf = StripState.halfScreenWidth(in: tiny)
        var state = StripState(items: items([tinyHalf, tinyHalf]), edgeInset: 0, layoutMode: .halfScreen)
        let layout = state.layout(in: tiny)
        XCTAssertTrue(layout.allSatisfy { $0.frame.isUsable })
        XCTAssertNear(layout.last!.frame.maxX, tiny.maxX)
        XCTAssertEqual(state.layout(in: Frame(x: 0, y: 0, width: 0, height: 5)), [])
        XCTAssertEqual(state.scroll(by: .infinity, in: display), false)
    }

    func testGridReorderReconcileAndFloatingPreserveIdentity() {
        let half = StripState.halfScreenWidth(in: display)
        var state = StripState(items: items([half, display.width, half, half]), edgeInset: 0, layoutMode: .halfScreen)
        state.focus("w1")
        _ = state.layout(in: display)
        state.reorderFocused(1)
        XCTAssertEqual(state.items.map(\.id), ["w0", "w2", "w1", "w3"])
        XCTAssertEqual(state.focusedID, "w1")
        let full = state.layout(in: display).first { $0.id == "w1" }!
        XCTAssertEqual(full.frame.x, display.x)
        XCTAssertEqual(full.frame.width, display.width)
        let additions = items([half, half, half, half, half])
        state.reconcile(additions)
        XCTAssertEqual(state.items.map(\.id), ["w0", "w2", "w1", "w4", "w3"])
        XCTAssertEqual(state.focusedItem?.width, display.width)
        state.toggleFloating("w1")
        XCTAssertEqual(state.focusedID, "w0")
        XCTAssertTrue(!state.layout(in: display).contains { $0.id == "w1" })
        state.reconcile([additions[2], additions[4]])
        XCTAssertEqual(state.items.map(\.id), ["w2", "w4"])
        XCTAssertEqual(state.focusedID, "w2")
        XCTAssertEqual(state.layout(in: display).map(\.frame.width), [half, half])
        XCTAssertEqual(state.scrollOffset, 0)
    }

    func testGridMixedOperationPropertiesAtFractionalDisplayOrigins() {
        var seed: UInt64 = 0x534E415047524944
        func next() -> UInt64 { seed = seed &* 2862933555777941757 &+ 3037000493; return seed }
        for viewport in [Frame(x: -1512.5, y: 28.5, width: 1512.5, height: 940.25),
                         Frame(x: 1200, y: -820, width: 997, height: 800)] {
            let half = StripState.halfScreenWidth(in: viewport)
            let pitch = half + StripState.gap
            var state = StripState(items: items([half, viewport.width, half + 1, half, .nan, -1]),
                                   edgeInset: 0, layoutMode: .halfScreen)
            for _ in 0..<600 {
                switch next() % 7 {
                case 0: state.stepFocus(next() % 2 == 0 ? -1 : 1)
                case 1: state.reorderFocused(next() % 2 == 0 ? -1 : 1)
                case 2: state.setWidth(fraction: next() % 2 == 0 ? 0.5 : 1, viewport: viewport)
                case 3: state.toggleFloating("w\(next() % 6)")
                case 4: state.focus("w\(next() % 6)")
                default:
                    state.scroll(by: Double(Int(next() % 4000) - 2000), in: viewport)
                    let moving = state.layout(in: viewport, revealFocused: false)
                    XCTAssertTrue(moving.allSatisfy { $0.frame.isUsable })
                    state.focusNearestToCenter(in: viewport)
                    let target = state.snapOffset(in: viewport)
                    XCTAssertNear(target / pitch, (target / pitch).rounded())
                    state.scroll(by: target - state.scrollOffset, in: viewport)
                }
                let result = state.layout(in: viewport)
                XCTAssertNear(state.scrollOffset / pitch, (state.scrollOffset / pitch).rounded())
                XCTAssertEqual(Set(result.map(\.id)).count, result.count)
                for placement in result {
                    XCTAssertTrue(placement.frame.isUsable)
                    XCTAssertEqual(placement.frame.y, viewport.y)
                    XCTAssertEqual(placement.frame.height, viewport.height)
                    XCTAssertTrue(abs(placement.frame.width - half) < 0.000001 || placement.frame.width == viewport.width)
                    if !placement.isParked {
                        let slot = (placement.frame.x - viewport.x) / pitch
                        XCTAssertNear(slot, slot.rounded())
                    }
                }
                if let id = state.focusedID {
                    let focused = result.first { $0.id == id }!
                    XCTAssertGreaterThanOrEqual(focused.frame.x, viewport.x - 0.000001)
                    XCTAssertLessThanOrEqual(focused.frame.maxX, viewport.maxX + 0.000001)
                    XCTAssertTrue(!focused.isParked)
                }
            }
        }
    }

}

@main
struct LayoutChecks {
    static func main() {
        let suite = StripLayoutTests()
        let checks: [(String, () -> Void)] = [
            ("Width preservation", suite.testAddingWindowPreservesExistingWidths),
            ("Focus viewport and endpoints", suite.testFocusScrollsJustEnoughAndNeverLosesFocusedWindow),
            ("Neighbor spacing", suite.testVisibleNeighborsDoNotOverlapWhenTheyFit),
            ("Reachable overflow handles", suite.testOverflowAlwaysKeepsReachableEdgeHandle),
            ("Identity-preserving reorder", suite.testReorderRetainsFocusedIdentityAndWidths),
            ("Floating exclusions", suite.testFloatsAreAbsentFromLayoutAndNavigation),
            ("Width presets", suite.testWidthPresetsAffectOnlyFocusedItem),
            ("Invalid geometry and oversize windows", suite.testOversizeAndInvalidInputsCannotProduceUnreachableFrames),
            ("Display coordinates", suite.testNonzeroDisplayOriginIsRespected),
            ("1,000-operation mixed sequence", suite.testLongNavigationSequenceMaintainsFiniteReachableLayout),
            ("1,004 focus intents before one layout", suite.testBurstNavigationUsesLatestIntentWithoutIntermediateLayouts),
            ("Continuous pan independent of old focus", suite.testPanMovesContinuouslyWithoutSnappingToOldFocus),
            ("Pan endpoints and floating exclusions", suite.testPanClampsBothEndsAndKeepsFloatsOut),
            ("Native horizontal input normalization", suite.testNativeScrollNormalizationRejectsVerticalAndMomentum),
            ("2,000 scroll samples before one layout", suite.testBurstPanUsesAccumulatedLatestOffset),
            ("Partially visible windows track until fully outside", suite.testPartlyVisibleWindowsTrackUntilFullyOutside),
            ("Incoming slivers and endpoint restoration keep shared grid", suite.testIncomingSliverAndEndpointRestorationKeepSharedGrid),
            ("Half pair fills usable screen", suite.testTwoHalfColumnsExactlyFillFullUsableHeight),
            ("Half/full grid and odd tail", suite.testGridOddTailAndFullWidthShareOnePitch),
            ("Continuous gesture and stable grid settlement", suite.testGridGestureIsContinuousAndSettlementSurvivesFocusReveal),
            ("Half/full presets and native minimums", suite.testGridPresetsAndNativeMinimumRoundUpToFullSlot),
            ("Grid empty, single, invalid and tiny geometry", suite.testGridEmptySingleInvalidAndTinyViewports),
            ("Grid reorder, reconcile and floating", suite.testGridReorderReconcileAndFloatingPreserveIdentity),
            ("1,200 grid operations with fractional and negative origins", suite.testGridMixedOperationPropertiesAtFractionalDisplayOrigins)
        ]
        for (name, body) in checks {
            let before = failures
            body()
            print("\(before == failures ? "PASS" : "FAIL") \(name)")
        }
        let motion = runMotionSettingsChecks()
        assertions += motion.assertions
        failures += motion.failures
        let settlement = runGestureSettlementChecks()
        assertions += settlement.assertions
        failures += settlement.failures
        print("\(checks.count) layout checks + motion and settlement checks; \(assertions) assertions; \(failures) failures. Pure RibbonCore only; no AppKit/AX controller launched.")
        exit(failures == 0 ? 0 : 1)
    }
}
