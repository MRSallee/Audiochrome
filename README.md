# Audiochrome

macOS menu bar app for system-wide EQ, with per-output profile mapping.

> **v1.4.4** — Smoother live EQ edits while audio plays, and Manage Configuration ordered Export → Import → Reset.  
> Grant **System Audio Recording** access when prompted.

## Requirements

- macOS 14.2+
- Swift 5.9+ / Xcode Command Line Tools (full Xcode optional)

## Build & run

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
