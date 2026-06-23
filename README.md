# Dorodango — menu bar video processor

<img src="dorodango_icon.png" alt="Dorodango icon" width="120" align="right">

> **As per Adam Savage on Mythbusters S06E14: "You can, in fact, polish a poop."**

Named after the Japanese art of hand-polishing dirt into a smooth, gleaming ball, Dorodango takes rough, oversized footage and works it into a clean, compact, consistent file — quality smoothed, loudness normalized, bitrate reined in.

---

You're the video engineer for a live event. The client delivers their final promotional video minutes before showtime. You load it in as-is. What you missed: bitrate through the roof, audio so quietly normalized it's nearly inaudible. The video stutters. The audio engineer cranks pre-amp gain +30 dB just to hear anything. The client blames you for choppy playback. The audio engineer blames you for making them crank so hard. You hope they turn that channel back down before the next video. If they don't, it fires hot — and you get blamed again.

**We say, we're tired of this 💩.**

---

A native macOS menu bar app that batch-compresses, caps bitrate, and loudness-normalizes video with `ffmpeg`: drag-and-drop or paste-a-URL intake, saved presets, custom ffmpeg flags, a queue with per-file progress, and a "batch done" notification. Built with SwiftUI in a persistent status-bar panel.

## Requirements

- macOS 13 Ventura or later
- Xcode command line tools: `xcode-select --install`
- ffmpeg: `brew install ffmpeg` (provides both `ffmpeg` and `ffprobe`)
- yt-dlp *(optional, for URL downloads)*: `brew install yt-dlp`

## Build & run

```bash
cd Dorodango
chmod +x build-app.sh
./build-app.sh            # produces build/Dorodango.app
open build/Dorodango.app
```

A circle icon appears in your menu bar — no Dock icon, it's an `LSUIElement` agent app. Click it to open the panel. For quick iteration during development, use `swift run`.

## Using it

<img src="ui screenshot.png" alt="Dorodango drop zone" width="300">

- **Drop videos** onto the panel or the menu bar icon, click **Add files…**, or paste a URL into the drop zone — items queue and process one at a time.
- The **sliders button** (top right) opens settings. The queue section appears once it has items, with **Clear done** in its header.
- Each row shows a live progress bar. Finished rows show a size delta (e.g. `120 MB → 38 MB (−68%)`) and a Reveal in Finder button.
- The menu bar icon spins while work is in progress. Right-click it to **Quit**.

## The pipeline

This reproduces the original Dorodango bash workflow and exposes its knobs. Output is always `<name>_COMP.mp4`.

**Video** — capped CRF by default: `libx264 -crf 21 -maxrate <cap> -bufsize <1.33×cap>`, `-preset slow`, profile main, `yuv420p`, Rec.709 color tags, `+faststart`.

**Audio** (auto-detected; `-an` when absent) — optional `acompressor` dynamics stage, then `loudnorm` to the target LUFS, then AAC at the chosen bitrate, 48 kHz, stereo or summed mono.

## Settings

<img src="settings screenshot.png" alt="Dorodango settings panel" width="300">

| Control | What it does | Default |
|---|---|---|
| Quality (CRF) | x264 quality floor, 18–28. Lower = better quality, bigger file. Disabled in hardware mode. | 21 |
| Bitrate | Peak ceiling in x264 `(cap)` or target in hardware `(target)`; bufsize auto-tracks at 1.33×. | 6000k |
| Speed | Walks the x264 preset ladder best→fast; final detent switches to hardware encoder. | slow (best) |
| Channels | Stereo (`-ac 2`) or sum to mono (`-ac 1`). | Stereo |
| Loudness | `loudnorm` integrated target, −24…−9 LUFS (TP −1.5, LRA 11 fixed). | −16 LUFS |
| Compression | Off / Light / Medium / Heavy dynamics; Off bypasses `acompressor`. | Medium |
| Audio bitrate | AAC bitrate: 96 / 128 / 192 / 256k. | 128k |
| Extra flags | Raw ffmpeg flags appended after the video or audio codec block. | *(empty)* |
| Download quality | Caps yt-dlp fetch resolution: Source / 2160p / 1080p / 720p. | 1080p |
| Save to | Destination folder, or alongside source. | source |
| Notify | Notification Center banner when the batch finishes. | on |

Settings are organized into named **presets** selected from a dropdown at the top of the panel.

### Speed / encoder

There's no separate encoder switch — the Speed slider *is* the encoder choice:

