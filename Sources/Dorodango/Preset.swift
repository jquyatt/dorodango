import Foundation

/// A named bundle of processing settings. The seeded "Default" is locked
/// (can't be renamed or deleted).
struct Preset: Codable, Identifiable {
    var id = UUID()
    var name: String
    var settings: ProcessingSettings
    var locked: Bool = false
}

/// Owns the preset list, the active selection, and which preset loads on launch.
/// Persists to UserDefaults as JSON; supports import/export of single presets.
@MainActor
final class PresetStore: ObservableObject {
    @Published private(set) var presets: [Preset]
    @Published var selectedID: UUID
    @Published private(set) var defaultID: UUID

    private let key = "dorodango.presets.v1"

    init() {
        if let saved = Self.load() {
            presets = saved.presets
            defaultID = saved.defaultID
            selectedID = saved.defaultID   // launch starts on the default preset
        } else {
            let def = Preset(name: "Default", settings: ProcessingSettings(), locked: true)
            presets = [def]
            defaultID = def.id
            selectedID = def.id
        }
    }

    var selected: Preset { presets.first { $0.id == selectedID } ?? presets[0] }

    func isDefault(_ id: UUID) -> Bool { id == defaultID }

    // MARK: Mutations

    func select(_ id: UUID) { selectedID = id }

    /// Save the given settings as a brand-new preset and select it.
    func add(name: String, settings: ProcessingSettings) {
        let p = Preset(name: name.isEmpty ? "Untitled" : name, settings: settings)
        presets.append(p)
        selectedID = p.id
        persist()
    }

    /// Overwrite the selected preset's settings (no-op if it's locked).
    func saveSelected(_ settings: ProcessingSettings) {
        guard let i = presets.firstIndex(where: { $0.id == selectedID }), !presets[i].locked else { return }
        presets[i].settings = settings
        persist()
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = presets.firstIndex(where: { $0.id == id }), !presets[i].locked,
              !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        presets[i].name = name
        persist()
    }

    func delete(_ id: UUID) {
        guard let p = presets.first(where: { $0.id == id }), !p.locked else { return }
        presets.removeAll { $0.id == id }
        if defaultID == id { defaultID = presets[0].id }
        if selectedID == id { selectedID = defaultID }
        persist()
    }

    func setDefault(_ id: UUID) {
        defaultID = id
        persist()
    }

    // MARK: Import / export

    func exportSelected(to url: URL) throws {
        let data = try JSONEncoder().encode(selected)
        try data.write(to: url)
    }

    func importPreset(from url: URL) throws {
        var p = try JSONDecoder().decode(Preset.self, from: url)
        p.id = UUID()        // fresh id so imports never collide
        p.locked = false     // imported presets are always editable
        presets.append(p)
        selectedID = p.id
        persist()
    }

    // MARK: Persistence

    private struct Persisted: Codable { var presets: [Preset]; var defaultID: UUID }

    private func persist() {
        let blob = Persisted(presets: presets, defaultID: defaultID)
        if let data = try? JSONEncoder().encode(blob) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func load() -> Persisted? {
        guard let data = UserDefaults.standard.data(forKey: "dorodango.presets.v1") else { return nil }
        return try? JSONDecoder().decode(Persisted.self, from: data)
    }
}

private extension JSONDecoder {
    func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try decode(type, from: Data(contentsOf: url))
    }
}
