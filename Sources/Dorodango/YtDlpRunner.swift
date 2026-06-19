import Foundation

/// Downloads a remote video with yt-dlp into a temp folder, parsing yt-dlp's
/// `--progress-template` output for fractional progress. The resulting file is
/// then handed to FFmpegRunner like any local source.
///
/// Requires `brew install yt-dlp` (it shells out to ffmpeg for muxing).
final class YtDlpRunner {
    private let formatSelector: String
    private var process: Process?
    private var cancelled = false

    init(formatSelector: String) {
        self.formatSelector = formatSelector
    }

    func cancel() {
        cancelled = true
        process?.terminate()
    }

    /// Download `urlString` into a fresh temp directory.
    /// - Returns: the downloaded media file.
    func download(urlString: String,
                  onProgress: @escaping (Double, String?) -> Void) async throws -> URL {

        guard let ytdlp = ToolManager.locate("yt-dlp") else {
            throw DownloadError.toolMissing
        }

        // Unique scratch dir so we can reliably find the one produced file.
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dorodango-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let args = [
            "-f", formatSelector,
            "--no-playlist",
            "--newline",
            "--progress-template", "download:%(progress._percent_str)s",
            "-o", workDir.appendingPathComponent("%(title).200s.%(ext)s").path,
            urlString
        ]

        return try await withCheckedThrowingContinuation { continuation in
            let proc = Process()
            self.process = proc
            proc.executableURL = URL(fileURLWithPath: ytdlp)
            proc.arguments = args

            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            let stderrTail = TailBuffer()

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                guard let chunk = String(data: handle.availableData, encoding: .utf8),
                      !chunk.isEmpty else { return }
                // Lines look like "  45.3%" (percent resets between video/audio streams).
                for raw in chunk.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                    let s = raw.trimmingCharacters(in: .whitespaces)
                    guard s.hasSuffix("%"), let pct = Double(s.dropLast()) else { continue }
                    onProgress(min(max(pct / 100.0, 0), 1), "Downloading…")
                }
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                if let s = String(data: handle.availableData, encoding: .utf8), !s.isEmpty {
                    stderrTail.append(s)
                }
            }

            proc.terminationHandler = { p in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil

                if self.cancelled {
                    try? FileManager.default.removeItem(at: workDir)
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard p.terminationStatus == 0 else {
                    let lastLine = stderrTail.value.split(separator: "\n").last.map(String.init) ?? ""
                    continuation.resume(throwing: DownloadError.failed(lastLine))
                    return
                }
                // yt-dlp wrote one media file into workDir — return it.
                if let file = Self.newestMediaFile(in: workDir) {
                    continuation.resume(returning: file)
                } else {
                    continuation.resume(throwing: DownloadError.noOutput)
                }
            }

            do { try proc.run() }
            catch { continuation.resume(throwing: error) }
        }
    }

    private static func newestMediaFile(in dir: URL) -> URL? {
        let skip: Set<String> = ["part", "ytdl", "tmp"]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { !skip.contains($0.pathExtension.lowercased()) }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return da < db
            }
    }

    enum DownloadError: LocalizedError {
        case toolMissing
        case failed(String)
        case noOutput
        var errorDescription: String? {
            switch self {
            case .toolMissing: return "yt-dlp not found. Install it with: brew install yt-dlp"
            case .failed(let m): return "Download failed. \(m)"
            case .noOutput: return "Download finished but no file was produced."
            }
        }
    }
}
