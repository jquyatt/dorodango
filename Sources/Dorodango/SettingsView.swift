import SwiftUI
import AppKit

/// The processing-settings panel. Mutates queue.settings directly so new
/// items pick up the current configuration.
struct SettingsView: View {
    @EnvironmentObject var queue: ProcessingQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Processing settings").font(.subheadline.bold())

            videoSection
            Divider()
            audioSection
            Divider()
            downloadSection
            Divider()
            outputSection
            Divider()
            ToolsView()
            Divider()
            HStack {
                Spacer()
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                Spacer()
            }
        }
    }

    // MARK: Download

    private var downloadSection: some View {
        HStack {
            Image(systemName: "link").font(.caption).foregroundStyle(.secondary)
            Text("Download quality").font(.caption)
            Spacer()
            Picker("", selection: bind(\.downloadQuality)) {
                ForEach(ProcessingSettings.DownloadQuality.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 110)
        }
    }

    // MARK: Video

    private var videoSection: some View {
        let isHW = queue.settings.isHardware
        return VStack(alignment: .leading, spacing: 8) {

            // Quality (CRF) — grayed out and disabled in hardware mode.
            VStack(alignment: .leading, spacing: 2) {
                labeledSlider(
                    title: "Quality",
                    value: Text(isHW ? "CRF —" : "CRF \(queue.settings.crf)")
                        .font(.caption.monospacedDigit()),
                    binding: Binding(get: { Double(queue.settings.crf) },
                                     set: { queue.settings.crf = Int($0) }),
                    range: 18...28, step: 1)
                Text(isHW ? "Not used by the hardware engine"
                          : "Lower = better quality, bigger file")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .disabled(isHW)
            .opacity(isHW ? 0.4 : 1)

            // Bitrate — qualifier swaps cap/gray ↔ target/yellow with mode.
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("Bitrate").font(.caption)
                    Text(isHW ? "(target)" : "(cap)")
                        .font(.caption)
                        .foregroundStyle(isHW ? Color.orange : Color.secondary)
                    Spacer()
                    Text("\(queue.settings.bitrateCapKbps) k")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { Double(queue.settings.bitrateCapKbps) },
                                      set: { queue.settings.bitrateCapKbps = Int($0) }),
                       in: 1000...20000, step: 250)
                Text(isHW ? "Hardware engine target"
                          : "Ceiling for busy scenes (bufsize \(queue.settings.bufsizeKbps)k)")
                    .font(.caption2)
                    .foregroundStyle(isHW ? Color.orange : Color.secondary)
            }

            // Speed — best → fast across the x264 ladder, final detent = hardware.
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Speed").font(.caption)
                    Spacer()
                    if isHW {
                        Label("Hardware", systemImage: "bolt.fill")
                            .font(.caption).foregroundStyle(.orange)
                    } else {
                        Text(queue.settings.speedLabel).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Slider(value: Binding(get: { Double(queue.settings.speedIndex) },
                                      set: { queue.settings.speedIndex = Int($0) }),
                       in: 0...Double(ProcessingSettings.maxSpeedIndex), step: 1)
                HStack {
                    Text("Best").font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    Text("Fast").font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    Text("HW").font(.caption2)
                        .foregroundStyle(isHW ? Color.orange : Color.secondary)
                }
            }
        }
    }

    // MARK: Audio

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Channels
            Picker("Channels", selection: bind(\.audioChannels)) {
                ForEach(ProcessingSettings.AudioChannels.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            // Loudness target
            labeledSlider(
                title: "Loudness",
                value: Text("\(Int(queue.settings.loudnessTargetLUFS)) LUFS").font(.caption.monospacedDigit()),
                binding: Binding(get: { queue.settings.loudnessTargetLUFS },
                                 set: { queue.settings.loudnessTargetLUFS = $0 }),
                range: -24 ... -9, step: 1)

            // Compression intensity (off at the bottom)
            let compIndex = Binding(
                get: { Double(queue.settings.compression.index) },
                set: { queue.settings.compression = .at(index: Int($0)) })
            labeledSlider(
                title: "Compression",
                value: Text(queue.settings.compression.rawValue).font(.caption),
                binding: compIndex,
                range: 0...Double(ProcessingSettings.Compression.ladder.count - 1), step: 1)

            // Audio bitrate
            Picker("Audio bitrate", selection: bind(\.audioBitrateKbps)) {
                ForEach([96, 128, 192, 256], id: \.self) { Text("\($0)k").tag($0) }
            }
        }
    }

    // MARK: Output

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Save to:").font(.caption)
                Text(queue.settings.outputFolder?.lastPathComponent ?? "Same as source")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose…") { chooseFolder() }.buttonStyle(.borderless).font(.caption)
                if queue.settings.outputFolder != nil {
                    Button("Reset") { queue.settings.outputFolder = nil }
                        .buttonStyle(.borderless).font(.caption)
                }
            }
            Toggle("Notify when batch finishes", isOn: bind(\.notifyOnComplete))
                .font(.caption)
        }
    }

    // MARK: Helpers

    /// Two-way binding into a settings keypath.
    private func bind<T>(_ keyPath: WritableKeyPath<ProcessingSettings, T>) -> Binding<T> {
        Binding(get: { queue.settings[keyPath: keyPath] },
                set: { queue.settings[keyPath: keyPath] = $0 })
    }

    /// A title + trailing value label above a slider, kept compact for the panel.
    private func labeledSlider(title: String, value: Text,
                               binding: Binding<Double>,
                               range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                value.foregroundStyle(.secondary)
            }
            Slider(value: binding, in: range, step: step)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { queue.settings.outputFolder = panel.url }
    }
}
