import AppKit
import SwiftUI

// An offscreen render harness. It never launches an engine, shows a window,
// starts capture, or changes permissions.
enum Engine {
    static let binary = "/bin/false"
    static func run(_ arguments: [String]) throws -> String { "{}" }
}

MainActor.assumeIsolated {
    _ = NSApplication.shared
    let records: [[String: Any]] = (0..<(CommandLine.arguments.contains("--short") ? 2 : 5)).map { index in
        let width = index == 2 ? 1200 : 600
        let x = index < 3 ? index * 604 : index * 604 + 600
        return ["window_id": index + 1, "bundle_id": "fixture", "app_name": ["Browser", "Editor", "Terminal", "Notes", "Files"][index],
                "title": "Window \(index + 1)", "focused": index == 1, "floating": false, "visible": index < 2,
                "frame": ["x": x, "y": 25, "width": width, "height": 800],
                "ribbon_frame": ["x": x, "y": 0, "width": width, "height": 800]]
    }
    let originID = CommandLine.arguments.contains("--origin-first") ? 1 : CommandLine.arguments.contains("--origin-last") ? records.count : 2
    let document: [String: Any] = ["active": ["display_id": 1, "native_workspace_id": 1, "virtual_workspace_number": 1, "focused_window_id": originID],
        "virtual_workspaces": [["number": 1, "native_workspace_id": 1, "active": true, "windows": records]]]
    let snapshot = try! JSONDecoder().decode(RibbonSnapshot.self, from: JSONSerialization.data(withJSONObject: document))
    let model = RibbonOverviewModel()
    model.windows = snapshot.ribbon
    model.selectedID = Int32(originID)
    model.originID = snapshot.overviewOriginID
    if CommandLine.arguments.contains("--other-selection") { model.selectedID = model.windows.last?.id }
    model.previewPermission = true
    model.zoomedOut = true
    model.infiniteRibbon = CommandLine.arguments.contains("--infinite")
    model.overviewOffset = model.camera.initialOffset(model.camera.overview(width: 1440, height: 900, infinite: model.infiniteRibbon),
                                                      viewportX: 0, width: 1440, originID: model.originID)
    if CommandLine.arguments.count > 2, let offset = Double(CommandLine.arguments[2]) { model.overviewOffset = offset }
    for (index, window) in model.windows.enumerated() {
        let width = Int(window.ribbon_frame!.width)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 800, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor(calibratedHue: CGFloat(index) * 0.13, saturation: 0.13, brightness: 0.20, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: 800).fill()
        NSColor(white: 0.25, alpha: 1).setFill()
        NSRect(x: 0, y: 765, width: width, height: 35).fill()
        for row in 0..<16 {
            NSColor(white: 0.5, alpha: 0.22).setFill()
            NSRect(x: 24, y: 720 - row * 40, width: width - 48 - row % 3 * 75, height: 12).fill()
        }
        (window.app_name as NSString).draw(at: NSPoint(x: 25, y: 770), withAttributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.white])
        NSGraphicsContext.restoreGraphicsState()
        let frame = RibbonPreviewFrame()
        frame.image = bitmap.cgImage
        model.previews[window.id] = frame
    }
    let renderer = ImageRenderer(content: RibbonOverviewView(model: model).frame(width: 1440, height: 900))
    renderer.scale = 1
    guard let image = renderer.cgImage else { fatalError("View did not render") }
    let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}
