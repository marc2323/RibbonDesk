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
precondition(shortOverview.maxOffset == 0 && shortOverview.scale == 1.0 / 3.0)
precondition(shortOverview.x > 0, "Center a short ribbon")
let shortDisplay = longCamera.overview(width: 1440, height: 250)
precondition(shortDisplay.scale < 1.0 / 3.0 && shortDisplay.scale * 800 <= 154, "Height still fits on short displays")
print("Scrollable overview: one-third scale, initial viewport, culling, endpoints, clamping, short ribbons and short displays passed")

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
