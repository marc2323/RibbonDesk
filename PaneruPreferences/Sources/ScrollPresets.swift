import Foundation

struct ScrollPreset: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var tuning: ScrollTuning
}

struct ScrollPresetStore {
    let url: URL

    func read() throws -> [ScrollPreset] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([ScrollPreset].self, from: Data(contentsOf: url))
    }

    @discardableResult
    func save(name: String, tuning: ScrollTuning) throws -> ScrollPreset {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !name.isEmpty else { throw PresetError.emptyName }
        var presets = try read()
        let index = presets.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        let preset = ScrollPreset(id: index.map { presets[$0].id } ?? UUID().uuidString,
                                  name: name, tuning: tuning.validated)
        if let index { presets[index] = preset } else { presets.append(preset) }
        try write(presets.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        return preset
    }

    func delete(id: String) throws {
        try write(read().filter { $0.id != id })
    }

    private func write(_ presets: [ScrollPreset]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(presets).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private enum PresetError: LocalizedError {
        case emptyName
        var errorDescription: String? { "Enter a name for this feel preset." }
    }
}
