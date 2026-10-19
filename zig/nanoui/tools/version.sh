#!/bin/sh
# Sets or checks the version nanoui is released with. It is kept in one
# place, build.zig.zon, which the build passes to the code as
# nanoui.version (as mygo's scripts/version.ts keeps mygo.Version):
#
#   sh tools/version.sh 0.2.1             # set it
#   sh tools/version.sh --check v0.2.1    # check it matches a tag
#   sh tools/version.sh                   # print it
set -eu
cd "$(dirname "$0")/.."

current="$(sed -n 's/^    \.version = "\([^"]*\)",$/\1/p' build.zig.zon)"
[ -n "$current" ] || { echo "build.zig.zon has no version" >&2; exit 1; }

case "${1:-}" in
"")
  echo "$current"
  ;;
--check)
  want="${2:?usage: version.sh --check <tag>}"
  want="${want#v}"
  if [ "$current" != "$want" ]; then
    echo "build.zig.zon has $current, not $want" >&2
    exit 1
  fi
  echo "nanoui is at $want"
  ;;
*)
  v="$1"
  echo "$v" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$' || {
    echo "usage: version.sh <major.minor.patch[-pre]> | --check <tag>" >&2
    exit 2
  }
  sed -i.bak "s/^    \.version = \"$current\",\$/    .version = \"$v\",/" build.zig.zon
  rm build.zig.zon.bak
  echo "set the version to $v: commit, then push the tag v$v to release"
  ;;
esac
