<p align="center">
  <img src="docs/Audiochrome-cover.png" alt="Audiochrome">
</p>

- Lightweight system-wide parametric EQ for macOS
- Active EQ reminders. Never accidentally use EQ when you don't want to
- Per-device PEQ profile mapping
- Level-matched compare mode
- Simple interface for creating and editing PEQ profiles
- Import PEQ profiles from Squiglink and other tools
- Support for separate left and right channel PEQ profiles
- Saturation, crossfeed, and subharmonics effects
- Disables cleanly. Doesn't touch system audio when Audiochrome is off

**[Download](https://github.com/MRSallee/Audiochrome/releases/latest/download/Audiochrome.zip)** the signed, notarized app (macOS 14.2+).

> **v1.6.8** — EQ editor groups filters by Both / Left / Right channel; Available EQs and Effects open when nothing is selected; Other Devices and an open device stay exclusive.  
> Grant **System Audio Recording** access when prompted.

## Requirements

- macOS 14.2+
- **System Audio Recording** access when prompted (to process system audio)

Building from source also needs Swift 5.9+ and Xcode Command Line Tools (full Xcode optional).

## Build from source

```bash
# Parser / device smoke checks (no full Xcode / XCTest required)
swift run AudiochromeSmoke

# Local debug .app (ad-hoc sign)
./Scripts/package-app.sh debug

# Distributable release: Developer ID sign → notarize → staple → zip
./Scripts/package-app.sh release
open .build/Audiochrome.app
# Share: .build/Audiochrome-<version>.zip
```

Requires a **Developer ID Application** cert and `notarytool` profile `Audiochrome` (see `xcrun notarytool store-credentials`). Skip notarization with `SKIP_NOTARIZE=1`.

Or run the binary directly:

```bash
swift run Audiochrome
```

## Profiles

Place Equalizer APO / Squiglink `.txt` files in:

```text
~/Documents/Audiochrome/EQ profiles/
```

On first launch Audiochrome creates that folder and seeds a few starter profiles. Change Folder… on an output can point at any other directory. Config (per-device enable, profile, color) stays in:

```text
~/Library/Application Support/Audiochrome/config.json
```

Supported profile shapes:

- Linked stereo (no `Channel:` lines)
- Independent L/R (`Channel: L` / `Channel: R`)

## Architecture (current)

| Piece | Role |
|-------|------|
| `Audiochrome` | Status-item panel UI (AppKit + SwiftUI) |
| `AudiochromeCore` | Parser, config, devices, engine orchestration |
| `ProcessTapAudioEngine` | System-wide EQ via process tap + aggregate replay |
| `EQProcessor` | Parametric biquads (Squiglink / APO), L/R + preamp |
| `StubAudioEngine` | Fallback when process tap is unavailable |
