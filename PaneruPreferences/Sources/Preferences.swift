import Foundation

enum FocusMode: String, Codable, CaseIterable, Sendable {
    case hover, click
}

struct Preferences: Codable, Equatable, Sendable {
    var speed: Double
    var gap: Int
    var momentum: Double = 1.0
    var momentumDecay: Double = 4.0
    var snapSpeed: Double = 0.8
    var snapVisible: Double = 0.55
    var snapAnimation: Double = 1.0
    // Retain legacy size flags when round-tripping saved preferences and presets.
    // All Ribbon widths are eligible; these fields no longer filter snapping.
    var snapFullWidth: Bool = true
    var snapHalfWidth: Bool = true
    var snapBack: Bool = false
    var snapExitDistance: Double = 0.12
    var threeFingerPaging: Bool = true
    var magneticSnapping: Bool = false
    var magnetStrength: Double = 1.8
    var magnetRange: Double = 0.2
    var infiniteRibbon: Bool = false
    var floatingFollowsRibbon: Bool = true
    var trackpadHaptics: Bool = true
    var overviewAnimation: Bool = false
    var focusMode: FocusMode = .hover
    var launchAtLogin: Bool = false
    var disabledSpaceUUIDs: [String] = []
    var borderEnabled: Bool = true
    var borderColor: String = BorderColor.defaultHex
    static let defaults = Preferences(speed: 0.65, gap: 6)

    init(speed: Double, gap: Int, focusMode: FocusMode = .hover, launchAtLogin: Bool = false, disabledSpaceUUIDs: [String] = [], borderEnabled: Bool = true, borderColor: String = BorderColor.defaultHex, momentum: Double = 1.0, snapSpeed: Double = 0.8, snapVisible: Double = 0.55, momentumDecay: Double = 4.0, snapAnimation: Double = 1.0, snapFullWidth: Bool = true, snapHalfWidth: Bool = true, snapBack: Bool = false, snapExitDistance: Double = 0.12, threeFingerPaging: Bool = true, overviewAnimation: Bool = false, infiniteRibbon: Bool = false, magneticSnapping: Bool = false, magnetStrength: Double = 1.8, magnetRange: Double = 0.2, floatingFollowsRibbon: Bool = true, trackpadHaptics: Bool = true) {
        self.speed = speed
        self.floatingFollowsRibbon = floatingFollowsRibbon
        self.trackpadHaptics = trackpadHaptics
        self.momentum = momentum
        self.momentumDecay = momentumDecay
        self.snapSpeed = snapSpeed
        self.snapVisible = snapVisible
        self.snapAnimation = snapAnimation
        self.snapFullWidth = snapFullWidth
        self.snapHalfWidth = snapHalfWidth
        self.snapBack = snapBack
        self.snapExitDistance = snapExitDistance
        self.threeFingerPaging = threeFingerPaging
        self.magneticSnapping = magneticSnapping
        self.magnetStrength = magnetStrength
        self.magnetRange = magnetRange
        self.infiniteRibbon = infiniteRibbon
        self.overviewAnimation = overviewAnimation
        self.gap = gap
        self.focusMode = focusMode
        self.launchAtLogin = launchAtLogin
        self.disabledSpaceUUIDs = disabledSpaceUUIDs
        self.borderEnabled = borderEnabled
        self.borderColor = borderColor
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        speed = try values.decode(Double.self, forKey: .speed)
        gap = try values.decode(Int.self, forKey: .gap)
        momentum = try values.decodeIfPresent(Double.self, forKey: .momentum) ?? 1.0
        momentumDecay = try values.decodeIfPresent(Double.self, forKey: .momentumDecay) ?? 4.0
        snapSpeed = try values.decodeIfPresent(Double.self, forKey: .snapSpeed) ?? 0.8
        snapVisible = try values.decodeIfPresent(Double.self, forKey: .snapVisible) ?? 0.55
        snapAnimation = try values.decodeIfPresent(Double.self, forKey: .snapAnimation) ?? 1.0
        snapFullWidth = try values.decodeIfPresent(Bool.self, forKey: .snapFullWidth) ?? true
        snapHalfWidth = try values.decodeIfPresent(Bool.self, forKey: .snapHalfWidth) ?? true
        snapBack = try values.decodeIfPresent(Bool.self, forKey: .snapBack) ?? false
        snapExitDistance = try values.decodeIfPresent(Double.self, forKey: .snapExitDistance) ?? 0.12
        threeFingerPaging = try values.decodeIfPresent(Bool.self, forKey: .threeFingerPaging) ?? true
        magneticSnapping = try values.decodeIfPresent(Bool.self, forKey: .magneticSnapping) ?? false
        magnetStrength = try values.decodeIfPresent(Double.self, forKey: .magnetStrength) ?? 1.8
        magnetRange = try values.decodeIfPresent(Double.self, forKey: .magnetRange) ?? 0.2
        infiniteRibbon = try values.decodeIfPresent(Bool.self, forKey: .infiniteRibbon) ?? false
        overviewAnimation = try values.decodeIfPresent(Bool.self, forKey: .overviewAnimation) ?? false
        floatingFollowsRibbon = try values.decodeIfPresent(Bool.self, forKey: .floatingFollowsRibbon) ?? true
        trackpadHaptics = try values.decodeIfPresent(Bool.self, forKey: .trackpadHaptics) ?? true
        // Existing installations have only speed and gap. Preserve both values.
        focusMode = try values.decodeIfPresent(FocusMode.self, forKey: .focusMode) ?? .hover
        launchAtLogin = try values.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        disabledSpaceUUIDs = try values.decodeIfPresent([String].self, forKey: .disabledSpaceUUIDs) ?? []
        borderEnabled = try values.decodeIfPresent(Bool.self, forKey: .borderEnabled) ?? true
        borderColor = try values.decodeIfPresent(String.self, forKey: .borderColor) ?? BorderColor.defaultHex
    }

