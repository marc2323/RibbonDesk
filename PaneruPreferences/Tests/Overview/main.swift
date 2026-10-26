import Foundation

let data = Data("""
{"active":{"display_id":1,"native_workspace_id":2,"virtual_workspace_number":1},"virtual_workspaces":[{"number":1,"native_workspace_id":2,"active":true,"windows":[
{"window_id":42,"bundle_id":"app","app_name":"App","title":"Right parked","focused":false,"floating":false,"visible":false,"frame":{"x":9999,"y":0,"width":600,"height":800}},
{"window_id":7,"bundle_id":"app","app_name":"App","title":"Left parked","focused":true,"floating":false,"visible":true,"frame":{"x":-9999,"y":0,"width":1200,"height":800}},
{"window_id":8,"bundle_id":"app","app_name":"App","title":"Float","focused":false,"floating":true,"visible":true,"frame":null}
]}]}
""".utf8)
let snapshot = try JSONDecoder().decode(RibbonSnapshot.self, from: data)
precondition(snapshot.ribbon.map(\.id) == [42, 7], "Use engine order, never parked screen coordinates")
for count in [0, 1, 2, 10, 50, 200, 1000] {
    let windows = (0..<count).map { snapshot.ribbon[$0 % 2] }
    let camera = RibbonCamera(windows: windows)
    for available in [320.0, 1280, 3456] {
        let fit = camera.fit(width: available, height: 900, inset: 20)
        precondition(camera.bounds.width * fit.scale <= available + 0.001)
        precondition(camera.bounds.height * fit.scale <= 900 + 0.001)
        precondition(fit.scale.isFinite && fit.scale > 0 && fit.scale <= 1)
        for placement in camera.placements {
            precondition(placement.frame.x * fit.scale + fit.x >= -0.001)
            precondition((placement.frame.x + placement.frame.width) * fit.scale + fit.x <= available + 0.001)
        }
    }
}
let logicalData = Data("""
{"active":{"display_id":1,"native_workspace_id":2,"virtual_workspace_number":1},"virtual_workspaces":[{"number":1,"native_workspace_id":2,"active":true,"windows":[
{"window_id":1,"bundle_id":"app","app_name":"App","title":"A","focused":true,"floating":false,"visible":true,"frame":{"x":0,"y":0,"width":500,"height":700},"ribbon_frame":{"x":0,"y":0,"width":496,"height":700}},
{"window_id":2,"bundle_id":"app","app_name":"App","title":"B","focused":false,"floating":false,"visible":false,"frame":{"x":99999,"y":0,"width":1000,"height":350},"ribbon_frame":{"x":500,"y":0,"width":996,"height":350}},
{"window_id":3,"bundle_id":"app","app_name":"App","title":"C","focused":false,"floating":false,"visible":false,"frame":{"x":99999,"y":350,"width":1000,"height":350},"ribbon_frame":{"x":500,"y":350,"width":996,"height":350}}
]}]}
""".utf8)
let logical = try JSONDecoder().decode(RibbonSnapshot.self, from: logicalData)
let camera = RibbonCamera(windows: logical.ribbon)
precondition(camera.placements[1].frame.x == camera.placements[2].frame.x, "Stacked windows retain their column")
precondition(camera.placements[2].frame.y == 350, "Preserve vertical stack geometry")
precondition(camera.bounds.width == 1496 && camera.bounds.height == 700, "Ignore parked native positions")
let transform = camera.fit(width: 1200, height: 800)
precondition(abs(camera.placements[1].frame.width / camera.placements[0].frame.width - 996.0 / 496.0) < 0.001)
precondition(transform.scale < 1)
precondition(camera.destination(id: 2, viewportX: 0, width: 1000) == 496)
precondition(camera.destination(id: 1, viewportX: 496, width: 1000) == 0)
precondition(camera.destination(id: nil, viewportX: 123, width: 1000) == 123)
print("Ribbon camera: logical order, uniform scale, stacks, gaps, 1,000 windows, and zoom destinations passed")

