#!/bin/bash
# Builds "Mountwell.app" (Universal) and from it build/Mountwell-<version>.pkg
set -eu
cd "$(dirname "$0")"
# the release sets VERSION; otherwise the file VERSION, which Create release PR updates
VERSION="${VERSION:-$(cat VERSION)}"
# GitHub repository whose releases the app offers as updates
REPO="${REPO:-moetiker/mountwell}"
APP="Mountwell"
ID=ch.oetiker.mountwell
B=build
# explicit SDK, so stale headers in /usr/local/include do not interfere
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"

# no package without green tests
tests/run.sh

rm -rf "$B"
mkdir -p "$B/root/Applications" "$B/root/Library/LaunchAgents"
BUNDLE="$B/root/Applications/$APP.app"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

for arch in arm64 x86_64; do
    swiftc -sdk "$SDKROOT" -O -parse-as-library -swift-version 5 -target "$arch-apple-macos14.0" \
        app/Core.swift app/Mountwell.swift -o "$B/app-$arch"
done
lipo -create -output "$BUNDLE/Contents/MacOS/$APP" "$B/app-arm64" "$B/app-x86_64"

sed -e "s/@VERSION@/$VERSION/g" -e "s|@REPO@|$REPO|g" app/Info.plist > "$BUNDLE/Contents/Info.plist"
install -m 755 mountwell.sh "$BUNDLE/Contents/Resources/mountwell"
install -m 755 uninstall.sh "$BUNDLE/Contents/Resources/uninstall.sh"
install -m 644 LICENSE "$BUNDLE/Contents/Resources/LICENSE"
# languages: macOS shows the UI in the system language if the app has it
cp -R app/*.lproj "$BUNDLE/Contents/Resources/"
swift app/make-icon.swift "$B/AppIcon.iconset"
iconutil -c icns "$B/AppIcon.iconset" -o "$BUNDLE/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$BUNDLE"

install -m 644 "pkg/$ID.plist" "$B/root/Library/LaunchAgents/"

# extended attributes would end up as ._ files in the package
xattr -cr "$B/root"
export COPYFILE_DISABLE=1

# do not "relocate" the app if a copy already exists elsewhere
pkgbuild --analyze --root "$B/root" "$B/component.plist"
plutil -replace 0.BundleIsRelocatable -bool NO "$B/component.plist"

pkgbuild --root "$B/root" --component-plist "$B/component.plist" --scripts pkg/scripts \
    --identifier "$ID" --version "$VERSION" --install-location / "$B/component.pkg"
productbuild --package "$B/component.pkg" "$B/Mountwell-$VERSION.pkg"
echo "done: $B/Mountwell-$VERSION.pkg"
