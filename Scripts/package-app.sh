#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-debug}"
PRODUCT_DIR="$ROOT/.build/$CONFIG"
APP_DIR="$ROOT/.build/Audiochrome.app"
BINARY="$PRODUCT_DIR/Audiochrome"

echo "Building Audiochrome ($CONFIG)…"
swift build -c "$CONFIG" --product Audiochrome

if [[ ! -x "$BINARY" ]]; then
  echo "error: expected binary at $BINARY" >&2
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BINARY" "$APP_DIR/Contents/MacOS/Audiochrome"

# SPM looks for the resource bundle next to the executable.
RESOURCE_BUNDLE="$PRODUCT_DIR/Audiochrome_Audiochrome.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
  cp -R "$RESOURCE_BUNDLE" "$APP_DIR/Contents/MacOS/"
fi

# Also copy logo into Contents/Resources for Bundle.main lookups.
LOGO_SRC="$ROOT/Sources/Audiochrome/Resources/AudiochromeLogo.png"
if [[ -f "$LOGO_SRC" ]]; then
  cp "$LOGO_SRC" "$APP_DIR/Contents/Resources/AudiochromeLogo.png"
fi

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>Audiochrome</string>
	<key>CFBundleIdentifier</key>
	<string>app.audiochrome.Audiochrome</string>
	<key>CFBundleName</key>
	<string>Audiochrome</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.2</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSAudioCaptureUsageDescription</key>
	<string>Audiochrome needs system audio access to apply EQ to your current output.</string>
</dict>
</plist>
PLIST

echo "Created $APP_DIR"
echo "Run with: open \"$APP_DIR\""
