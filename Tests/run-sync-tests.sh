#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/kea-sync-tests.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT HUP INT TERM

swiftc -swift-version 5 \
    "$repo_dir/Sources/Kea/SyncCore.swift" \
    "$repo_dir/Sources/Kea/LocalNetwork.swift" \
    "$repo_dir/Tests/SyncCoreTests.swift" \
    -o "$build_dir/sync-tests"
"$build_dir/sync-tests"
