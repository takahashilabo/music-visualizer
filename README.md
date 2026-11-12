# Music Visualizer

A tiny native macOS app that sits beside your work and reacts to whatever
audio your Mac is playing — Apple Music, Spotify, a browser tab, anything —
rendered as a dynamic, geometric wireframe pattern inspired by
[Rhizomatiks](https://rhizomatiks.com/)-style audio-reactive visuals.

No virtual audio driver (BlackHole, etc.) required — it taps the system's
audio output directly via Core Audio's Process Tap API.

## What it looks like

A warped, rotating polar grid (concentric rings + radial spokes), all
generated procedurally on the GPU:

- **Bass** makes the grid breathe and warp outward
- **Mid** drives rotation speed
- **Treble** shifts the color between cyan and white, and jitters the spokes
- **Beats** flash the whole pattern

## Window behavior

The window is borderless, transparent, and **click-through by default** —
it won't steal clicks from whatever is underneath it, so it can just sit at
the edge of your screen without getting in the way.

- Click the waveform icon in the menu bar to control it.
- **Edit Mode (Move / Resize)** makes the window draggable/resizable (shows
  a dashed outline + a corner grip). Toggle it off again to lock the window
  back into click-through mode.
- **Show on All Spaces & Full Screen** keeps it visible across virtual
  desktops and full-screen apps.
- **Quit** exits the app completely — the status bar icon disappears when
  it's not running.

The visualization scales to whatever size/aspect ratio you resize the
window to, so it works equally well as a tall strip or a wide strip docked
at a screen edge.

## Requirements

- macOS 14.4 (Sonoma) or later — the system audio tap API this app uses
  wasn't available before that.
- Apple Silicon or Intel Mac.

## Installing

Grab the latest `.dmg` from [Releases](../../releases), open it, and drag
**MusicVisualizer.app** to Applications.

Since this isn't notarized with a paid Apple Developer certificate,
Gatekeeper will likely refuse to open it the first time
("can't be opened because Apple cannot check it for malicious software" or
similar). To run it anyway:

- Right-click (or Control-click) the app → **Open** → **Open** again in the
  dialog, **or**
- Run `xattr -cr /Applications/MusicVisualizer.app` in Terminal to clear
  the quarantine flag.

The first time it starts, macOS will ask for permission to record system
audio — that's this app requesting the tap, not a microphone. Allow it.

## Troubleshooting

**The window shows the pattern, but it never reacts to music.** This
almost always means the system audio permission isn't actually granted,
even though the visual still renders (it just has no real audio feeding
it). Check **System Settings → Privacy & Security → Screen & System Audio
Recording**, and make sure MusicVisualizer is listed there and enabled. If
you toggle it, quit the app (menu bar icon → Quit) and reopen it.

If it's building/running from more than one location (e.g. a copy built
from source alongside a copy installed from the `.dmg`), macOS may treat
each as a separate entry in that list because their code signatures
differ — check that the specific copy you're running is the one that's
enabled.

If MusicVisualizer doesn't show up in that list at all, you likely missed
or dismissed the permission prompt on first launch. Delete the app, empty
the Trash, and reinstall from the `.dmg` so the prompt fires again.

## Building from source

This is a Swift Package Manager project — no Xcode project file needed, but
you do need the **full Xcode app** installed (not just the Command Line
Tools) for its Metal shader compiler:

```sh
git clone https://github.com/takahashilabo/music-visualizer.git
cd music-visualizer
./build.sh run
```

`build.sh` builds the Swift package, assembles `MusicVisualizer.app`,
ad-hoc code-signs it, and (with the `run` argument) launches it.

If you hit `unable to spawn process 'metal'`, Xcode's Metal toolchain isn't
installed yet:

```sh
sudo DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -license
xcodebuild -downloadComponent MetalToolchain
```

## How it works

- **Audio capture** — `SystemAudioTap.swift` uses Core Audio's Process Tap
  API (`CATapDescription` + `AudioHardwareCreateProcessTap` +
  `AudioHardwareCreateAggregateDevice`, macOS 14.2+) to get a live mixdown
  of the system's audio output.
- **Analysis** — `AudioAnalyzer.swift` runs a windowed FFT (Accelerate /
  vDSP) to extract bass/mid/treble band energy, overall loudness, and
  beat/onset detection via spectral flux.
- **Rendering** — `GeometricRenderer.swift` + `Shaders.metal` draw the whole
  pattern in a single Metal draw call: the vertex shader computes every
  ring/spoke line segment procedurally from `vertex_id`, no vertex buffer
  needed.
- **Window** — `VisualizerPanel.swift` is a borderless, transparent,
  click-through `NSPanel` living at `.floating` level; `AppDelegate.swift`
  wires everything together and drives the menu bar controls.

## Platform scope

This intentionally doesn't exist for iOS/Android: neither platform exposes
a public API for one app to capture another app's audio output, which is
the whole point of this project (reacting to whatever is already playing,
with zero setup). A version that visualizes audio played *from within the
app itself* would be a different project.

## License

MIT