    var validated: Preferences {
        Preferences(speed: speed.isFinite ? min(1.5, max(0.2, speed)) : 0.65,
                    gap: Int((Double(min(24, max(0, gap))) / 2).rounded()) * 2,
                    focusMode: focusMode, launchAtLogin: launchAtLogin,
                    disabledSpaceUUIDs: Array(Set(disabledSpaceUUIDs.filter { !$0.isEmpty })).sorted(),
                    borderEnabled: borderEnabled, borderColor: BorderColor.normalized(borderColor),
                    momentum: momentum.isFinite ? min(3, max(0, momentum)) : 1.0,
                    snapSpeed: snapSpeed.isFinite ? min(3, max(0, snapSpeed)) : 0.8,
                    snapVisible: snapVisible.isFinite ? min(0.95, max(0.25, snapVisible)) : 0.55,
                    momentumDecay: momentumDecay.isFinite ? min(100, max(1, momentumDecay)) : 4.0,
                    snapAnimation: snapAnimation.isFinite ? min(4, max(0.2, snapAnimation)) : 1.0,
                    snapFullWidth: snapFullWidth, snapHalfWidth: snapHalfWidth, snapBack: snapBack,
                    snapExitDistance: snapExitDistance.isFinite ? min(0.5, max(0, snapExitDistance)) : 0.12, threeFingerPaging: threeFingerPaging,
                    overviewAnimation: overviewAnimation, infiniteRibbon: infiniteRibbon, magneticSnapping: magneticSnapping,
                    magnetStrength: magnetStrength.isFinite ? min(6, max(0.2, magnetStrength)) : 1.8,
                    magnetRange: magnetRange.isFinite ? min(0.4, max(0.03, magnetRange)) : 0.2,
                    floatingFollowsRibbon: floatingFollowsRibbon, trackpadHaptics: trackpadHaptics)
    }

    func luaSource(disabledSpaceIDs: [UInt64]) -> String {
        let value = validated
        let speed = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value.speed)
        let momentum = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value.momentum)
        let momentumDecay = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value.momentumDecay)
        let snapSpeed = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value.snapSpeed)
        let snapVisible = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value.snapVisible)
        let snapAnimation = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value.snapAnimation)
        let snapExitDistance = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value.snapExitDistance)
        let magnetStrength = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value.magnetStrength)
        let magnetRange = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value.magnetRange)
        let excludedIDs = disabledSpaceIDs.map(String.init).joined(separator: ", ")
        return """
        -- Written by RibbonDesk.
        return { speed = \(speed), momentum = \(momentum), momentum_decay = \(momentumDecay), snap_speed = \(snapSpeed), snap_visible = \(snapVisible), snap_animation = \(snapAnimation), snap_full_width = \(value.snapFullWidth), snap_half_width = \(value.snapHalfWidth), snap_back = \(value.snapBack), snap_exit_distance = \(snapExitDistance), three_finger_paging = \(value.threeFingerPaging), magnetic_snapping = \(value.magneticSnapping), magnet_strength = \(magnetStrength), magnet_range = \(magnetRange), infinite_ribbon = \(value.infiniteRibbon), floating_follows_ribbon = \(value.floatingFollowsRibbon), trackpad_haptics = \(value.trackpadHaptics), gap = \(value.gap), focus_follows_mouse = \(value.focusMode == .hover), disabled_spaces = { \(excludedIDs) }, border_enabled = \(value.borderEnabled), border_color = "\(value.borderColor)" }

        """
    }
}

