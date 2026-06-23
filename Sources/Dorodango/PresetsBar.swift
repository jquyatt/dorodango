import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Preset picker + actions menu at the top of the settings panel.
/// Selecting a preset loads its settings into the live queue settings.
struct PresetsBar: View {
    @EnvironmentObject var queue: ProcessingQueue
    @EnvironmentObject var presets: PresetStore

    @State private var showSaveAs = false
    @State private var showRename = false
    @State private var nameInput = ""

    private var lockedSelection: Bool { presets.selected.locked }

    var body: some View {
        HStack(spacing: 6) {
            Text("Preset").font(.caption)

            Picker("", selection: Binding(
                get: { presets.selectedID },
                set: { presets.select($0) })) {
                ForEach(presets.presets) { p in
                    Text(p.name + (presets.isDefault(p.id) ? " ★" : "")).tag(p.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .onChange(of: presets.selectedID) { _ in
                queue.settings = presets.selected.settings   // apply on selection
            }

            Menu {
                Button("Save") { presets.saveSelected(queue.settings) }
                    .disabled(lockedSelection)
                Button("Save as new…") { nameInput = ""; showSaveAs = true }
                Divider()
                Button("Rename…") { nameInput = presets.selected.name; showRename = true }
                    .disabled(lockedSelection)
                Button("Delete") { presets.delete(presets.selectedID) }
                    .disabled(lockedSelection)
                Button("Set as default") { presets.setDefault(presets.selectedID) }
                    .disabled(presets.isDefault(presets.selectedID))
                Divider()
                Button("Import…") { importPreset() }
                Button("Export…") { exportPreset() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
        }
        .alert("Save preset as", isPresented: $showSaveAs) {
            TextField("Name", text: $nameInput)
            Button("Save") { presets.add(name: nameInput, settings: queue.settings) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename preset", isPresented: $showRename) {
            TextField("Name", text: $nameInput)
            Button("Rename") { presets.rename(presets.selectedID, to: nameInput) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func importPreset() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            try? presets.importPreset(from: url)
            queue.settings = presets.selected.settings
        }
    }

    private func exportPreset() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(presets.selected.name).json"
        if panel.runModal() == .OK, let url = panel.url {
            try? presets.exportSelected(to: url)
        }
    }
}