- **Best → Fast** walks the x264 preset ladder (`slow → medium → fast → faster → veryfast → superfast → ultrafast`) at constant quality. CRF drives quality; Bitrate `(cap)` is a ceiling for busy scenes. Best quality-per-megabyte.
- **HW** (the final, separated detent) switches to `h264_videotoolbox` on the Mac media engine. Near-realtime, but ignores CRF — the Quality slider grays out and the Bitrate label flips to `(target)`. Lower quality-per-megabyte; use when turnaround matters more than file size.

> **Bitrate semantics differ:** in x264 mode the number caps peaks (quality-first); in HW mode it becomes the encoder's target bitrate.

### Compression intensity

Each level snaps to a reproducible detent:

| Level | acompressor settings |
|---|---|
| Off | Filter bypassed — loudnorm only |
| Light | `threshold=-18dB:ratio=2:attack=20:release=250:makeup=3` |
| Medium | `threshold=-18dB:ratio=4:attack=20:release=250:makeup=6` *(original)* |
| Heavy | `threshold=-20dB:ratio=6:attack=10:release=200:makeup=8` |

## Presets

A preset is a named bundle of *every* processing setting, including custom flags. The **•••** menu offers:

- **Save** — overwrite the selected preset with current settings
- **Save as new…** — store current settings under a new name
- **Rename…**, **Delete**
- **Set as default** — the ★-marked preset loads on launch
- **Import… / Export…** — single presets as `.json` for sharing or backup

The seeded **Default** preset is locked (can't be renamed or deleted) and is the initial launch default. Presets persist in `UserDefaults`.

## Custom ffmpeg flags

Two fields under the audio section append raw flags to the command. **Video** flags are injected right after the video codec block; **Audio** flags right after the audio codec block — so each lands on the correct stream. A quote-aware parser keeps values like `-metadata title="My Clip"` intact.

Examples: `-vf negate`, `-tune film` (video); `-af volume=0.1`, `-ar 44100` (audio). A bad flag causes that item to fail with ffmpeg's error shown in its row — other queued items are unaffected.

## Downloading with yt-dlp

Click the drop zone and paste a URL (⌘V, then ↩), or drop a link onto the panel or menu bar icon. Remote items run a two-phase job: yt-dlp downloads to a temp folder first (with its own progress bar), then the result feeds into the normal encode pipeline. The **Download quality** setting caps resolution via yt-dlp's `-f` selector. Finished downloads land in `~/Downloads` unless you've set an output folder.

> yt-dlp breaks frequently as sites update their internals — when a download misbehaves, update it first: **Settings → Tools → yt-dlp → Update**.

*Downloading is subject to each site's terms of service — use responsibly.*

## Tools panel

A foldable Tools section (chevron next to the title) at the bottom of settings lists Homebrew, ffmpeg, and yt-dlp with their installed versions and per-row **Install** / **Update** actions. Versions are re-checked each time settings opens. yt-dlp self-updates via `yt-dlp -U`; ffmpeg installs and updates through Homebrew.

## Architecture

```
DorodangoApp / AppDelegate   status-bar item + persistent KeyablePanel (NSPanel),
  │                          spinning icon, right-click Quit
  ├─ ProcessingQueue   @MainActor ObservableObject — serial work loop, owns live
  │   │                settings + items, fires the completion notification
  │   ├─ ProcessingSettings   Codable value type bound to the settings controls
  │   ├─ [QueueItem]          per-file observable: file or remote URL, status,
  │   │                       progress, detail string
  │   ├─ YtDlpRunner          downloads remote items, parses yt-dlp progress
  │   └─ FFmpegRunner         locates tools, probes duration + audio, builds args
  │                           (incl. custom flags), parses -progress output
  ├─ PresetStore       presets list, selection, default; JSON import/export
  ├─ ToolManager       locate / version / install / update for brew/ffmpeg/yt-dlp
  └─ Notifier          UserNotifications-based "batch done" banner

Views: MenuContentView · DropZone · QueueListView · QueueRowView
       SettingsView · PresetsBar · ToolsView
```

Progress is real: `ffprobe` reports source duration, then ffmpeg's `out_time_ms` from `-progress pipe:1` is divided by it.

## Caveats & next steps

- **HDR sources:** Rec.709 tags *label* color without converting — correct for SDR HD, but wrong for HDR/Rec.2020 sources. A "preserve source color" escape hatch is needed for HDR material.
- **Faster presets produce larger files** at the same CRF — with a tight bitrate cap, fast mode hits the ceiling more often and quality drops in busy scenes.
- **Two-pass loudnorm** (measure → apply) would be more accurate than the current single pass; could become a "high accuracy loudness" toggle.
- **Conflicting custom flags** (e.g. re-specifying `-c:v`) cause that item to fail rather than silently winning — by design, but worth knowing.
