# Audiochrome

macOS menu bar app for system-wide EQ, with per-output profile mapping.

> **v0.9.0** — Custom status-item panel, optional Custom EQ per device (shared “All Audio” when off), Quit & Relaunch for privacy grants, and settings/login-item support.  
> Grant **System Audio Recording** access when prompted.

## Requirements

- macOS 14.2+
- Swift 5.9+ / Xcode Command Line Tools (full Xcode optional)

## Build & run

```bash
# Parser / device smoke checks (no full Xcode / XCTest required)
swift run AudiochromeSmoke

# Build a menu-bar .app (no Dock icon) and launch
./Scripts/package-app.sh
open .build/Audiochrome.app
```

Or run the binary directly:

```bash
swift run Audiochrome
```

## Profiles

Place Equalizer APO / Squiglink `.txt` files in:

```text
~/Library/Application Support/Audiochrome/Profiles/
```

The folder button in the menu opens that directory in Finder. Config (per-device enable, profile, color) is stored in:

```text
~/Library/Application Support/Audiochrome/config.json
```

Supported profile shapes:

- Linked stereo (no `Channel:` lines)
- Independent L/R (`Channel: L` / `Channel: R`)

## Architecture (current)

| Piece | Role |
|-------|------|
| `Audiochrome` | SwiftUI `MenuBarExtra` UI |
| `AudiochromeCore` | Parser, config, devices, stub audio engine |
| `StubAudioEngine` | Fallback stub |
| `ProcessTapAudioEngine` | System-wide EQ via process tap + aggregate replay |
| `EQProcessor` | Parametric biquads (Squiglink / APO), L/R + preamp |
