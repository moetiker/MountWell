#!/bin/bash
# Runs all tests: app logic (Swift) and the mount script (Bash).
set -eu
cd "$(dirname "$0")/.."
export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
swiftc -sdk "$SDKROOT" -swift-version 5 app/Core.swift tests/main.swift -o "$OUT/core-tests"
"$OUT/core-tests"
tests/test-mountwell.sh
