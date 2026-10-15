#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/kea-carry-tests.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT HUP INT TERM

swiftc -swift-version 5 \
    "$repo_dir/Sources/Kea/Carry.swift" \
    "$repo_dir/Tests/CarryTests.swift" \
    -o "$build_dir/carry-tests"
"$build_dir/carry-tests"