let longRibbon: [RibbonWindow] = (0..<1000).map { (index: Int) -> RibbonWindow in
    let frame = RibbonWindow.Frame(x: Double(index) * 604.0, y: 0, width: 600, height: 800)
    return RibbonWindow(window_id: Int32(index), bundle_id: "fixture", app_name: "App", title: "Window", focused: index == 500,
                 floating: false, visible: index == 500, frame: nil,
                 ribbon_frame: frame)
}
let longCamera = RibbonCamera(windows: longRibbon)
let overview = longCamera.overview(width: 1440, height: 900)
precondition(overview.scale == 1.0 / 3.0, "Overview uses one-third scale")
precondition(overview.maxOffset > 0)
let center = longCamera.initialOffset(overview, viewportX: 604 * 500, width: 1440)
let visible = longCamera.visibleIDs(scale: overview.scale, x: overview.x - center, width: 1440)
precondition(visible.contains(500) && visible.count < 10, "Start near the viewport and cull the rest")
let last = longCamera.visibleIDs(scale: overview.scale, x: overview.x - overview.maxOffset, width: 1440)
precondition(last.contains(999) && !last.contains(0), "Scrolling can reach the last window")
precondition(overview.clamped(-100) == 0 && overview.clamped(1e20) == overview.maxOffset)
let shortCamera = RibbonCamera(windows: Array(longRibbon.prefix(2)))
let shortOverview = shortCamera.overview(width: 1440, height: 900)
precondition(abs(shortOverview.maxOffset - 604.0 / 3.0) < 0.001 && shortOverview.scale == 1.0 / 3.0)
precondition(shortOverview.x > 0, "End padding lets either window in a short ribbon reach center")
let shortDisplay = longCamera.overview(width: 1440, height: 250)
precondition(shortDisplay.scale < 1.0 / 3.0 && shortDisplay.scale * 800 <= 154, "Height still fits on short displays")
print("Scrollable overview: one-third scale, initial viewport, culling, endpoints, clamping, short ribbons and short displays passed")

let circular = longCamera.overview(width: 1440, height: 900, infinite: true)
let period = circular.scrollExtent
precondition(circular.loopPeriod == 604_000, "The seam retains the ordinary four-point gap")
precondition(abs(circular.resolvedOffset(-100) - (period - 100)) < 0.001)
precondition(abs(circular.resolvedOffset(period * 25 + 100) - 100) < 0.001)
precondition(circular.resolvedOffset(.infinity) == 0)
let seamOffset = period - 200
let seamX = circular.x - circular.resolvedOffset(seamOffset)
let seamCopies = longCamera.instances(scale: circular.scale, x: seamX, width: 1440, period: circular.loopPeriod, margin: 0)
precondition(seamCopies.contains { $0.id.windowID == 999 } && seamCopies.contains { $0.id.windowID == 0 },
             "The last and first previews share one continuous viewport")
precondition(seamCopies.count < 12, "A thousand-window ribbon still renders only nearby copies")
precondition(Set(seamCopies.map(\.id)).count == seamCopies.count)
for copy in seamCopies {
    let x = min(1439, max(0, (copy.frame.x + copy.frame.width / 2) * circular.scale + seamX))
    let y = (copy.frame.y + copy.frame.height / 2) * circular.scale + circular.y
    precondition(longCamera.windowAt(x: x, y: y, width: 1440, height: 900, offset: seamOffset, infinite: true) == copy.id.windowID,
                 "Hit testing resolves the original window through every visible lap")
}
let firstCopy = seamCopies.first { $0.id.windowID == 0 }!
let firstX = (firstCopy.frame.x + firstCopy.frame.width / 2) * circular.scale + seamX
let shift = longCamera.sceneShift(id: 0, overview: circular, offset: seamOffset, width: 1440, preferredX: firstX)
precondition(shift == circular.loopPeriod, "Entry animation follows the chosen copy")
precondition(firstCopy.frame.x - shift == longCamera.placements[0].frame.x)
let shortLoop = shortCamera.overview(width: 1440, height: 900, infinite: true)
let repeated = shortCamera.instances(scale: shortLoop.scale, x: shortLoop.x, width: 1440, period: shortLoop.loopPeriod, margin: 0)
precondition(repeated.count > 2 && repeated.count < 16, "Short ribbons fill the viewport with bounded preview copies")
precondition(Set(repeated.map { $0.id.windowID }) == [0, 1], "Copies share the existing preview cache")
let singleCamera = RibbonCamera(windows: Array(longRibbon.prefix(1)))
precondition(singleCamera.overview(width: 1440, height: 900, infinite: true).loopPeriod == nil)
precondition(RibbonCamera(windows: []).overview(width: 1440, height: 900, infinite: true).loopPeriod == nil)
let stackLoop = camera.overview(width: 1200, height: 800, infinite: true)
precondition(stackLoop.loopPeriod == 1500)
let stackCopies = camera.instances(scale: stackLoop.scale, x: stackLoop.x, width: 1200, period: stackLoop.loopPeriod)
for bottom in stackCopies.filter({ $0.id.windowID == 3 }) {
    let top = stackCopies.first { $0.id.windowID == 2 && $0.id.lap == bottom.id.lap }!
    precondition(top.frame.x == bottom.frame.x && bottom.frame.y == 350)
}
let reveal = longCamera.revealingOffset(id: 0, overview: circular, offset: seamOffset, width: 1440)
precondition(abs(reveal - seamOffset) < 0.001, "Revealing the first window at the seam must not traverse the whole ribbon")
print("Infinite overview: both directions, repeated laps, seam gap, exact hit testing, stacks, short ribbons, entry animation and bounded culling passed")

