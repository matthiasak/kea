#!/bin/bash
# Builds KeaZig.app (the Zig 0.17 + nanoui WebKit browser) alongside Kea.app
# and puts it in /Applications/KeaZig.app.
#
#   ./build-zig.sh                 release build, installed as /Applications/KeaZig.app
#   ./build-zig.sh debug           debug build, installed as /Applications/KeaZig.app
#   ./build-zig.sh release test    stops at build/KeaZig.app and touches nothing else
#   KEA_INSTALL=0 ./build-zig.sh   the same as `test`
set -euo pipefail

cd "$(dirname "$0")"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
if [ -z "${SDKROOT:-}" ] && [ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" ]; then
  export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
fi

CONFIG="${1:-release}"
STEP="${2:-app}"
case "$STEP" in app|test) ;; *) echo "usage: ./build-zig.sh [release|debug] [app|test]" >&2; exit 1 ;; esac
ARCH="${KEA_ARCH:-$(uname -m)}"
case "$ARCH" in arm64|x86_64) ;; *) echo "KEA_ARCH is arm64 or x86_64, not “$ARCH”" >&2; exit 1 ;; esac

NAME="KeaZig"
APP="build/$NAME.app"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD="$(date +%Y%m%d%H%M)"
MINIMUM="14.0"
INSTALL=1
{ [ "$STEP" = "test" ] || [ "${KEA_INSTALL:-1}" = "0" ]; } && INSTALL=0

if [ "$INSTALL" = 1 ] && pgrep -f "/Applications/$NAME.app/Contents/MacOS/$NAME" >/dev/null; then
  echo "$NAME is running from /Applications — quit it, then run ./build-zig.sh again" >&2
  exit 1
fi

ZIG_OPT="-Doptimize=ReleaseFast"
[ "$CONFIG" = "debug" ] && ZIG_OPT="-Doptimize=Debug"

(cd zig && zig build lines && (cd nanoui && zig build lines) && zig build "$ZIG_OPT")
BINARY="zig/zig-out/bin/$NAME"
[ -f "$BINARY" ] || { echo "$BINARY was not produced" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$NAME"
cp Kea.sdef "$APP/Contents/Resources/"
cp Icon/kea.gif "$APP/Contents/Resources/"
[ "$CONFIG" = "release" ] && strip -x "$APP/Contents/MacOS/$NAME"

ICONSET="build/AppIconZig.iconset"
rm -rf "$ICONSET"
swift Icon/icon.swift Icon/kea.png "$ICONSET" > /dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>app.kea.zig</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>$MINIMUM</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHumanReadableCopyright</key><string>KeaZig · MIT License</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleScriptEnabled</key><true/>
  <key>NSUserActivityTypes</key><array><string>NSUserActivityTypeBrowsingWeb</string></array>
  <key>OSAScriptingDefinition</key><string>Kea.sdef</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>Web address</string>
      <key>CFBundleURLSchemes</key>
      <array><string>http</string><string>https</string></array>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Web page</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key>
      <array><string>public.html</string><string>com.apple.web-internet-location</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>XHTML page</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key>
      <array><string>public.xhtml</string></array>
    </dict>
  </array>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
  <key>NSCameraUsageDescription</key>
  <string>Websites you visit can ask to use your camera.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Websites you visit can ask to use your microphone.</string>
  <key>NSLocationUsageDescription</key>
  <string>Websites you visit can ask for your location.</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>Files you download are saved to your Downloads folder.</string>
</dict>
</plist>
PLIST

IDENTITY="${KEA_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)}"
if [ -n "$IDENTITY" ]; then
  codesign --force --deep --timestamp --options runtime --entitlements Kea.entitlements --sign "$IDENTITY" "$APP"
  echo "signed as: $IDENTITY"
else
  codesign --force --deep --sign - "$APP"
fi

echo "built: $APP ($VERSION, $ARCH, build $BUILD)"
[ "$INSTALL" = 0 ] && exit 0
rm -rf "/Applications/$NAME.app"
cp -R "$APP" "/Applications/$NAME.app"
codesign --verify --deep --strict "/Applications/$NAME.app"
echo "installed: /Applications/$NAME.app"
