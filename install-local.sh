#!/bin/bash
# Builds Search with the Command Line Tools only (no Xcode) and installs it
# as ~/Applications/Search Local.app, beside any Search.app already installed.
#
# Same bundle id as the real app on purpose: it shares that app's settings
# and WebKit store. So quit Search before opening this one — two copies
# writing ~/Library/Application Support/Search at once will overwrite each other.
set -euo pipefail
cd "$(dirname "$0")"
# The 27 SDK makes @State a macro whose plugin only Xcode ships; 26.5 doesn't.
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
./build.sh release
DEST="$HOME/Applications/Search Local.app"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R build/Search.app "$DEST"
codesign --verify --deep --strict "$DEST"
echo "installed: $DEST"