enum BorderColor {
    static let defaultHex = "#33879E"

    static func parsedHex(_ source: String) -> String? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.hasPrefix("#") ? trimmed.dropFirst() : trimmed[...]
        guard digits.utf8.count == 6, digits.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }) else { return nil }
        return "#" + digits.uppercased()
    }

    static func normalized(_ source: String) -> String { parsedHex(source) ?? defaultHex }

    static func components(_ source: String) -> (red: Double, green: Double, blue: Double) {
        let number = UInt32(normalized(source).dropFirst(), radix: 16)!
        return (Double((number >> 16) & 255) / 255,
                Double((number >> 8) & 255) / 255, Double(number & 255) / 255)
    }

    static func hex(red: Double, green: Double, blue: Double) -> String {
        let channels = [red, green, blue].map { Int((min(1, max(0, $0.isFinite ? $0 : 0)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channels[0], channels[1], channels[2])
    }
}

/// A feel preset intentionally excludes Desktop policy, login, and appearance.
struct ScrollTuning: Codable, Equatable, Sendable {
    var speed: Double
    var momentum: Double
    var momentumDecay: Double
    var snapSpeed: Double
    var snapVisible: Double
    var snapAnimation: Double
    var snapFullWidth: Bool
    var snapHalfWidth: Bool
    var snapBack: Bool
    var snapExitDistance: Double
    var threeFingerPaging: Bool = true
    var magneticSnapping: Bool = false
    var magnetStrength: Double = 1.8
    var magnetRange: Double = 0.2

    var validated: ScrollTuning {
        var preferences = Preferences.defaults
        preferences.scrollTuning = self
        return preferences.validated.scrollTuning
    }
}

extension Preferences {
    var scrollTuning: ScrollTuning {
        get {
            ScrollTuning(speed: speed, momentum: momentum, momentumDecay: momentumDecay,
                        snapSpeed: snapSpeed, snapVisible: snapVisible, snapAnimation: snapAnimation,
                        snapFullWidth: snapFullWidth, snapHalfWidth: snapHalfWidth,
                        snapBack: snapBack, snapExitDistance: snapExitDistance, threeFingerPaging: threeFingerPaging,
                        magneticSnapping: magneticSnapping, magnetStrength: magnetStrength, magnetRange: magnetRange)
        }
        set {
            speed = newValue.speed
            momentum = newValue.momentum
            momentumDecay = newValue.momentumDecay
            snapSpeed = newValue.snapSpeed
            snapVisible = newValue.snapVisible
            snapAnimation = newValue.snapAnimation
            snapFullWidth = newValue.snapFullWidth
            snapHalfWidth = newValue.snapHalfWidth
            snapBack = newValue.snapBack
            snapExitDistance = newValue.snapExitDistance
            threeFingerPaging = newValue.threeFingerPaging
            magneticSnapping = newValue.magneticSnapping
            magnetStrength = newValue.magnetStrength
            magnetRange = newValue.magnetRange
        }
    }
}


extension ScrollTuning {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(speed: try values.decode(Double.self, forKey: .speed),
                  momentum: try values.decode(Double.self, forKey: .momentum),
                  momentumDecay: try values.decode(Double.self, forKey: .momentumDecay),
                  snapSpeed: try values.decode(Double.self, forKey: .snapSpeed),
                  snapVisible: try values.decode(Double.self, forKey: .snapVisible),
                  snapAnimation: try values.decode(Double.self, forKey: .snapAnimation),
                  snapFullWidth: try values.decode(Bool.self, forKey: .snapFullWidth),
                  snapHalfWidth: try values.decode(Bool.self, forKey: .snapHalfWidth),
                  snapBack: try values.decode(Bool.self, forKey: .snapBack),
                  snapExitDistance: try values.decode(Double.self, forKey: .snapExitDistance),
                  // Old feel presets restore the free-scrolling mode they saved.
                  threeFingerPaging: try values.decodeIfPresent(Bool.self, forKey: .threeFingerPaging) ?? false,
                  magneticSnapping: try values.decodeIfPresent(Bool.self, forKey: .magneticSnapping) ?? false,
                  magnetStrength: try values.decodeIfPresent(Double.self, forKey: .magnetStrength) ?? 1.8,
                  magnetRange: try values.decodeIfPresent(Double.self, forKey: .magnetRange) ?? 0.2)
    }
}
