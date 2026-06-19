# Dorodango — menu bar video processor

A native macOS menu bar app (SwiftUI `MenuBarExtra`) that batch-compresses,
caps bitrate, and loudness-normalizes video with `ffmpeg`. It's the menu bar
upgrade of the original Automator droplet: quick processing settings, a queue,
per-file + overall progress, and a "batch done" notification.

## Requirements

- macOS 13 (Ventura) or later
- Xcode command line tools: `xcode-select --install`
- ffmpeg: `brew install ffmpeg`  (provides both `ffmpeg` and `ffprobe`)
- yt-dlp (optional, for URL downloads): `brew install yt-dlp`

## Build & run

```bash
cd DorodangoMenuBar
chmod +x build-app.sh
./build-app.sh            # produces build/Dorodango.app
open build/Dorodango.app
```

A circle icon appears in your menu bar (no Dock icon — it's an `LSUIElement`
agent app). Click it to open the panel. For quick iteration: `swift run`.

## The pipeline

This reproduces the original Dorodango bash workflow and exposes its knobs.
Output is always `<name>_COMP.mp4` (suffix configurable in code).

**Video** — capped CRF by default: `libx264 -crf 21 -maxrate <cap> -bufsize <1.33×cap>`,
`-preset slow`, `profile main`, `yuv420p`, Rec.709 color tags, `+faststart`.

**Audio** (auto-detected; `-an` when absent) — optional `acompressor` dynamics
stage, then `loudnorm` to the target LUFS, then `aac` at the chosen bitrate,
48 kHz, stereo or summed mono.

## Settings

| Control | What it does | Default |
|---|---|---|
| Quality (CRF) | x264 quality floor, 18–28. Lower = better/bigger. Disabled in hardware mode | 21 |
| Bitrate | `(cap)` ceiling in x264, `(target)` in hardware; bufsize auto-tracks at 1.33× | 6000k |
| Speed | One axis: best→fast across the x264 ladder, final detent = hardware engine | slow (best) |
| Channels | Stereo (`-ac 2`) or Sum to mono (`-ac 1`) | Stereo |
| Loudness | `loudnorm` integrated target, −24…−9 LUFS (TP −1.5, LRA 11 fixed) | −16 |
| Compression | Off / Light / Medium / Heavy dynamics; bottom = bypassed | Medium |
| Audio bitrate | AAC bitrate 96/128/192/256k | 128k |
| Save to | Destination folder, or alongside source | source |
| Notify | Notification Center banner when the batch finishes | on |

### Speed / encoder (one slider)

There's no separate encoder switch. The Speed slider *is* the encoder choice:

- **Best → Fast** walk the x264 preset ladder (`slow → medium → fast → faster →
  veryfast → superfast → ultrafast`) at constant quality. CRF drives the result;
  the Bitrate `(cap)` is a ceiling for busy scenes. Best quality-per-megabyte.
- **HW** (the final, separated detent) switches to `h264_videotoolbox` on the Mac
  media engine. Near-realtime, but ignores CRF — so the Quality slider grays out
  and the Bitrate label flips to `(target)`, driving the encode by bitrate
  instead. Lower quality-per-megabyte; use when turnaround beats file size.

Watch the bitrate semantics: in x264 it caps peaks (quality-first); on the HW
detent the same number becomes the bitrate the encoder aims for.

### Compression intensity

Stepped so each level is reproducible (the slider snaps to detents):

| Level | acompressor |
|---|---|
| Off | filter bypassed (loudnorm only) |
| Light | `threshold=-18dB:ratio=2:attack=20:release=250:makeup=3` |
| Medium | `threshold=-18dB:ratio=4:attack=20:release=250:makeup=6` (original) |
| Heavy | `threshold=-20dB:ratio=6:attack=10:release=200:makeup=8` |

## Downloading with yt-dlp

Paste a video URL into the link row and hit **Add URL**. Remote items run a
two-phase job: yt-dlp downloads to a temp folder first (with its own progress
bar), then the result feeds straight into the normal encode pipeline. The
**Download quality** setting caps resolution (`Source` / 2160 / 1080 / 720) via
yt-dlp's `-f` selector. Finished downloads land in `~/Downloads` unless you've
chosen an output folder. Note: downloading is subject to each site's terms — use
responsibly.

## Tools section

Settings includes a Tools panel showing the installed ffmpeg / ffprobe / yt-dlp
versions. **Update yt-dlp** runs `yt-dlp -U` (its built-in self-update, no brew
needed). **Update ffmpeg (brew)** runs `brew upgrade ffmpeg`. yt-dlp breaks often
as sites change, so update it first when a download misbehaves.

## Using it

- **Drop videos** on the panel or click **Add files…**; they queue and process
  one at a time automatically.
- The **sliders button** (top right) flips to settings.
- Each row shows a live progress bar; finished rows show a size delta
  (e.g. `120 MB → 38 MB  (−68%)`) and a Reveal-in-Finder button.
- Footer shows overall queue progress and items remaining.

## Architecture

```
DorodangoApp            MenuBarExtra scene + menu bar icon
  └─ ProcessingQueue    @MainActor ObservableObject — serial work loop, owns
     │                  settings + items, overall progress, completion notify
     ├─ ProcessingSettings   value type bound to the settings controls
     ├─ [QueueItem]          per-file observable: status, progress, detail
     └─ FFmpegRunner         locates ffmpeg/ffprobe, probes duration + audio,
                             builds args, parses `-progress` for real progress
Views: MenuContentView (panel) · DropZone · QueueListView/QueueRowView · SettingsView
```

Progress is real: `ffprobe` reports source duration, then ffmpeg's `out_time_ms`
from `-progress pipe:1` is divided by it.

## Caveats / next steps

- The Rec.709 tags *label* color without converting — correct for SDR HD, wrong
  for HDR/Rec.2020 sources. Add a "preserve source color" escape hatch if you
  ever feed it HDR.
- Faster presets at the same CRF produce bigger files, so with a tight bitrate
  cap, turbo mode hits the ceiling more often and quality drops in busy scenes.
- Two-pass `loudnorm` (measure → apply) is more accurate than the current
  single pass; could be a "high accuracy loudness" toggle.
- Settings reset each launch; persist with `@AppStorage` when you're happy with
  the defaults.
