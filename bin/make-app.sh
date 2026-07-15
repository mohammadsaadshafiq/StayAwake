#!/bin/bash
# Builds Wigbat.app — a proper .app bundle wrapping the compiled binary, so the
# bat is launchable from Spotlight, Finder, and the Dock. It stays an accessory
# app (LSUIElement), so while running it still shows ONLY as the menu-bar icon
# and floating bat — no Dock clutter. Assets/state are still read from
# ~/claude-awake-buddy, so the bundle only carries the binary + icon.
#
# Usage: bin/make-app.sh [DEST_DIR]
#   DEST_DIR defaults to /Applications, falling back to ~/Applications if that
#   isn't writable. Prints the final path of the installed bundle on the last line.
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Wigbat"
BUNDLE_ID="com.wigbat.buddy"

# --- pick a destination -----------------------------------------------------
DEST="${1:-/Applications}"
if [ ! -w "$DEST" ]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
fi
APP="$DEST/$APP_NAME.app"

# --- compile the binary -----------------------------------------------------
if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install Xcode Command Line Tools first: xcode-select --install" >&2
  exit 1
fi
echo "==> Compiling binary" >&2
(cd "$DIR/swift" && swiftc -O BuddyApp.swift -o buddy)

# --- generate an .icns from the awake artwork -------------------------------
echo "==> Generating app icon" >&2
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
SRC_ICON="$DIR/wigbat-awake-final.png"
for size in 16 32 64 128 256 512; do
  sips -z "$size" "$size"       "$SRC_ICON" --out "$ICONSET/icon_${size}x${size}.png"      >/dev/null
  sips -z "$((size*2))" "$((size*2))" "$SRC_ICON" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
ICNS="$(mktemp -d)/AppIcon.icns"
iconutil -c icns "$ICONSET" -o "$ICNS"

# --- assemble the bundle ----------------------------------------------------
echo "==> Assembling $APP" >&2
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$DIR/swift/buddy" "$APP/Contents/MacOS/buddy"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>     <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>      <string>buddy</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>11.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>LSUIElement</key>             <true/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>    <string>$BUNDLE_ID</string>
            <key>CFBundleURLSchemes</key> <array><string>wigbat</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST_EOF

# Refresh LaunchServices/Finder/Spotlight so the icon and Spotlight entry appear.
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$APP" 2>/dev/null || true

echo "$APP"
