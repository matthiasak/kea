#!/bin/sh
# nui for each platform, for a release: zig-out/nui-package/nui-<os>-<arch>
# archives (.tar.gz; .zip on Windows) and SHA256SUMS. On macOS the binary is
# signed with $CODESIGN_IDENTITY and notarized when NOTARY_KEY_PATH,
# NOTARY_KEY_ID and NOTARY_ISSUER_ID are set, so a downloaded one runs.
#
#     sh tools/package-nui.sh
set -eu
cd "$(dirname "$0")/.."
out=zig-out/nui-package
rm -rf "$out"
mkdir -p "$out"
for t in aarch64-macos.13.0 x86_64-macos.13.0 x86_64-linux-gnu aarch64-linux-gnu x86_64-windows-gnu aarch64-windows-gnu; do
  arch=${t%%-*}
  rest=${t#*-}
  os=${rest%%[.-]*}
  name="nui-$os-$arch"
  prefix="zig-out/nui-build/$name"
  zig build nui -Doptimize=ReleaseSafe -Dtarget="$t" --prefix "$prefix"
  dir="$out/$name"
  mkdir -p "$dir"
  if [ "$os" = windows ]; then
    cp "$prefix/bin/nui.exe" "$dir/"
  else
    cp "$prefix/bin/nui" "$dir/"
  fi
  cp LICENSE "$dir/"
  if [ "$os" = macos ] && [ -n "${CODESIGN_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$dir/nui"
    if [ -n "${NOTARY_KEY_PATH:-}" ]; then
      ditto -c -k --keepParent "$dir/nui" "$out/$name-notarize.zip"
      xcrun notarytool submit "$out/$name-notarize.zip" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait
      rm "$out/$name-notarize.zip"
    fi
  fi
  if [ "$os" = windows ]; then
    (cd "$out" && zip -qr "$name.zip" "$name")
  else
    tar -C "$out" -czf "$out/$name.tar.gz" "$name"
  fi
  rm -rf "$dir"
done
(cd "$out" && shasum -a 256 nui-* > SHA256SUMS)
ls "$out"
