import SwiftUI

/// "Tools" section in settings. One row per managed tool (ffmpeg covers ffprobe
/// — same Homebrew formula), each showing version + a contextual Install/Update
/// action with per-row progress and a concise result line.
struct ToolsView: View {
    private struct Tool: Identifiable {
        let id = UUID()
        let key: String          // identity for state dictionaries
        let display: String
        let note: String?        // small clarifier under the name
        let probe: String        // binary to read a version from
        let versionArgs: [String]
    }

    private let tools: [Tool] = [
        Tool(key: "brew",   display: "Homebrew", note: nil,                probe: "brew",   versionArgs: ["--version"]),
        Tool(key: "ffmpeg", display: "ffmpeg",   note: "includes ffprobe", probe: "ffmpeg", versionArgs: ["-version"]),
        Tool(key: "yt-dlp", display: "yt-dlp",   note: nil,                probe: "yt-dlp", versionArgs: ["--version"])
    ]

    @State private var version: [String: String] = [:]
    @State private var installed: [String: Bool] = [:]
    @State private var busyKey: String? = nil
    @State private var message: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Tools").font(.subheadline.bold())
                Spacer()
                Button { refreshAll() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Re-check versions")
                    .disabled(busyKey != nil)
            }
            ForEach(tools) { row($0) }
        }
        .onAppear { refreshAll() }   // re-detect on every open (catches external installs)
    }

    // MARK: Row

    @ViewBuilder
    private func row(_ tool: Tool) -> some View {
        let isInstalled = installed[tool.key] ?? false
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: isInstalled ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(isInstalled ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 0) {
                    Text(tool.display).font(.caption)
                    if let note = tool.note {
                        Text(note).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                if busyKey == tool.key {
                    ProgressView().controlSize(.small)
                } else {
                    Text(isInstalled ? (version[tool.key] ?? "") : "not installed")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                actionButton(for: tool, installed: isInstalled)
            }
            if let msg = message[tool.key], !msg.isEmpty {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 22)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func actionButton(for tool: Tool, installed isInstalled: Bool) -> some View {
        let brewMissing = !(installed["brew"] ?? false)
        switch tool.key {
        case "brew":
            if isInstalled {
                smallButton("Update") { run(tool) { await ToolManager.updateHomebrew() } }
            } else {
                smallButton("Install…") {
                    ToolManager.openHomebrewInstaller()
                    message["brew"] = "Opened Terminal — finish there, then Refresh."
                }
            }
        case "ffmpeg":
            if isInstalled {
                smallButton("Update") { run(tool) { await ToolManager.updateFfmpeg() } }
            } else {
                smallButton("Install", disabled: brewMissing) { run(tool) { await ToolManager.install("ffmpeg") } }
            }
        case "yt-dlp":
            if isInstalled {
                smallButton("Update") { run(tool) { await ToolManager.updateYtDlp() } }
            } else {
                smallButton("Install", disabled: brewMissing) { run(tool) { await ToolManager.install("yt-dlp") } }
            }
        default:
            EmptyView()
        }
    }

    private func smallButton(_ title: String, disabled: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(busyKey != nil || disabled)
    }

    // MARK: Actions

    private func refreshAll() {
        Task {
            for tool in tools {
                let s = await Task.detached {
                    ToolManager.status(for: tool.probe, versionArgs: tool.versionArgs)
                }.value
                installed[tool.key] = s.installed
                version[tool.key] = s.version
            }
        }
    }

    private func run(_ tool: Tool, _ op: @escaping () async -> String) {
        busyKey = tool.key
        message[tool.key] = nil
        let before = (installed[tool.key] ?? false) ? version[tool.key] : nil
        Task {
            let raw = await op()
            let after = await Task.detached {
                ToolManager.status(for: tool.probe, versionArgs: tool.versionArgs)
            }.value
            installed[tool.key] = after.installed
            version[tool.key] = after.version
            message[tool.key] = summarize(tool: tool, before: before, after: after, raw: raw)
            busyKey = nil
        }
    }

    /// Turn raw command output into a one-line, human result.
    private func summarize(tool: Tool, before: String?, after: ToolManager.ToolStatus, raw: String) -> String {
        guard after.installed else {
            return raw.split(separator: "\n").last.map(String.init) ?? "Failed."
        }
        if tool.key == "brew" { return "Refreshed (\(after.version))" }
        if before == nil { return "Installed \(after.version)" }
        if before != after.version { return "Updated \(before!) → \(after.version)" }
        return "Already up to date"
    }
}
