import Foundation

/// Tiny thread-safe text accumulator. Pipe `readabilityHandler`s run on a
/// background queue, so a plain captured `var` trips Swift's concurrency
/// checks; mutating through this constant reference is clean and safe.
final class TailBuffer: @unchecked Sendable {
    private var text = ""
    private let lock = NSLock()

    func append(_ s: String, limit: Int = 800) {
        lock.lock(); defer { lock.unlock() }
        text = String((text + s).suffix(limit))
    }

    var value: String {
        lock.lock(); defer { lock.unlock() }
        return text
    }
}

/// Locates the external CLI tools and reports / updates their versions.
/// ffmpeg + ffprobe are managed via Homebrew; yt-dlp self-updates with `-U`.
enum ToolManager {

    // MARK: Discovery

    static func locate(_ tool: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(tool)",   // Apple Silicon Homebrew
            "/usr/local/bin/\(tool)",      // Intel Homebrew
            "/usr/bin/\(tool)"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        which.arguments = ["which", tool]
        let pipe = Pipe()
        which.standardOutput = pipe
        try? which.run()
        which.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (path?.isEmpty == false) ? path : nil
    }

    // MARK: Status

    struct ToolStatus {
        let name: String
        let installed: Bool
        let version: String
    }

    static func status(for tool: String, versionArgs: [String]) -> ToolStatus {
        guard let path = locate(tool) else {
            return ToolStatus(name: tool, installed: false, version: "not installed")
        }
        let out = run(path, versionArgs).output
        return ToolStatus(name: tool, installed: true, version: parseVersion(tool: tool, raw: out))
    }

    private static func parseVersion(tool: String, raw: String) -> String {
        let first = raw.split(separator: "\n").first.map(String.init) ?? raw
        let parts = first.split(separator: " ")
        switch tool {
        case "ffmpeg", "ffprobe":
            // "ffmpeg version 6.1.1 Copyright ..." → "6.1.1"
            if parts.count >= 3, parts[1] == "version" { return String(parts[2]) }
            return first
        case "brew":
            // "Homebrew 4.2.1" → "4.2.1"
            if parts.count >= 2 { return String(parts[1]) }
            return first
        default:
            // yt-dlp prints just the version string, e.g. "2024.04.09"
            return first.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: Updates

    /// yt-dlp self-update. Works on the standalone binary; brew installs report
    /// that they're managed by brew, which we surface as-is.
    static func updateYtDlp() async -> String {
        guard let path = locate("yt-dlp") else { return "yt-dlp not found." }
        return await runAsync(path, ["-U"]).combined
    }

    /// ffmpeg update via Homebrew (best effort; requires brew on PATH).
    static func updateFfmpeg() async -> String {
        guard let brew = locate("brew") else { return brewMissingNote }
        return await runAsync(brew, ["upgrade", "ffmpeg"]).combined
    }

    /// `brew install <formula>` for a missing tool.
    static func install(_ formula: String) async -> String {
        guard let brew = locate("brew") else { return brewMissingNote }
        return await runAsync(brew, ["install", formula]).combined
    }

    /// `brew update` — refreshes Homebrew itself and its formula list (no sudo).
    static func updateHomebrew() async -> String {
        guard let brew = locate("brew") else { return brewMissingNote }
        return await runAsync(brew, ["update"]).combined
    }

    /// Homebrew's own installer needs an admin password and a real terminal, so
    /// we can't run it silently — we open Terminal with the official command and
    /// let the user complete it there.
    static func openHomebrewInstaller() {
        let cmd = "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        let esc = cmd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(esc)\"\nend tell"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        try? proc.run()
    }

    private static let brewMissingNote =
        "Homebrew not found. Install it first (the Install button opens Terminal)."

    // MARK: Process helpers

    private struct Result { let output: String; let error: String; var combined: String {
        [output, error].filter { !$0.isEmpty }.joined(separator: "\n")
    } }

    private static func run(_ tool: String, _ args: [String]) -> Result {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tool)
        proc.arguments = args
        // GUI apps launch with a minimal PATH; give brew & friends a real one.
        proc.environment = ProcessInfo.processInfo.environment.merging(
            ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]) { _, new in new }
        let out = Pipe(); let err = Pipe()
        proc.standardOutput = out; proc.standardError = err
        try? proc.run()
        proc.waitUntilExit()
        let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return Result(output: o.trimmingCharacters(in: .whitespacesAndNewlines),
                      error: e.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func runAsync(_ tool: String, _ args: [String]) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: run(tool, args))
            }
        }
    }
}
