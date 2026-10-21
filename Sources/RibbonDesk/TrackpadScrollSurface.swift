import AppKit
import SwiftUI
import RibbonCore

/// A local three-finger demo surface and live status/pause control. Wheel
/// events always follow the normal responder chain, including in live mode.
@MainActor
final class TrackpadScrollView: NSView {
    var onBegin: (() -> Void)?
    var onScroll: ((Double) -> Void)?
    var onFinish: (() -> Void)?
    var onCompletion: ((RibbonSwipeCompletion) -> Void)?
    var onPause: (() -> Void)?
    var inputCancellationRevision: UInt = 0 {
        didSet { if oldValue != inputCancellationRevision { gesture.cancelGesture() } }
    }
    var localGestureEnabled = false { didSet { if !localGestureEnabled { gesture.stop() } } }
    var inputEnabled = false {
        didSet {
            if !inputEnabled { gesture.stop() }
            pauseButton.isEnabled = inputEnabled; needsDisplay = true
        }
    }
    var motionSettings = RibbonMotionSettings.default {
        didSet { gesture.updateMotionSettings(motionSettings) }
    }
    var detail = "Start the isolated demo to try scrolling." { didSet { needsDisplay = true } }
    private let pauseButton = NSButton(title: "Pause / Restore", target: nil, action: nil)
    private let gesture = GlobalScroll()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        allowedTouchTypes = [.indirect]
        gesture.onBegin = { [weak self] _ in self?.onBegin?() }
        gesture.onScroll = { [weak self] delta, _ in self?.onScroll?(delta) }
        gesture.onFinish = { [weak self] _ in self?.onFinish?() }
        gesture.onCompletion = { [weak self] completion, _ in self?.onCompletion?(completion) }
        pauseButton.target = self
        pauseButton.action = #selector(pause)
        pauseButton.bezelStyle = .rounded
        pauseButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pauseButton)
        NSLayoutConstraint.activate([
            pauseButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            pauseButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            pauseButton.widthAnchor.constraint(equalToConstant: 126)
        ])
        setAccessibilityElement(true)
        setAccessibilityLabel("Horizontal window scroll strip")
        setAccessibilityHelp("Swipe horizontally with three fingers here in the isolated demo, or anywhere during live control. Two-finger scrolling keeps its normal behavior. Pause restores saved windows.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
        let title = "↔  Three-finger horizontal swipe"
        let titleBounds = NSRect(x: 16, y: bounds.midY + 1, width: max(0, bounds.width - 175), height: 17)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        title.draw(in: titleBounds, withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: inputEnabled ? NSColor.labelColor : NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ])
        let detailBounds = NSRect(x: 16, y: bounds.midY - 18, width: max(0, bounds.width - 175), height: 15)
        detail.draw(in: detailBounds, withAttributes: [
            .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ])
    }
    override func scrollWheel(with event: NSEvent) { super.scrollWheel(with: event) }
    override func touchesBegan(with event: NSEvent) { handleTouches(event) }
    override func touchesMoved(with event: NSEvent) { handleTouches(event) }
    override func touchesEnded(with event: NSEvent) { handleTouches(event) }
    override func touchesCancelled(with event: NSEvent) { handleTouches(event) }
    private func handleTouches(_ event: NSEvent) {
        guard inputEnabled, localGestureEnabled else { return }
        gesture.routeTouches(event, at: .zero)
    }
    @objc private func pause() { onPause?() }
}

@MainActor
struct TrackpadScrollSurface: NSViewRepresentable {
    @ObservedObject var desk: DeskController
    func makeNSView(context: Context) -> TrackpadScrollView { TrackpadScrollView(frame: .zero) }
    func updateNSView(_ view: TrackpadScrollView, context: Context) {
        let revision = desk.inputCancellationRevision
        view.inputCancellationRevision = revision
        view.inputEnabled = desk.controlsEnabled
        view.localGestureEnabled = desk.mode == .demo
        view.motionSettings = desk.motionSettings
        view.detail = desk.mode == .live ? "Half-screen snapping · two fingers scroll normally."
            : "Swipe here to try half-screen snapping."
        if desk.mode == .live {
            view.setAccessibilityHelp("Swipe horizontally anywhere with three fingers. Two-finger scrolling keeps its normal system behavior. A short flick advances to the next half-screen position; a slow drag settles to the nearest one. The window under the pointer is activated after settling. New swipes interrupt snapping; Pause restores the saved arrangement.")
        }
        view.setAccessibilityValue("Offset \(Int(desk.state.scrollOffset)) points. Focus: \(desk.state.focusedItem?.appName ?? "none").")
        // The revision guards queued callbacks immediately after a keyboard or
        // sidebar action, before SwiftUI delivers the next native-view update.
        view.onBegin = { [weak desk] in
            guard let desk, desk.inputCancellationRevision == revision else { return }
            desk.beginHorizontalScroll()
        }
        view.onScroll = { [weak desk] delta in
            guard let desk, desk.inputCancellationRevision == revision else { return }
            desk.scrollHorizontally(by: delta)
        }
        view.onFinish = { [weak desk] in
            guard let desk, desk.inputCancellationRevision == revision else { return }
            desk.finishHorizontalScroll()
        }
        view.onCompletion = { [weak desk] completion in
            guard let desk, desk.inputCancellationRevision == revision else { return }
            desk.finishHorizontalScroll(completion: completion)
        }
        view.onPause = { [weak desk] in desk?.pauseAndRestore() }
    }
}

/// Nonactivating app-owned surface. It appears only during an opted-in live
/// session, over the bottom of the managed window area.
@MainActor
final class LiveScrollPanel: NSPanel {
    init(screen: NSScreen, desk: DeskController) {
        let usable = screen.visibleFrame
        let width = min(900, usable.width - 32)
        let frame = NSRect(x: usable.midX - width / 2, y: usable.minY + 12, width: width, height: 56)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "RibbonDesk Live Scroll Strip"
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        level = .floating
        collectionBehavior = [.transient, .ignoresCycle]
        isOpaque = false; backgroundColor = .clear; hasShadow = true
        let surface = TrackpadScrollView(frame: NSRect(origin: .zero, size: frame.size))
        surface.inputEnabled = true
        surface.setAccessibilityHelp("Swipe horizontally anywhere with three fingers. Two fingers scroll normally. Pause restores the saved arrangement.")
        surface.motionSettings = desk.motionSettings
        surface.detail = "LIVE · half-screen snapping · ⌃⌥⌘P pauses"
        surface.onBegin = { [weak desk] in desk?.beginHorizontalScroll() }
        surface.onScroll = { [weak desk] delta in desk?.scrollHorizontally(by: delta) }
        surface.onFinish = { [weak desk] in desk?.finishHorizontalScroll() }
        surface.onCompletion = { [weak desk] completion in desk?.finishHorizontalScroll(completion: completion) }
        surface.onPause = { [weak desk] in desk?.pauseAndRestore() }
        contentView = surface
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