let changes = RibbonOverviewChanges()
precondition(!changes.consume(Data("{\"event\":\"window_title_changed\",\"title\":\"busy\"}\n{\"event\":\"window_focused\"}\n".utf8)))
precondition(!changes.consume(Data("{\"event\":\"windows_".utf8)))
precondition(changes.consume(Data("changed\"}\n{\"event\":\"window_title_changed\"}\n".utf8)))
precondition(changes.consume(Data("{\"event\":\"on_screen_changed\"}\n".utf8)))
print("Subscription filtering: fragmented packets and geometry-only refresh passed")

var instantHandoff = RibbonHandoffGate(targetID: 42, animationFinished: true)
precondition(!instantHandoff.canReveal, "Instant switching still covers native focus/placement work")
instantHandoff.acknowledge(7)
precondition(!instantHandoff.canReveal, "An acknowledgment for another window must not uncover it")
instantHandoff.acknowledge(42)
precondition(instantHandoff.canReveal)
var animatedHandoff = RibbonHandoffGate(targetID: 42, animationFinished: false)
animatedHandoff.acknowledge(42)
precondition(!animatedHandoff.canReveal)
animatedHandoff.animationFinished = true
precondition(animatedHandoff.canReveal)
var reversedHandoff = RibbonHandoffGate(targetID: 7, animationFinished: false)
reversedHandoff.animationFinished = true
precondition(!reversedHandoff.canReveal)
reversedHandoff.acknowledge(7)
precondition(reversedHandoff.canReveal)
print("Overview handoff: instant and animated switching wait for the matching native target in either completion order")


let hitCamera = RibbonCamera(windows: logical.ribbon)
let hitOverview = hitCamera.overview(width: 1200, height: 800)
func hit(_ logicalX: Double, _ logicalY: Double) -> Int32? {
    hitCamera.windowAt(x: logicalX * hitOverview.scale + hitOverview.x,
                       y: logicalY * hitOverview.scale + hitOverview.y,
                       width: 1200, height: 800, offset: 0)
}
precondition(hit(100, 100) == 1)
precondition(hit(600, 100) == 2 && hit(600, 500) == 3, "Resolve both vertical stack members")
precondition(hit(498, 100) == nil && hit(600, 701) == nil, "Gaps and background are not windows")
let hoveredFrame = longCamera.placements[500].frame
let hoveredX = (hoveredFrame.x + hoveredFrame.width / 2) * overview.scale + overview.x - center
let hoveredY = (hoveredFrame.y + hoveredFrame.height / 2) * overview.scale + overview.y
precondition(longCamera.windowAt(x: hoveredX, y: hoveredY, width: 1440, height: 900, offset: center) == 500,
             "Pointer hit testing uses the scrolled overview camera")
precondition(longCamera.windowAt(x: -1, y: hoveredY, width: 1440, height: 900, offset: center) == nil)
let overlap = RibbonWindow(window_id: 99, bundle_id: "fixture", app_name: "App", title: "Top", focused: true,
    floating: false, visible: true, frame: nil, ribbon_frame: logical.ribbon[1].ribbon_frame)
let overlapCamera = RibbonCamera(windows: [logical.ribbon[1], overlap])
let overlapView = overlapCamera.overview(width: 1200, height: 800)
precondition(overlapCamera.windowAt(x: 600 * overlapView.scale + overlapView.x,
    y: 100 * overlapView.scale + overlapView.y, width: 1200, height: 800, offset: 0) == 99,
    "Overlaps use the same focused-window z-order as rendering")
