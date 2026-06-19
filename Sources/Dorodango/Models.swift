import Foundation
import SwiftUI

// MARK: - Processing settings

/// User-adjustable settings exposed in the menu bar panel.
/// Mirrors the original Dorodango bash pipeline, with knobs surfaced.
struct ProcessingSettings {

    // Video quality: capped-CRF model (quality floor + bitrate ceiling).
    var crf: Int = 21                 // x264 quality. Lower = better/bigger. 18–28 useful.
    var bitrateCapKbps: Int = 6000    // -maxrate ceiling for busy scenes.

    /// bufsize tracks the cap at the original 1.33× ratio (8000/6000).
    var bufsizeKbps: Int { Int((Double(bitrateCapKbps) * 4.0 / 3.0).rounded()) }

    // Encoder + speed are a single axis now. The slider runs best→fast across
    // the x264 preset ladder, and its final detent engages hardware encoding.
    var speedIndex: Int = 0           // 0 = best quality (slow); max = hardware.

    /// x264 presets ordered best (slowest) → fastest. The hardware detent sits
    /// one past the end of this array.
    static let presetLadder: [EncoderPreset] =
        [.slow, .medium, .fast, .faster, .veryfast, .superfast, .ultrafast]

    /// Slider index that means "hardware engine".
    static var hardwareIndex: Int { presetLadder.count }
    /// Maximum slider index (== hardwareIndex).
    static var maxSpeedIndex: Int { presetLadder.count }

    /// True when the speed slider is parked on the hardware detent.
    var isHardware: Bool { speedIndex >= Self.hardwareIndex }

    /// The x264 preset for the current slider position (ignored in hardware mode).
    var currentPreset: EncoderPreset {
        Self.presetLadder[min(max(speedIndex, 0), Self.presetLadder.count - 1)]
    }

    /// ffmpeg video codec for the current mode.
    var videoCodec: String { isHardware ? "h264_videotoolbox" : "libx264" }

    /// Short label shown next to the speed slider.
    var speedLabel: String { isHardware ? "Hardware" : currentPreset.rawValue }

    // Audio.
    var audioChannels: AudioChannels = .stereo
    var loudnessTargetLUFS: Double = -16.0
    var compression: Compression = .medium
    var audioBitrateKbps: Int = 128

    // Download (yt-dlp). Caps the fetched resolution before encoding.
    var downloadQuality: DownloadQuality = .p1080

    // Output + UX.
    var outputSuffix: String = "_COMP"
    var outputFolder: URL? = nil      // nil => alongside the source file.
    var notifyOnComplete: Bool = true

    enum DownloadQuality: String, CaseIterable, Identifiable {
        case source = "Source"
        case p2160 = "2160p"
        case p1080 = "1080p"
        case p720 = "720p"
        var id: String { rawValue }

        /// yt-dlp -f selector with a graceful fallback.
        var formatSelector: String {
            switch self {
            case .source: return "bestvideo+bestaudio/best"
            case .p2160:  return "bestvideo[height<=2160]+bestaudio/best[height<=2160]"
            case .p1080:  return "bestvideo[height<=1080]+bestaudio/best[height<=1080]"
            case .p720:   return "bestvideo[height<=720]+bestaudio/best[height<=720]"
            }
        }
    }

    // MARK: Enums

    /// x264 preset names. Ordering for the slider lives in `presetLadder`.
    enum EncoderPreset: String, CaseIterable, Identifiable {
        case ultrafast, superfast, veryfast, faster, fast, medium, slow
        var id: String { rawValue }
    }

    enum AudioChannels: String, CaseIterable, Identifiable {
        case stereo = "Stereo"
        case mono = "Sum to mono"
        var id: String { rawValue }
        var ffmpegChannels: Int { self == .stereo ? 2 : 1 }
    }

    /// Dynamics compression intensity. `.off` bypasses the filter entirely.
    /// Stepped so each level is reproducible; the slider snaps to these detents.
    enum Compression: String, CaseIterable, Identifiable {
        case off = "Off"
        case light = "Light"
        case medium = "Medium"
        case heavy = "Heavy"
        var id: String { rawValue }

        static var ladder: [Compression] { allCases } // off → heavy
        var index: Int { Self.ladder.firstIndex(of: self) ?? 0 }
        static func at(index: Int) -> Compression {
            ladder[min(max(index, 0), ladder.count - 1)]
        }

        /// The acompressor filter string, or nil when off.
        var acompressorFilter: String? {
            switch self {
            case .off:    return nil
            case .light:  return "acompressor=threshold=-18dB:ratio=2:attack=20:release=250:makeup=3"
            case .medium: return "acompressor=threshold=-18dB:ratio=4:attack=20:release=250:makeup=6"
            case .heavy:  return "acompressor=threshold=-20dB:ratio=6:attack=10:release=200:makeup=8"
            }
        }
    }
}

// MARK: - Queue item

/// A single video waiting to be / being / done being processed. The source is
/// either a local file or a remote URL (downloaded via yt-dlp first).
final class QueueItem: ObservableObject, Identifiable {
    let id = UUID()
    let source: Source

    @Published var status: Status = .queued
    @Published var progress: Double = 0.0      // 0.0 ... 1.0 for the active phase
    @Published var detail: String = ""          // e.g. "120 MB → 38 MB (−68%)"
    @Published var outputURL: URL? = nil
    /// The file actually fed to ffmpeg. For files this is the source; for remote
    /// items it's filled in once yt-dlp finishes downloading.
    @Published var resolvedInput: URL?
    /// Learned title for remote items (from the downloaded filename).
    @Published var title: String?

    init(fileURL: URL) {
        self.source = .file(fileURL)
        self.resolvedInput = fileURL
    }

    init(remote urlString: String) {
        self.source = .remote(urlString)
        self.resolvedInput = nil
    }

    enum Source {
        case file(URL)
        case remote(String)
    }

    var isRemote: Bool {
        if case .remote = source { return true }
        return false
    }

    /// What to show in the row.
    var displayName: String {
        if let title { return title }
        switch source {
        case .file(let url):  return url.lastPathComponent
        case .remote(let str): return str
        }
    }

    enum Status: Equatable {
        case queued
        case downloading
        case processing
        case done
        case failed(String)
        case cancelled

        var label: String {
            switch self {
            case .queued: return "Queued"
            case .downloading: return "Downloading"
            case .processing: return "Processing"
            case .done: return "Done"
            case .failed: return "Failed"
            case .cancelled: return "Cancelled"
            }
        }

        var symbolName: String {
            switch self {
            case .queued: return "clock"
            case .downloading: return "arrow.down.circle"
            case .processing: return "gearshape.2"
            case .done: return "checkmark.circle.fill"
            case .failed: return "exclamationmark.triangle.fill"
            case .cancelled: return "xmark.circle"
            }
        }

        var tint: Color {
            switch self {
            case .queued: return .secondary
            case .downloading: return .accentColor
            case .processing: return .accentColor
            case .done: return .green
            case .failed: return .red
            case .cancelled: return .orange
            }
        }

        /// True while the item is actively occupying the worker.
        var isActive: Bool { self == .downloading || self == .processing }
    }
}
