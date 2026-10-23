#!/bin/sh
# How long nanoui takes to build, and how much disk it uses, beside mygo:
# a counter app each (mygo's examples/counter-native; nanoui's from
# `nui start`), from empty build caches. Network fetches aren't timed.
#
#     sh tools/buildperf.sh            # needs Go (any; mygo's toolchain is fetched) and git
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
B="${TMPDIR:-/tmp}/nanoui-buildperf"
rm -rf "$B" && mkdir -p "$B"
t() { /usr/bin/time -p "$@" 2>&1 >/dev/null | awk '/^real/ {print $2}'; }
mb() { du -sm "$@" 2>/dev/null | awk '{s+=$1} END {print s}'; }
edit() { if sed --version >/dev/null 2>&1; then sed -i "$@"; else sed -i '' "$@"; fi; }

echo "== mygo examples/counter-native"
git clone -q --depth 1 https://github.com/egoist/mygo "$B/mygo"
cd "$B/mygo"
export GOTOOLCHAIN=auto GOCACHE="$B/gocache"
go mod download
echo "cold:      $(t go build -o "$B/m-counter" ./examples/counter-native) s"
echo "no-op:     $(t go build -o "$B/m-counter" ./examples/counter-native) s"
edit 's/package main/package main \/\/ edited/' examples/counter-native/main.go
echo "one edit:  $(t go build -o "$B/m-counter" ./examples/counter-native) s"
echo "cache:     $(mb "$B/gocache") MB"
echo "program:   $(mb "$B/m-counter") MB"

echo "== nanoui, an app from nui start"
cd "$here" && zig build nui >/dev/null
export ZIG_GLOBAL_CACHE_DIR="$B/zigcache"
cd "$B" && "$here/zig-out/bin/nui" start app --local "$here" --no-build >/dev/null
cd "$B/app"
echo "cold:      $(t zig build) s"
echo "no-op:     $(t zig build) s"
edit 's/count: i64 = 0,/count: i64 = 1,/' src/app.zig
echo "one edit:  $(t zig build) s"
echo "cache:     $(mb "$B/zigcache" .zig-cache) MB"
echo "program:   $(mb zig-out/bin/app) MB (Debug)"
rm -rf .zig-cache zig-out
echo "a second app (Zig's global cache warm), cold: $(t zig build) s"
rm -rf .zig-cache zig-out
echo "ReleaseSmall: $(t zig build -Doptimize=ReleaseSmall) s, $(ls -l zig-out/bin/app | awk '{printf "%.1f", $5/1048576}') MB"
rm -rf .zig-cache zig-out
echo "ReleaseFast:  $(t zig build -Doptimize=ReleaseFast) s, $(ls -l zig-out/bin/app | awk '{printf "%.1f", $5/1048576}') MB"
