#!/bin/bash
# Builds Kea and puts it in /Applications. Kea is a browser you build
# yourself: there is no download and nothing checks for updates — pull and
# run this again.
#
#   ./build.sh                 release build, installed as /Applications/Kea.app; build/ is removed
#   ./build.sh debug           the same, a debug build
#   ./build.sh release test    stops at build/Kea.app and touches nothing else (Tests/ and fresh.sh)
#   KEA_INSTALL=0 ./build.sh   the same as `test`
#   KEA_ARCH=x86_64            for an Intel Mac (default: this Mac's chip)
#   KEA_SIGN_IDENTITY="…"      a Developer ID to sign with (default: the first in the keychain, else ad-hoc)
#
# SwiftPM builds the executable; a Mac app is a folder with a plist and the
# binary in the right place, so the rest is done here.
set -euo pipefail

cd "$(dirname "$0")"
if [ -z "${SDKROOT:-}" ] && [ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" ]; then
  export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
fi
CONFIG="${1:-release}"
STEP="${2:-app}"
case "$STEP" in app|test) ;; *) echo "usage: ./build.sh [release|debug] [app|test]" >&2; exit 1 ;; esac
ARCH="${KEA_ARCH:-$(uname -m)}"
case "$ARCH" in arm64|x86_64) ;; *) echo "KEA_ARCH is arm64 or x86_64, not “$ARCH”" >&2; exit 1 ;; esac
NAME="Kea"
APP="build/$NAME.app"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD="$(date +%Y%m%d%H%M)"
MINIMUM="14.0"
INSTALL=1
{ [ "$STEP" = "test" ] || [ "${KEA_INSTALL:-1}" = "0" ]; } && INSTALL=0

# Replacing the app under a running Kea pulls it out from under itself.
if [ "$INSTALL" = 1 ] && pgrep -f "/Applications/$NAME.app/Contents/MacOS/$NAME" >/dev/null; then
  echo "Kea is running from /Applications — quit it, then run ./build.sh again" >&2
  exit 1
fi

# -Osize for a release: 14% less binary at the same speed (measured Sep 2026).
SWIFTFLAGS=(-c "$CONFIG" --arch "$ARCH")
[ "$CONFIG" = "release" ] && SWIFTFLAGS+=(-Xswiftc -Osize)
swift build "${SWIFTFLAGS[@]}"
BINARY="$(swift build "${SWIFTFLAGS[@]}" --show-bin-path)/$NAME"
[ "$(lipo -archs "$BINARY")" = "$ARCH" ] || { echo "$BINARY is not a $ARCH binary" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$NAME"
# The AppleScript dictionary (Scripting.swift); the plist points to it.
cp Kea.sdef "$APP/Contents/Resources/"
# The flying kea, for the welcome and Settings › About (KeaArt.swift).
cp Icon/kea.gif "$APP/Contents/Resources/"
# Symbols stay out of the app: more than half of what it would weigh, and
# nothing it reads while it runs.
[ "$CONFIG" = "release" ] && strip -x "$APP/Contents/MacOS/$NAME"

# The icon, drawn from Icon/kea.png each time.
ICONSET="build/AppIcon.iconset"
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
  <key>CFBundleIdentifier</key><string>app.kea.browser</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>$MINIMUM</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHumanReadableCopyright</key><string>Kea · MIT License</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleScriptEnabled</key><true/>
  <key>NSUserActivityTypes</key><array><string>NSUserActivityTypeBrowsingWeb</string></array>
  <key>OSAScriptingDefinition</key><string>Kea.sdef</string>
  <!-- Owning http and https is what sends a link clicked in Mail here.
       Appearing in Desktop & Dock → Default web browser also needs the
       XHTML document type below. -->
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
    <!-- macOS only lists an app under Desktop & Dock → Default web browser
         when it claims public.xhtml as well as public.html. http and https
         alone, which Kea already had, are not enough. -->
    <dict>
      <key>CFBundleTypeName</key><string>XHTML page</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key>
      <array><string>public.xhtml</string></array>
    </dict>
  </array>
  <!-- A browser goes wherever it is pointed, including at http sites and at
       whatever is running on localhost. -->
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
  <!-- A browser is asked for these by the pages it shows, not by itself. macOS
       still wants a sentence to put in its own prompt, and touching the APIs
       without one is a crash rather than a refusal. -->
  <key>NSCameraUsageDescription</key>
  <string>Websites you visit can ask to use your camera. Kea asks you the first time each site does and keeps your answer; Settings › Privacy forgets them.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Websites you visit can ask to use your microphone. Kea asks you the first time each site does and keeps your answer; Settings › Privacy forgets them.</string>
  <key>NSLocationUsageDescription</key>
  <string>Websites you visit can ask for your location. Kea asks you each time a site does, unless you choose Always allow for it; Settings › Privacy forgets those choices.</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>Files you download are saved to your Downloads folder.</string>
</dict>
</plist>
PLIST

# Signing: a Developer ID if this Mac has one, with the hardened runtime;
# otherwise ad-hoc, which runs on the Mac that built it.
IDENTITY="${KEA_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)}"
if [ -n "$IDENTITY" ]; then
  codesign --force --deep --timestamp --options runtime --entitlements Kea.entitlements --sign "$IDENTITY" "$APP"
  echo "signed as: $IDENTITY"
else
  # set -e: a bundle that couldn't be signed is not a build.
  codesign --force --deep --sign - "$APP"
fi

echo "built: $APP ($VERSION, $ARCH, build $BUILD)"
[ "$INSTALL" = 0 ] && exit 0
rm -rf "/Applications/$NAME.app"
cp -R "$APP" "/Applications/$NAME.app"
codesign --verify --deep --strict "/Applications/$NAME.app"
rm -rf build
echo "installed: /Applications/$NAME.app"
