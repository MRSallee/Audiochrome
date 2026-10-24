#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-debug}"
# Release zips are universal. Debug stays native unless UNIVERSAL=1.
if [[ "$CONFIG" == "release" ]]; then
  UNIVERSAL="${UNIVERSAL:-1}"
else
  UNIVERSAL="${UNIVERSAL:-0}"
fi
if [[ "${2:-}" == "universal" ]]; then
  UNIVERSAL=1
elif [[ "${2:-}" == "native" ]]; then
  UNIVERSAL=0
fi
PRODUCT_DIR="$ROOT/.build/$CONFIG"
APP_DIR="$ROOT/.build/Audiochrome.app"
BINARY="$PRODUCT_DIR/Audiochrome"

if [[ "$UNIVERSAL" == "1" ]]; then
  echo "Building Audiochrome ($CONFIG, universal arm64 + x86_64)…"
  swift build -c "$CONFIG" --arch arm64 --product Audiochrome
  swift build -c "$CONFIG" --arch x86_64 --product Audiochrome
  ARM_BIN="$ROOT/.build/arm64-apple-macosx/$CONFIG/Audiochrome"
  X86_BIN="$ROOT/.build/x86_64-apple-macosx/$CONFIG/Audiochrome"
  if [[ ! -x "$ARM_BIN" || ! -x "$X86_BIN" ]]; then
    echo "error: expected arch slices at $ARM_BIN and $X86_BIN" >&2
    exit 1
  fi
  mkdir -p "$PRODUCT_DIR"
  lipo -create "$ARM_BIN" "$X86_BIN" -output "$BINARY"
  lipo -info "$BINARY"
else
  echo "Building Audiochrome ($CONFIG)…"
  swift build -c "$CONFIG" --product Audiochrome
fi

if [[ ! -x "$BINARY" ]]; then
  echo "error: expected binary at $BINARY" >&2
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BINARY" "$APP_DIR/Contents/MacOS/Audiochrome"

# Do not copy SPM's Audiochrome_Audiochrome.bundle into the .app:
# - Next to Contents/ (what Bundle.module wants) is "unsealed contents" and
#   codesign rejects it.
# - Next to the binary is where 1.7.0 put it; Bundle.module still fatals.
# Logo and starter profiles go in Contents/Resources; the app never calls
# Bundle.module.

# Copy logo into Contents/Resources for Bundle.main lookups.
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
	<string>1.7.5</string>
	<key>CFBundleVersion</key>
	<string>45</string>
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
