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
	<string>1.4.4</string>
	<key>CFBundleVersion</key>
	<string>21</string>
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

ENTITLEMENTS="$ROOT/Scripts/Audiochrome.entitlements"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist" 2>/dev/null || echo "0")"
DIST_ZIP="$ROOT/.build/Audiochrome-${VERSION}.zip"
NOTARY_PROFILE="${NOTARY_PROFILE:-Audiochrome}"

# Google Drive (and some sync tools) stamp xattrs/resource forks that make
# codesign refuse to bind Info.plist — strip them before signing.
if command -v xattr >/dev/null; then
  xattr -cr "$APP_DIR" 2>/dev/null || true
fi

sign_adhoc() {
  # Stable identifier matching CFBundleIdentifier — if the ID drifts
  # (Audiochrome-<hash>), UNUserNotificationCenter silently fails.
  if [[ -d "${RESOURCE_BUNDLE_DST:-}" ]]; then
    codesign --force --sign - \
      --identifier "app.audiochrome.Audiochrome.resources" \
      "$RESOURCE_BUNDLE_DST"
  fi
  codesign --force --sign - \
    --identifier "app.audiochrome.Audiochrome" \
    "$APP_DIR/Contents/MacOS/Audiochrome"
  codesign --force --sign - \
    --identifier "app.audiochrome.Audiochrome" \
    "$APP_DIR"
}

sign_developer_id() {
  local identity="$1"
  local deep_args=(
    --force
    --options runtime
    --timestamp
    --sign "$identity"
    --entitlements "$ENTITLEMENTS"
  )
  if [[ -d "${RESOURCE_BUNDLE_DST:-}" ]]; then
    codesign "${deep_args[@]}" \
      --identifier "app.audiochrome.Audiochrome.resources" \
      "$RESOURCE_BUNDLE_DST"
  fi
  codesign "${deep_args[@]}" \
    --identifier "app.audiochrome.Audiochrome" \
    "$APP_DIR/Contents/MacOS/Audiochrome"
  codesign "${deep_args[@]}" \
    --identifier "app.audiochrome.Audiochrome" \
    "$APP_DIR"
  codesign --verify --deep --strict --verbose=2 "$APP_DIR"
}

notarize_and_staple() {
  local zip_path="$1"
  echo "Submitting to Apple notarization (profile: $NOTARY_PROFILE)…"
  xcrun notarytool submit "$zip_path" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
  echo "Stapling notarization ticket…"
  xcrun stapler staple "$APP_DIR"
  xcrun stapler validate "$APP_DIR"
}

if ! command -v codesign >/dev/null; then
  echo "warning: codesign not found; app is unsigned" >&2
elif [[ "$CONFIG" == "release" ]]; then
  IDENTITY="${CODESIGN_IDENTITY:-}"
  if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(
      security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' \
        | head -1
    )"
  fi
  if [[ -z "$IDENTITY" ]]; then
    echo "error: no Developer ID Application identity found." >&2
    echo "Install a Developer ID cert, or set CODESIGN_IDENTITY=..." >&2
    exit 1
  fi
  if [[ ! -f "$ENTITLEMENTS" ]]; then
    echo "error: missing entitlements at $ENTITLEMENTS" >&2
    exit 1
  fi

  echo "Signing with ${IDENTITY}..."
  sign_developer_id "$IDENTITY"
  echo "codesign:"
  codesign -dv --verbose=2 "$APP_DIR" 2>&1 | grep -E 'Authority=|Identifier=|Format=|Runtime|Info.plist' || true

  # Zip for notarization, then re-zip after staple for distribution.
  rm -f "$DIST_ZIP"
  ditto -c -k --keepParent "$APP_DIR" "$DIST_ZIP"

  if [[ "${SKIP_NOTARIZE:-0}" == "1" ]]; then
    echo "SKIP_NOTARIZE=1 — signed zip at $DIST_ZIP (not notarized)"
  else
    notarize_and_staple "$DIST_ZIP"
    rm -f "$DIST_ZIP"
    ditto -c -k --keepParent "$APP_DIR" "$DIST_ZIP"
    echo "Notarized distribution zip: $DIST_ZIP"
  fi
else
  sign_adhoc
  echo "codesign (ad-hoc):"
  codesign -dv --verbose=2 "$APP_DIR" 2>&1 | grep -E 'Identifier=|Info.plist' || true
fi

if [[ -x /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister ]]; then
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DIR" 2>/dev/null || true
fi

echo "Created $APP_DIR"
echo "Run with: open \"$APP_DIR\""
if [[ "$CONFIG" == "release" && -f "$DIST_ZIP" ]]; then
  echo "Share: $DIST_ZIP"
fi
