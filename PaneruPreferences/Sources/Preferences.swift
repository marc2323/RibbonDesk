import Foundation

enum FocusMode: String, Codable, CaseIterable, Sendable {
    case hover, click
}

struct Preferences: Codable, Equatable, Sendable {
    var speed: Double
    var gap: Int
    var focusMode: FocusMode = .hover
    var launchAtLogin: Bool = false
    var disabledSpaceUUIDs: [String] = []
    var borderEnabled: Bool = true
    var borderColor: String = BorderColor.defaultHex
    static let defaults = Preferences(speed: 0.65, gap: 6)

    init(speed: Double, gap: Int, focusMode: FocusMode = .hover, launchAtLogin: Bool = false, disabledSpaceUUIDs: [String] = [], borderEnabled: Bool = true, borderColor: String = BorderColor.defaultHex) {
        self.speed = speed
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
                    borderEnabled: borderEnabled, borderColor: BorderColor.normalized(borderColor))
    }

    func luaSource(disabledSpaceIDs: [UInt64]) -> String {
        let value = validated
        let speed = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value.speed)
        let excludedIDs = disabledSpaceIDs.map(String.init).joined(separator: ", ")
        return """
        -- Written by Paneru Settings.
        return { speed = \(speed), gap = \(value.gap), focus_follows_mouse = \(value.focusMode == .hover), disabled_spaces = { \(excludedIDs) }, border_enabled = \(value.borderEnabled), border_color = "\(value.borderColor)" }

        """
    }
}

enum BorderColor {
    static let defaultHex = "#33879E"

    static func normalized(_ source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.hasPrefix("#") ? trimmed.dropFirst() : trimmed[...]
        guard digits.utf8.count == 6, digits.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }) else { return defaultHex }
        return "#" + digits.uppercased()
    }

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
