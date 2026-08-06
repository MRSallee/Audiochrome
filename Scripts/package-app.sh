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

# Finder / Get Info app icon.
ICON_SRC="$ROOT/Sources/Audiochrome/Resources/AppIcon.icns"
if [[ -f "$ICON_SRC" ]]; then
  cp "$ICON_SRC" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

# Starter EQ profiles (first-launch seed into ~/Documents/Audiochrome/EQ profiles).
DEFAULT_EQ_SRC="$ROOT/Sources/Audiochrome/Resources/DefaultEQProfiles"
if [[ -d "$DEFAULT_EQ_SRC" ]]; then
  rm -rf "$APP_DIR/Contents/Resources/DefaultEQProfiles"
  cp -R "$DEFAULT_EQ_SRC" "$APP_DIR/Contents/Resources/DefaultEQProfiles"
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
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>app.audiochrome.Audiochrome</string>
	<key>CFBundleName</key>
	<string>Audiochrome</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0.2</string>
	<key>CFBundleVersion</key>
	<string>13</string>
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

# Ad-hoc sign with a *stable* identifier matching CFBundleIdentifier.
# If the code-signing ID drifts (Audiochrome-<hash>), UNUserNotificationCenter
# silently fails and notification permission resets every rebuild.
# Google Drive (and some sync tools) stamp xattrs/resource forks that make
# codesign refuse to bind Info.plist — strip them before signing.
if command -v codesign >/dev/null; then
  if command -v xattr >/dev/null; then
    xattr -cr "$APP_DIR" 2>/dev/null || true
  fi
  if [[ -d "${RESOURCE_BUNDLE_DST:-}" ]]; then
    codesign --force --sign - \
      --identifier "app.audiochrome.Audiochrome.resources" \
      "$RESOURCE_BUNDLE_DST"
  fi
  # Sign innermost → outermost so the app bundle binds Info.plist.
  codesign --force --sign - \
    --identifier "app.audiochrome.Audiochrome" \
    "$APP_DIR/Contents/MacOS/Audiochrome"
  codesign --force --sign - \
    --identifier "app.audiochrome.Audiochrome" \
    "$APP_DIR"
  echo "codesign:"
  codesign -dv --verbose=2 "$APP_DIR" 2>&1 | grep -E 'Identifier=|Info.plist' || true
fi
if [[ -x /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister ]]; then
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DIR" 2>/dev/null || true
fi

echo "Created $APP_DIR"
echo "Run with: open \"$APP_DIR\""
