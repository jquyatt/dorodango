# Dorodango — menu bar video processor

**As per Adam Savage on Mythbusters S06E14, "You can, in fact, polish a poop."**

You're the video engineer for a live event. The client delivers their final promotional video minutes before showtime. You load it in as-is. What you miss: bitrate through the roof, audio normalized so low it's inaudible. The video stutters. The audio engineer cranks the pre-amp gain +30dB just to hear anything. Now the client blames you for choppy playback. The audio engineer blames you for making them crank so hard. You hope they turn that channel back down before the next video. If they don't, it fires hot, and you get blamed again. We say, we're tired of this 💩.

Eponymously inspired by the ancient Japanese art of forming dirt into polished
balls by hand, Dorodango takes rough, oversized footage and patiently works it
into a clean, compact, consistent sphere of a file — quality smoothed, loudness
evened, bitrate reined in.

A native macOS menu bar app (SwiftUI in a persistent status-bar panel) that
batch-compresses, caps bitrate, and loudness-normalizes video with `ffmpeg`:
drag-and-drop or paste-a-URL intake, saved presets, custom ffmpeg flags, a queue
with per-file progress, and a "batch done" notification.

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
Output is always `<name>_COMP.mp4`.

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
| Extra flags | Raw ffmpeg flags appended after the video / audio blocks | empty |
| Download quality | Caps yt-dlp fetch resolution (Source / 2160 / 1080 / 720) | 1080p |
| Save to | Destination folder, or alongside source | source |
| Notify | Notification Center banner when the batch finishes | on |

Settings are organized into named **presets** (see below), with a dropdown at the
top of the panel.

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

## Presets

A preset is a named bundle of *every* processing setting (including the custom
flags). Pick one from the dropdown at the top of settings to load it. The •••
menu offers:

- **Save** — overwrite the selected preset with the current settings
- **Save as new…** — store the current settings under a new name
- **Rename…**, **Delete**
- **Set as default** — the ★-marked preset loads on launch
- **Import… / Export…** — single presets as `.json`, for sharing or backup

The seeded **Default** preset is locked (can't be renamed or deleted) and is the
initial launch default. Presets persist in `UserDefaults`.

## Custom ffmpeg flags

Two fields under the audio section append raw flags to the command. **Video**
flags are injected right after the video codec block; **Audio** flags right after
the audio block — so each lands on the correct stream. A quote-aware parser keeps
values like `-metadata title="My Clip"` intact.

Examples: `-vf negate`, `-tune film` (video); `-af volume=0.1`, `-ar 44100`
(audio). A bad flag just makes that one item fail with ffmpeg's error shown in
its row.

## Downloading with yt-dlp

Click the drop zone and paste a URL (⌘V, then ↩), or drop a link onto the panel
or the menu bar icon. Remote items run a two-phase job: yt-dlp downloads to a
temp folder first (with its own progress bar), then the result feeds straight
into the normal encode pipeline. The
**Download quality** setting caps resolution (`Source` / 2160 / 1080 / 720) via
yt-dlp's `-f` selector. Finished downloads land in `~/Downloads` unless you've
chosen an output folder. Note: downloading is subject to each site's terms — use
responsibly.

## Tools section

A foldable Tools panel (chevron by the title) at the bottom of settings lists
Homebrew / ffmpeg / yt-dlp with their versions and a per-row **Install** or
**Update** action. yt-dlp updates via `yt-dlp -U` (self-update, no brew); ffmpeg
and yt-dlp install/update through Homebrew; Homebrew itself refreshes with
`brew update`, or installs via a Terminal hand-off. It re-checks versions each
time settings opens. yt-dlp breaks often as sites change, so update it first when
a download misbehaves.

## Using it

- **Drop videos** on the panel or the menu bar icon, click **Add files…**, or
  paste a URL into the drop zone; they queue and process one at a time.
- The **sliders button** (top right) flips to settings; the queue section appears
  only once it has items, with **Clear done** in its header.
- Each row shows a live progress bar; finished rows show a size delta
  (e.g. `120 MB → 38 MB  (−68%)`) and a Reveal-in-Finder button.
- The menu bar icon spins while work is in progress. Right-click it for **Quit**.

## Architecture

```
DorodangoApp / AppDelegate   status-bar item + persistent KeyablePanel (NSPanel),
  │                          spinning icon, right-click Quit
  ├─ ProcessingQueue   @MainActor ObservableObject — serial work loop, owns the
  │   │                live settings + items, fires the completion notification
  │   ├─ ProcessingSettings   Codable value type bound to the settings controls
  │   ├─ [QueueItem]          per-file observable: file or remote URL, status,
  │   │                       progress, detail
  │   ├─ YtDlpRunner          downloads remote items, parses yt-dlp progress
  │   └─ FFmpegRunner         locates tools, probes duration + audio, builds args
  │                           (incl. custom flags), parses `-progress`
  ├─ PresetStore       presets list, selection, default; JSON import/export
  ├─ ToolManager       locate / version / install / update for brew/ffmpeg/yt-dlp
  └─ Notifier          UserNotifications-based "batch done" banner
Views: MenuContentView · DropZone · QueueListView/QueueRowView · SettingsView ·
       PresetsBar · ToolsView
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
- Custom flags are appended verbatim — a flag that conflicts with our own (e.g.
  re-specifying `-c:v`) will make that item fail rather than silently win.
