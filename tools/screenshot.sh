#!/bin/bash
# Renders the pictures in docs/ (see tools/screenshot/main.swift), light mode.
set -eu
cd "$(dirname "$0")/.."
export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
# SCREENSHOT leaves out the app's @main, so tools/screenshot/main.swift is the entry point
swiftc -sdk "$SDKROOT" -swift-version 5 -D SCREENSHOT -target "$(uname -m)-apple-macos14.0" \
    $(ls app/*.swift | grep -v '/make-icon\.swift$') tools/screenshot/main.swift -o "$OUT/screenshot"
mkdir -p docs
"$OUT/screenshot" docs -AppleLanguages '(en)'
