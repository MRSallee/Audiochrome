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
RESOURCE_BUNDLE_SRC="$PRODUCT_DIR/Audiochrome_Audiochrome.bundle"
RESOURCE_BUNDLE_DST="$APP_DIR/Contents/MacOS/Audiochrome_Audiochrome.bundle"
if [[ -d "$RESOURCE_BUNDLE_SRC" ]]; then
  cp -R "$RESOURCE_BUNDLE_SRC" "$RESOURCE_BUNDLE_DST"
  # Incomplete SPM bundles break `codesign --deep`; give it a minimal Info.plist.
  if [[ ! -f "$RESOURCE_BUNDLE_DST/Info.plist" ]]; then
    cat > "$RESOURCE_BUNDLE_DST/Info.plist" <<'BUNDLE_PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>app.audiochrome.Audiochrome.resources</string>
	<key>CFBundleName</key>
	<string>Audiochrome_Audiochrome</string>
	<key>CFBundlePackageType</key>
	<string>BNDL</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
</dict>
</plist>
BUNDLE_PLIST
  fi
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
	<string>0.6.0</string>
	<key>CFBundleVersion</key>
	<string>6</string>
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

# Ad-hoc sign with a stable identifier. Unsigned / mis-signed SPM apps get silent
# UNUserNotificationCenter failures instead of a permission dialog.
if command -v codesign >/dev/null; then
  if [[ -d "$RESOURCE_BUNDLE_DST" ]]; then
    codesign --force --sign - --identifier "app.audiochrome.Audiochrome.resources" "$RESOURCE_BUNDLE_DST" || true
  fi
  codesign --force --sign - --identifier "app.audiochrome.Audiochrome" "$APP_DIR/Contents/MacOS/Audiochrome" || true
  codesign --force --sign - --identifier "app.audiochrome.Audiochrome" "$APP_DIR" || true
fi
if [[ -x /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister ]]; then
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DIR" 2>/dev/null || true
fi

echo "Created $APP_DIR"
echo "Run with: open \"$APP_DIR\""