print("Pointer entry: panning, stacks, gaps, background, panel boundaries and overlap z-order passed")

var moves = RibbonReorderQueue()
let four = Array(longRibbon.prefix(4))
moves.append(id: 1, delta: -1)
precondition(moves.next(windows: four) == .init(id: 1, target: 0, after: false))
moves.append(id: 1, delta: 1)
moves.append(id: 1, delta: 1)
precondition(moves.next(windows: [four[1], four[0], four[2], four[3]]) == .init(id: 1, target: 0, after: true))
precondition(moves.next(windows: four) == .init(id: 1, target: 2, after: true), "Each repeat uses the latest order")
moves.append(id: 0, delta: -1)
moves.append(id: 9999, delta: 1)
precondition(moves.next(windows: four) == nil, "Boundaries and removed windows do not move another window")
let extra = RibbonWindow(window_id: 4, bundle_id: "fixture", app_name: "App", title: "D", focused: false,
    floating: false, visible: false, frame: nil, ribbon_frame: .init(x: 1500, y: 0, width: 600, height: 700))
let stacked = logical.ribbon + [extra]
moves.append(id: 2, delta: 1)
precondition(moves.next(windows: stacked) == .init(id: 2, target: 4, after: true), "Skip stack siblings when moving right")
moves.append(id: 3, delta: -1)
precondition(moves.next(windows: stacked) == .init(id: 3, target: 1, after: false), "Skip stack siblings when moving left")
moves.append(id: 1, delta: 1)
moves.clear()
precondition(moves.next(windows: four) == nil, "Closing or entering clears pending repeat steps")
print("Keyboard arrangement: both directions, serial repeats, fresh order, boundaries, removed IDs and whole columns passed")
precondition(ribbonSelection(after: [four[0], four[2], four[3]], previous: four, selectedID: 1) == 2,
             "Closing a selected window chooses its next neighbor")
precondition(ribbonSelection(after: Array(four.prefix(3)), previous: four, selectedID: 3) == 2,
             "Closing the last window chooses the previous neighbor")
precondition(ribbonSelection(after: [four[3]], previous: four, selectedID: 1) == 3,
             "Quitting an app can remove multiple windows at once")
precondition(ribbonSelection(after: four, previous: four, selectedID: 2) == 2,
             "A canceled close keeps the selected window")
precondition(ribbonSelection(after: [], previous: four, selectedID: 0) == nil)
print("Close/quit selection: neighbors, multiple removals, canceled close, and empty ribbon passed")
let paddedSibling = RibbonWindow(window_id: 3, bundle_id: "fixture", app_name: "App", title: "Padded stack", focused: false,
    floating: false, visible: false, frame: nil, ribbon_frame: .init(x: 506, y: 350, width: 984, height: 350))
moves.append(id: 2, delta: 1)
precondition(moves.next(windows: [logical.ribbon[0], logical.ribbon[1], paddedSibling, extra]) == .init(id: 2, target: 4, after: true),
             "Different per-window padding must not split a stack")

func coastDistance(frequency: Double) -> Double {
    var motion = RibbonOverviewMomentum()
    precondition(motion.advance(at: 0) == nil, "Idle overview has no momentum work")
    motion.begin(at: 100)
    for step in 1...6 {
        motion.move(by: 20, at: 100 + Double(step) / 60)
        precondition(motion.advance(at: 100 + Double(step) / 60) == nil, "Never coast under stationary fingers")
    }
    motion.end(at: 100.11)
    precondition(motion.coasting && !motion.touching)
    var total = 0.0
    for frame in 1...Int(frequency * 3) {
        guard let delta = motion.advance(at: 100.11 + Double(frame) / frequency) else { break }
        precondition(delta > 0 && delta < 30, "Small forward steps preserve release direction")
        total += delta
    }
    precondition(!motion.coasting && motion.velocity == 0)
    precondition(motion.advance(at: 110) == nil, "A settled coast stops scheduling frames")
    return total
}
let coast60 = coastDistance(frequency: 60)
let coast120 = coastDistance(frequency: 120)
precondition(coast60 > 200 && coast60 < 250 && abs(coast60 - coast120) < 0.5,
             "60/120 Hz use the same continuous decay and travel")
