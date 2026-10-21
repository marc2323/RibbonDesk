import AppKit
import SwiftUI
import RibbonCore

struct DashboardView: View {
    @ObservedObject var desk: DeskController
    @State private var showsMotionSettings = false
    @State private var showsShortcutHelp = false
    private let ink = Color.teal
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: "rectangle.split.3x1")
                    .font(.system(size: 30, weight: .light)).foregroundStyle(ink)
                VStack(alignment: .leading, spacing: 3) {
                    Text("RibbonDesk").font(.system(size: 25, weight: .semibold, design: .rounded))
                    Text("Quick switching. Room to focus.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Label(desk.mode.rawValue, systemImage: desk.mode == .live ? "circle.fill" : "pause.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(desk.mode == .live ? Color.orange.opacity(0.15) : Color.secondary.opacity(0.1), in: Capsule())
            }.padding(.horizontal, 20).padding(.vertical, 16)
            Divider()
            GeometryReader { geometry in
                if geometry.size.width >= 850 {
                    HStack(spacing: 0) {
                        sidebar(compact: false).frame(width: 220)
                        Divider()
                        ScrollView { workspace.padding(22).frame(maxWidth: .infinity) }
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            workspace.padding(20)
                            Divider()
                            sidebar(compact: true)
                        }
                    }
                }
            }
            Divider()
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: desk.pendingRestoreCount > 0 ? "arrow.uturn.backward.circle" : "info.circle")
                Text(desk.message).font(.system(size: 12)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 14)
                .frame(minHeight: 66, alignment: .topLeading)
        }
        .frame(minWidth: 600, minHeight: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func sidebar(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("WINDOWS").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary).tracking(1.5)
            if desk.state.items.isEmpty {
                Text("No tiled windows on this display.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(desk.state.items) { item in
                        HStack(spacing: 8) {
                            Button { desk.select(item.id) } label: {
                                HStack(spacing: 9) {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(item.isFloating ? Color.gray.opacity(0.4) : Color.teal.opacity(0.65))
                                        .frame(width: 7, height: 30)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.appName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                        Text(item.isFloating ? "Floating" : "\(Int(item.width)) pt column")
                                            .font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(!desk.controlsEnabled || item.isFloating)
                            Button { desk.toggleFloating(item.id) } label: {
                                Image(systemName: item.isFloating ? "rectangle.split.3x1" : "rectangle.on.rectangle")
                            }.buttonStyle(.borderless).help(item.isFloating ? "Return to strip" : "Float and restore original frame")
                                .disabled(!desk.controlsEnabled)
                        }
                        .padding(10)
                        .background(desk.state.focusedID == item.id ? Color.teal.opacity(0.12) : Color.secondary.opacity(0.045),
                                    in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }.frame(minHeight: 80, maxHeight: compact ? 240 : .infinity)
            if !compact { Spacer(minLength: 0) }
            Divider()
            Text("FLOAT ENTIRE APPS").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary).tracking(1)
            TextField("Bundle IDs, separated by commas", text: $desk.excludedBundleIDs, axis: .vertical)
                .font(.system(size: 11, design: .monospaced)).textFieldStyle(.roundedBorder)
                .lineLimit(2...4).disabled(desk.mode == .live)
            Text("Exclusions apply to the next live capture. Dialogs and fixed-size windows always float.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if !desk.unchanged.isEmpty {
                DisclosureGroup("\(desk.unchanged.count) left unchanged") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(desk.unchanged) { item in
                                Text("\(item.app) · \(item.title)\n\(item.reason)")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                    }.frame(maxHeight: 100)
                }.font(.system(size: 11))
            }
        }.padding(18).background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 14) {
            if desk.displays.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                    ForEach(desk.displays) { display in
                        Button(display.name) { desk.selectDisplay(display.id) }
                            .tint(desk.activeDisplayID == display.id ? .teal : .gray)
                    }
                    }
                }
            }
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(desk.mode == .live ? "Your active strip" : "Room to move")
                        .font(.system(size: 22, weight: .medium, design: .serif))
                    Text("Half-screen steps. Full-height windows.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(desk.mode == .live ? "LIVE MAP" : "IN-APP PREVIEW")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1).foregroundStyle(.secondary)
            }
            StripPreview(desk: desk).frame(maxWidth: .infinity).aspectRatio(desk.viewport.width / max(1, desk.viewport.height), contentMode: .fit).frame(maxHeight: 240)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.black.opacity(0.08)))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            HStack(spacing: 8) {
                Button { desk.perform(.focusLeft) } label: { Label("Focus", systemImage: "arrow.left") }
                    .help("Previous window · \(ShortcutBindings.help(.focusLeft))")
                Button { desk.perform(.focusRight) } label: { Label("Focus", systemImage: "arrow.right") }
                    .help("Next window · \(ShortcutBindings.help(.focusRight))")
                Divider().frame(height: 20)
                Button { desk.perform(.moveLeft) } label: { Image(systemName: "arrow.left.to.line") }
                    .help("Move window left · \(ShortcutBindings.help(.moveLeft))")
                Button { desk.perform(.moveRight) } label: { Image(systemName: "arrow.right.to.line") }
                    .help("Move window right · \(ShortcutBindings.help(.moveRight))")
                Spacer()
                Button("Half") { desk.perform(.medium) }.help("Half-screen width · \(ShortcutBindings.help(.medium))")
                Button("Full") { desk.perform(.full) }.help("Full-screen width · \(ShortcutBindings.help(.full))")
            }.disabled(!desk.controlsEnabled).controlSize(.regular)
            Text("\(ShortcutBindings.help(.focusLeft)) / \(ShortcutBindings.help(.focusRight)) switch · \(ShortcutBindings.help(.cycleWidth)) Half / Full · \(ShortcutBindings.help(.pause)) restore")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            shortcutHelp
            TrackpadScrollSurface(desk: desk).frame(height: 56)
            motionControls
            Divider()
            HStack(spacing: 10) {
                Button("Try Isolated Demo") { desk.startDemo() }
                    .disabled(desk.mode == .live || desk.pendingRestoreCount > 0)
                Button("Save & Arrange Windows") { desk.reviewLiveSession() }
                    .disabled(desk.mode == .live || desk.pendingRestoreCount > 0)
                Spacer()
                Button("Pause / Restore") { desk.pauseAndRestore() }
                    .disabled(desk.mode != .live && desk.mode != .demo)
            }
            if desk.pendingRestoreCount > 0 {
                Button("Restore Saved Arrangement (\(desk.pendingRestoreCount))") { desk.confirmRestore() }
                    .disabled(desk.mode == .live)
            }
            Text("One ribbon per Space and display. After a swipe settles, the window under your pointer comes to the front.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text("Original arrangement: \(desk.snapshotLocation)")
                .font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private var shortcutHelp: some View {
        DisclosureGroup(isExpanded: $showsShortcutHelp) {
            VStack(alignment: .leading, spacing: 7) {
                shortcutRow("Previous / next window", "\(ShortcutBindings.help(.focusLeft)) / \(ShortcutBindings.help(.focusRight))")
                shortcutRow("Reorder left / right", "\(ShortcutBindings.help(.moveLeft)) / \(ShortcutBindings.help(.moveRight))")
                shortcutRow("First / last window", "\(ShortcutBindings.help(.first)) / \(ShortcutBindings.help(.last))")
                shortcutRow("Jump to window 1–9", "\(ShortcutBindings.help(.jump1)) … \(ShortcutBindings.help(.jump9))")
                shortcutRow("Cycle Half / Full", ShortcutBindings.help(.cycleWidth))
                shortcutRow("Full width", ShortcutBindings.help(.full))
                shortcutRow("Float focused window", ShortcutBindings.help(.float))
                shortcutRow("Pause and restore originals", ShortcutBindings.help(.pause))
                Text("⌃ Control · ⌥ Option · ⇧ Shift · ⌘ Command. Arrow aliases work when available. Keyboard switching activates immediately.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 3)
                if desk.mode == .live {
                    Text(desk.shortcutDiagnostics.summary)
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    ForEach(desk.shortcutWarnings, id: \.self) { warning in
                        Text(warning).font(.system(size: 10)).foregroundStyle(.orange)
                    }
                }
            }.padding(.top, 8)
        } label: {
            HStack {
                Text("Keyboard shortcuts").font(.system(size: 12, weight: .semibold))
                Spacer()
                if !desk.shortcutWarnings.isEmpty && desk.mode == .live {
                    Text("\(desk.shortcutWarnings.count) unavailable").font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func shortcutRow(_ title: String, _ keys: String) -> some View {
        HStack {
            Text(title).font(.system(size: 11))
            Spacer(minLength: 8)
            Text(keys).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
        }
    }

    private var motionControls: some View {
        DisclosureGroup(isExpanded: $showsMotionSettings) {
            VStack(alignment: .leading, spacing: 12) {
                motionSlider("Speed", value: $desk.motionSettings.speed, range: RibbonMotionSettings.speedRange,
                             display: String(format: "%.2f×", desk.motionSettings.speed),
                             help: "Multiplies finger travel. Higher values move farther with the same swipe.")
                motionSlider("Sensitivity", value: $desk.motionSettings.sensitivity, range: RibbonMotionSettings.sensitivityRange,
                             display: String(format: "%.2f×", desk.motionSettings.sensitivity),
                             help: "Higher values activate with less finger travel. Lower values require a more deliberate swipe.")
                motionSlider("Acceleration", value: $desk.motionSettings.acceleration, range: RibbonMotionSettings.accelerationRange,
                             display: desk.motionSettings.acceleration == 0 ? "Linear" : String(format: "%.0f%%", desk.motionSettings.acceleration * 100),
                             help: "Fast swipes travel farther. At zero, motion stays linear at every swipe speed.")
                motionSlider("Momentum", value: $desk.motionSettings.momentum, range: RibbonMotionSettings.momentumRange,
                             display: desk.motionSettings.momentum == 0 ? "Off" : String(format: "%.0f%%", desk.motionSettings.momentum * 100),
                             help: "Controls coast distance and time after lifting. At zero, the ribbon settles immediately.")
                HStack {
                    Text("Applies to live control and the isolated demo.").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset Defaults") { desk.resetMotionSettings() }
                        .controlSize(.small).disabled(desk.motionSettings == .default)
                }
            }.padding(.top, 10)
        } label: {
            HStack {
                Text("Motion controls").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(String(format: "%.2f× speed", desk.motionSettings.speed))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
    }

    private func motionSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, display: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium)).frame(width: 85, alignment: .leading)
                Slider(value: value, in: range, step: 0.05).accessibilityLabel(title)
                    .accessibilityValue(display).help(help)
                Text(display).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .trailing)
            }
            Text(help).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

}

private struct StripPreview: View {
    @ObservedObject var desk: DeskController
    let colors: [Color] = [Color(red: 0.25, green: 0.49, blue: 0.48),
                            Color(red: 0.26, green: 0.36, blue: 0.52),
                            Color(red: 0.65, green: 0.43, blue: 0.30),
                            Color(red: 0.46, green: 0.43, blue: 0.59)]
    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / desk.viewport.width, geometry.size.height / desk.viewport.height)
            ZStack(alignment: .topLeading) {
                Color(red: 0.91, green: 0.92, blue: 0.89)
                if desk.placements.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "rectangle.split.3x1").font(.system(size: 42, weight: .ultraLight))
                        Text("The desktop can wait.").font(.system(size: 22, design: .serif))
                        Text("Explore safely with the isolated demo.").font(.system(size: 12))
                    }.foregroundStyle(Color(red: 0.29, green: 0.37, blue: 0.35))
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                ForEach(Array(desk.placements.enumerated()), id: \.element.id) { index, placement in
                    let item = desk.state.items.first { $0.id == placement.id }
                    let focused = placement.id == desk.state.focusedID
                    let color = colors[index % colors.count]
                    Button { desk.select(placement.id) } label: {
                        // Lay out a complete window at desktop size first.
                        // Scaling only the outer frame leaves text/padding at
                        // screen size and makes small map cards overflow.
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 14) {
                                Circle().fill(Color.white.opacity(0.4)).frame(width: 16, height: 16)
                                Circle().fill(Color.white.opacity(0.25)).frame(width: 16, height: 16)
                                Spacer(minLength: 0)
                                Text(item?.appName ?? "Window")
                                    .font(.system(size: 34, weight: .semibold)).lineLimit(1)
                                Spacer(minLength: 0)
                            }.padding(28).background(color)
                            VStack(alignment: .leading, spacing: 36) {
                                Text(item?.title ?? "")
                                    .font(.system(size: 46, weight: .medium, design: .serif))
                                    .lineLimit(3)
                                RoundedRectangle(cornerRadius: 12).fill(color.opacity(0.15)).frame(height: 145)
                                ForEach(0..<3) { line in
                                    Capsule().fill(color.opacity(0.12)).frame(height: 14)
                                        .padding(.trailing, CGFloat(line) * 36)
                                }
                                Spacer(minLength: 0)
                                Text(focused ? "IN FOCUS" : "\(Int(placement.frame.width)) PT")
                                    .font(.system(size: 26, weight: .bold, design: .monospaced)).tracking(3)
                                    .foregroundStyle(color)
                            }.padding(42).foregroundStyle(Color(red: 0.18, green: 0.24, blue: 0.25))
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .background(Color(red: 0.98, green: 0.98, blue: 0.96))
                        }
                        .frame(width: placement.frame.width, height: placement.frame.height, alignment: .topLeading)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .overlay(RoundedRectangle(cornerRadius: 20).stroke(focused ? color : Color.clear, lineWidth: 8))
                        .shadow(color: Color.black.opacity(focused ? 0.16 : 0.07), radius: focused ? 24 : 8, y: 10)
                    }.buttonStyle(.plain)
                        .scaleEffect(scale, anchor: .topLeading)
                        .frame(width: placement.frame.width * scale, height: placement.frame.height * scale,
                               alignment: .topLeading)
                        .position(x: (placement.frame.x - desk.viewport.x + placement.frame.width / 2) * scale,
                                  y: (placement.frame.y - desk.viewport.y + placement.frame.height / 2) * scale)
                        // Parked edge handles represent offscreen windows. They
                        // sit behind visible tiles, as in the real desktop.
                        .zIndex(focused ? 3 : placement.isParked ? 0 : 2)
                }
            }.clipped()
        }
        .accessibilityLabel("Strip preview. Use the window list or focus buttons to navigate.")
    }
}
