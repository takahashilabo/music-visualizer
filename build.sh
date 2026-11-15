#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# Metal shader compilation needs the full Xcode toolchain (Command Line
# Tools alone don't ship `metal`). Scope this to the build only — don't
# change the system-wide `xcode-select` default.
if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

APP_NAME="MusicVisualizer"
BUNDLE_ID="com.localhost.music-visualizer-cc-agent"
CONFIG="release"
BUILD_DIR=".build/$CONFIG"
APP_BUNDLE="$APP_NAME.app"

echo "Building $APP_NAME ($CONFIG)..."
swift build -c "$CONFIG"

echo "Assembling $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy any SPM resource bundle (e.g. compiled Metal shaders) if present.
shopt -s nullglob
for bundle in "$BUILD_DIR"/*.bundle; do
  cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"
done
shopt -u nullglob

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.4</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "Code signing (ad-hoc)..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "Built $APP_BUNDLE"

if [ "${1:-}" == "run" ]; then
  echo "Relaunching..."
  # Kill ANY running copy of this app, wherever it lives (e.g. a
  # /Applications install from a .dmg) — Launch Services resolving a
  # relative `open` by bundle identifier can otherwise reopen a *different*
  # on-disk copy than the one just built here, silently testing stale code.
  pkill -f "/$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
  # Give Core Audio time to fully tear down the previous process's system
  # audio tap / aggregate device before the new process creates its own.
  # Launching immediately after pkill can win a race where the new tap is
  # created while the old one is still unwinding, silently delivering no
  # real audio (no error — just a visual that never reacts to sound).
  for _ in $(seq 1 20); do
    pgrep -f "/$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null 2>&1 || break
    sleep 0.1
  done
  sleep 1
  # Absolute path: unambiguously launches *this* bundle, not whatever copy
  # Launch Services might otherwise resolve the bundle identifier to.
  open "$(pwd)/$APP_BUNDLE"
fi
