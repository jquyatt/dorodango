import Foundation

/// Runs ffprobe (duration + audio detection) then ffmpeg, parsing ffmpeg's
/// `-progress` stream for real fractional progress. Mirrors the original
/// Dorodango bash pipeline.
///
/// Requires `brew install ffmpeg` (provides ffmpeg + ffprobe).
final class FFmpegRunner {
    private let settings: ProcessingSettings
    private var process: Process?
    private var cancelled = false

    init(settings: ProcessingSettings) {
        self.settings = settings
    }

    func cancel() {
        cancelled = true
        process?.terminate()
    }

    // MARK: ffprobe helpers

    private func probeDuration(of url: URL, ffprobe: String) -> Double {
        let out = runCapturing(ffprobe, [
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            url.path
        ])
        return Double(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private func hasAudio(_ url: URL, ffprobe: String) -> Bool {
        let out = runCapturing(ffprobe, [
            "-v", "error",
            "-select_streams", "a",
            "-show_entries", "stream=codec_type",
            "-of", "csv=p=0",
            url.path
        ])
        return out.contains("audio")
    }

    private func runCapturing(_ tool: String, _ args: [String]) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tool)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: Output path

    private func outputURL(for source: URL, destination: URL?) -> URL {
        let base = source.deletingPathExtension().lastPathComponent + "_COMP"
        let folder = destination ?? source.deletingLastPathComponent()
        return folder.appendingPathComponent(base).appendingPathExtension("mp4")
    }

    // MARK: Build ffmpeg args

    private func ffmpegArguments(input: URL, output: URL, audioPresent: Bool) -> [String] {
        var args = ["-hide_banner", "-loglevel", "warning", "-y", "-i", input.path]

        // ---- Video ----
        let cap = "\(settings.bitrateCapKbps)k"
        let buf = "\(settings.bufsizeKbps)k"
        if settings.isHardware {
            // VideoToolbox ignores CRF; drive it by bitrate (cap == target).
            args += ["-c:v", "h264_videotoolbox",
                     "-b:v", cap, "-maxrate", cap, "-bufsize", buf]
        } else {
            // Capped CRF: quality floor + bitrate ceiling.
            args += ["-c:v", "libx264",
                     "-crf", "\(settings.crf)",
                     "-maxrate", cap, "-bufsize", buf,
                     "-preset", settings.currentPreset.rawValue]
        }
        // Delivery-compat flags (same in both paths).
        args += ["-profile:v", "main", "-pix_fmt", "yuv420p",
                 "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"]

        // ---- Audio ----
        if audioPresent {
            var chain: [String] = []
            if let comp = settings.compression.acompressorFilter { chain.append(comp) }
            chain.append("loudnorm=I=\(Int(settings.loudnessTargetLUFS)):TP=-1.5:LRA=11")
            args += ["-af", chain.joined(separator: ","),
                     "-c:a", "aac",
                     "-b:a", "\(settings.audioBitrateKbps)k",
                     "-ar", "48000",
                     "-ac", "\(settings.audioChannels.ffmpegChannels)"]
        } else {
            args += ["-an"]
        }

        args += ["-movflags", "+faststart"]

        // Machine-readable progress to stdout.
        args += ["-progress", "pipe:1", "-nostats", output.path]
        return args
    }

    // MARK: Run

    /// - Parameters:
    ///   - input: the local file to encode (a downloaded temp file for remote items)
    ///   - onProgress: (fraction 0...1, optional detail string)
    /// - Returns: URL of the finished file
    func process(inputURL input: URL,
                 destination: URL?,
                 onProgress: @escaping (Double, String?) -> Void) async throws -> URL {

        guard let ffmpeg = ToolManager.locate("ffmpeg") else { throw RunnerError.toolMissing("ffmpeg") }
        guard let ffprobe = ToolManager.locate("ffprobe") else { throw RunnerError.toolMissing("ffprobe") }

        let output = outputURL(for: input, destination: destination)
        let duration = probeDuration(of: input, ffprobe: ffprobe)
        let audioPresent = hasAudio(input, ffprobe: ffprobe)

        return try await withCheckedThrowingContinuation { continuation in
            let proc = Process()
            self.process = proc
            proc.executableURL = URL(fileURLWithPath: ffmpeg)
            proc.arguments = ffmpegArguments(input: input, output: output, audioPresent: audioPresent)

            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            let stderrTail = TailBuffer()

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                guard let chunk = String(data: handle.availableData, encoding: .utf8),
                      !chunk.isEmpty else { return }
                for line in chunk.split(separator: "\n") {
                    let parts = line.split(separator: "=", maxSplits: 1)
                    guard parts.count == 2 else { continue }
                    let key = parts[0].trimmingCharacters(in: .whitespaces)
                    let value = parts[1].trimmingCharacters(in: .whitespaces)
                    if key == "out_time_ms", let us = Double(value), duration > 0 {
                        let seconds = us / 1_000_000.0   // ffmpeg reports microseconds here
                        onProgress(min(max(seconds / duration, 0), 1), nil)
                    }
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
                    try? FileManager.default.removeItem(at: output)
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if p.terminationStatus == 0 {
                    onProgress(1.0, Self.sizeComparison(input: input, output: output))
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(throwing:
                        RunnerError.ffmpegFailed(code: p.terminationStatus, log: stderrTail.value))
                }
            }

            do { try proc.run() }
            catch { continuation.resume(throwing: error) }
        }
    }

    // MARK: Helpers

    private static func sizeComparison(input: URL, output: URL) -> String {
        let fm = FileManager.default
        func size(_ u: URL) -> Int64 {
            (try? fm.attributesOfItem(atPath: u.path)[.size] as? Int64) ?? 0
        }
        let inB = size(input), outB = size(output)
        guard inB > 0, outB > 0 else { return "" }
        let f = ByteCountFormatter(); f.countStyle = .file
        let pct = Int((1.0 - Double(outB) / Double(inB)) * 100)
        let delta = pct >= 0 ? "−\(pct)%" : "+\(-pct)%"
        return "\(f.string(fromByteCount: inB)) → \(f.string(fromByteCount: outB))  (\(delta))"
    }

    enum RunnerError: LocalizedError {
        case toolMissing(String)
        case ffmpegFailed(code: Int32, log: String)
        var errorDescription: String? {
            switch self {
            case .toolMissing(let t):
                return "\(t) not found. Install it with: brew install ffmpeg"
            case .ffmpegFailed(let code, let log):
                let lastLine = log.split(separator: "\n").last.map(String.init) ?? ""
                return "ffmpeg failed (exit \(code)). \(lastLine)"
            }
        }
    }
}