var motion = RibbonOverviewMomentum()
motion.begin(at: 1)
motion.move(by: 20, at: 1.02)
motion.end(at: 1.2)
precondition(!motion.coasting, "Pausing before finger lift stops deliberately")
motion.begin(at: 2)
motion.move(by: 20, at: 2.02)
motion.move(by: -20, at: 2.04)
motion.end(at: 2.05)
precondition((motion.advance(at: 2.07) ?? 0) < 0, "Reversal takes effect immediately")
motion.begin(at: 3)
precondition(!motion.coasting && motion.velocity == 0 && motion.touching, "A new contact catches an old coast")
motion.move(by: 20, at: 3.02)
motion.end(at: 3.03)
let delayed = motion.advance(at: 13.03) ?? 0
precondition(delayed > 0 && delayed < 34 && !motion.coasting, "A delayed frame decays without jumping across the ribbon")
motion.move(by: 20, at: 14)
motion.cancel()
precondition(motion.advance(at: 15) == nil && !motion.touching)
print("Overview momentum: smooth release, 60/120 Hz, pause-to-stop, reversal, new contact, cancellation, delayed frames and idle shutdown passed")

precondition(snapshot.overviewOriginID == 7, "Legacy snapshots retain their focused starting window")
var focusedDocument = try JSONSerialization.jsonObject(with: data) as! [String: Any]
var activeDocument = focusedDocument["active"] as! [String: Any]
activeDocument["focused_window_id"] = 42
focusedDocument["active"] = activeDocument
let exactOrigin = try JSONDecoder().decode(RibbonSnapshot.self, from: JSONSerialization.data(withJSONObject: focusedDocument))
precondition(exactOrigin.overviewOriginID == 42, "Exact native focus wins over stale per-window focus flags")
let originCopy = shortCamera.originInstance(id: 0, instances: repeated, scale: shortLoop.scale, x: shortLoop.x, width: 1440)
precondition(originCopy?.id.windowID == 0, "Only one visible origin copy receives the landmark")
precondition(shortCamera.originInstance(id: 9999, instances: repeated, scale: shortLoop.scale, x: shortLoop.x, width: 1440) == nil,
             "Closing the starting window removes its landmark without transferring it")
precondition(shortCamera.originInstance(id: nil, instances: repeated, scale: shortLoop.scale, x: shortLoop.x, width: 1440) == nil)
print("Overview origin: exact native focus, legacy snapshots, one landmark across repeated copies and removed-window behavior passed")

func assertOriginCentered(_ camera: RibbonCamera, id: Int32, width: Double, height: Double, infinite: Bool) {
    let overview = camera.overview(width: width, height: height, infinite: infinite)
    let offset = camera.initialOffset(overview, viewportX: -90_000, width: width, originID: id)
    let x = overview.x - overview.resolvedOffset(offset)
    let copies = camera.instances(scale: overview.scale, x: x, width: width, period: overview.loopPeriod, margin: 0)
    let origin = camera.originInstance(id: id, instances: copies, scale: overview.scale, x: x, width: width)!
    let center = (origin.frame.x + origin.frame.width / 2) * overview.scale + x
    precondition(abs(center - width / 2) < 0.001,
                 "Center the starting preview exactly, including at either end and after a circular wrap")
    let y = (origin.frame.y + origin.frame.height / 2) * overview.scale + overview.y
    precondition(camera.windowAt(x: center, y: y, width: width, height: height, offset: offset, infinite: infinite) == id)
}
for infinite in [false, true] {
    for width in [320.0, 1440, 3456] {
        for id in [Int32(0), 500, 999] {
            assertOriginCentered(longCamera, id: id, width: width, height: 900, infinite: infinite)
        }
        for id in [Int32(0), 1] {
            assertOriginCentered(shortCamera, id: id, width: width, height: 900, infinite: infinite)
        }
        assertOriginCentered(singleCamera, id: 0, width: width, height: 900, infinite: infinite)
    }
    for id in [Int32(1), 2, 3] {
        assertOriginCentered(camera, id: id, width: 1200, height: 800, infinite: infinite)
    }
    assertOriginCentered(longCamera, id: 999, width: 1440, height: 250, infinite: infinite)
}
precondition(longCamera.initialOffset(overview, viewportX: 604 * 500, width: 1440, originID: -1) == center,
             "Missing origins retain the viewport fallback")
print("Centered overview entry: first/middle/last, bounded and circular ribbons, mixed widths, stacks, single/short ribbons, display sizes and fallback passed")
