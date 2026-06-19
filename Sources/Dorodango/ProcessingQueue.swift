import Foundation
import SwiftUI

/// Owns the queue, runs items one at a time, and surfaces overall progress
/// for the menu bar UI. The actual encode work is delegated to FFmpegRunner.
@MainActor
final class ProcessingQueue: ObservableObject {
    @Published private(set) var items: [QueueItem] = []
    @Published private(set) var isRunning: Bool = false
    private var currentItem: QueueItem? = nil   // internal guard only; no view reads it

    /// Settings live here so a single source of truth drives both UI and encoder.
    @Published var settings = ProcessingSettings()

    private var runner: FFmpegRunner?
    private var downloader: YtDlpRunner?
    private var cancelRequested = false

    // MARK: Queue management

    func add(urls: [URL]) {
        let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "mkv", "avi",
                                            "webm", "flv", "wmv", "mpg", "mpeg", "ts"]
        let newItems = urls
            .filter { videoExtensions.contains($0.pathExtension.lowercased()) }
            .map { QueueItem(fileURL: $0) }
        items.append(contentsOf: newItems)
        startIfIdle()
    }

    /// Add a remote URL to be downloaded (yt-dlp) then encoded.
    func add(remote urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("http") else { return }
        items.append(QueueItem(remote: trimmed))
        startIfIdle()
    }

    func remove(_ item: QueueItem) {
        guard item.id != currentItem?.id else { return } // don't yank the running one
        items.removeAll { $0.id == item.id }
    }

    func clearFinished() {
        items.removeAll {
            switch $0.status {
            case .done, .failed, .cancelled: return true
            default: return false
            }
        }
    }

    func cancelCurrent() {
        cancelRequested = true
        downloader?.cancel()
        runner?.cancel()
    }

    // MARK: Serial runner

    private func startIfIdle() {
        guard !isRunning else { return }
        Task { await runLoop() }
    }

    private func runLoop() async {
        isRunning = true
        var succeeded = 0, failed = 0
        defer {
            isRunning = false
            currentItem = nil
            if settings.notifyOnComplete && (succeeded + failed) > 0 {
                Self.notify(succeeded: succeeded, failed: failed)
            }
        }

        while let next = items.first(where: { $0.status == .queued }) {
            if cancelRequested { cancelRequested = false }
            currentItem = next

            do {
                // Phase 1 — download remote items first.
                let input: URL
                if next.isRemote, case .remote(let urlString) = next.source {
                    next.status = .downloading
                    next.progress = 0
                    let dl = YtDlpRunner(formatSelector: settings.downloadQuality.formatSelector)
                    self.downloader = dl
                    input = try await dl.download(urlString: urlString) { [weak next] fraction, detail in
                        Task { @MainActor in
                            next?.progress = fraction
                            if let detail { next?.detail = detail }
                        }
                    }
                    self.downloader = nil
                    next.resolvedInput = input
                    next.title = input.lastPathComponent
                } else {
                    input = next.resolvedInput ?? { if case .file(let u) = next.source { return u }; return URL(fileURLWithPath: "/") }()
                }

                // Phase 2 — encode.
                next.status = .processing
                next.progress = 0
                let runner = FFmpegRunner(settings: settings)
                self.runner = runner
                let output = try await runner.process(inputURL: input,
                                                      destination: destinationFolder(for: next)) { [weak next] fraction, detail in
                    Task { @MainActor in
                        next?.progress = fraction
                        if let detail { next?.detail = detail }
                    }
                }
                self.runner = nil

                next.outputURL = output
                next.progress = 1.0
                next.status = .done
                succeeded += 1
            } catch is CancellationError {
                next.status = .cancelled
            } catch {
                next.status = .failed(error.localizedDescription)
                failed += 1
            }
            self.runner = nil
            self.downloader = nil
        }
    }

    /// Remote downloads land in a temp dir, so the encode for them defaults to
    /// ~/Downloads unless the user picked an output folder. File items use the
    /// configured folder or sit next to the source.
    private func destinationFolder(for item: QueueItem) -> URL? {
        if let chosen = settings.outputFolder { return chosen }
        if item.isRemote {
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        }
        return nil // FFmpegRunner falls back to the source's own folder
    }

    /// Fire a Notification Center banner attributed to Dorodango.
    nonisolated private static func notify(succeeded: Int, failed: Int) {
        let total = succeeded + failed
        if failed == 0 {
            Notifier.notify(title: "Dorodango",
                            subtitle: "All files processed successfully.",
                            body: "\(total) file(s) done.")
        } else {
            Notifier.notify(title: "Dorodango",
                            subtitle: "Completed with errors.",
                            body: "\(succeeded)/\(total) succeeded, \(failed) failed.")
        }
    }
}
