#!/bin/bash
# Builds "MountWell.app" (Universal) and from it build/MountWell-<version>.pkg
set -eu
cd "$(dirname "$0")"
# the release sets VERSION; otherwise the file VERSION, which Create release PR updates
VERSION="${VERSION:-$(cat VERSION)}"
# GitHub repository whose releases the app offers as updates
REPO="${REPO:-moetiker/MountWell}"
# Developer ID certificates in the keychain; without them app and package are signed ad hoc
# and stay unsigned. SIGN_APP and SIGN_PKG override the lookup.
SIGN_APP="${SIGN_APP-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' | head -1)}"
SIGN_PKG="${SIGN_PKG-$(security find-identity -v -p basic | sed -n 's/.*"\(Developer ID Installer: .*\)"$/\1/p' | head -1)}"
# Apple team ID; when set, the app installs only updates signed by that team's Developer ID.
# Taken from the installer certificate "Developer ID Installer: Name (TEAMID)".
TEAM_ID="${TEAM_ID-$(printf '%s' "$SIGN_PKG" | sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p')}"
# notarization: a profile saved with "xcrun notarytool store-credentials". The release
# build sets NOTARIZE=0: ri-release-macos-signed notarizes and staples the package itself.
NOTARY_PROFILE="${NOTARY_PROFILE:-mountwell}"
NOTARIZE="${NOTARIZE:-1}"
# a release must not ship unsigned: with REQUIRE_SIGNING=1 a missing piece is an error
REQUIRE_SIGNING="${REQUIRE_SIGNING:-0}"

# An invalid team ID reaches the app as "no team ID", and the app then installs any update
# unchecked (U-4). Refuse it instead.
if [ -n "$TEAM_ID" ] && ! [[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
    echo "TEAM_ID must be 10 upper-case letters and digits, not \"$TEAM_ID\"" >&2
    exit 1
fi
if [ "$REQUIRE_SIGNING" = 1 ] && { [ -z "$SIGN_APP" ] || [ -z "$SIGN_PKG" ] || [ -z "$TEAM_ID" ]; }; then
    echo "REQUIRE_SIGNING=1, but Developer ID Application, Developer ID Installer or the team ID is missing" >&2
    exit 1
fi
APP="MountWell"
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

# the app: every Swift file in app/ except the icon generator (a script) and smb-id (its own
# program in app/smb-id/)
APP_SOURCES=$(ls app/*.swift | grep -v '/make-icon\.swift$')
for arch in arm64 x86_64; do
    # shellcheck disable=SC2086
    swiftc -sdk "$SDKROOT" -O -parse-as-library -swift-version 5 -target "$arch-apple-macos14.0" \
        $APP_SOURCES -o "$B/app-$arch"
    swiftc -sdk "$SDKROOT" -O -swift-version 5 -target "$arch-apple-macos14.0" \
        app/Core.swift app/smb-id/main.swift -o "$B/smb-id-$arch"
done
lipo -create -output "$BUNDLE/Contents/MacOS/$APP" "$B/app-arm64" "$B/app-x86_64"
# server ID for mountwell.sh (M-13); in MacOS/ so codesign treats it as nested code
lipo -create -output "$BUNDLE/Contents/MacOS/smb-id" "$B/smb-id-arm64" "$B/smb-id-x86_64"

sed -e "s/@VERSION@/$VERSION/g" -e "s|@REPO@|$REPO|g" -e "s|@TEAM_ID@|$TEAM_ID|g" app/Info.plist > "$BUNDLE/Contents/Info.plist"
install -m 755 mountwell.sh "$BUNDLE/Contents/Resources/mountwell"
install -m 755 uninstall.sh "$BUNDLE/Contents/Resources/uninstall.sh"
install -m 755 app/install-update.sh "$BUNDLE/Contents/Resources/install-update"
install -m 644 LICENSE "$BUNDLE/Contents/Resources/LICENSE"
# languages: macOS shows the UI in the system language if the app has it
cp -R app/*.lproj "$BUNDLE/Contents/Resources/"
swift app/make-icon.swift "$B/AppIcon.iconset"
iconutil -c icns "$B/AppIcon.iconset" -o "$BUNDLE/Contents/Resources/AppIcon.icns"
if [ -n "$SIGN_APP" ]; then
    # hardened runtime and a secure timestamp are what notarization requires,
    # for the nested helper as well; it is signed first, the bundle seals it
    codesign --force --options runtime --timestamp --sign "$SIGN_APP" "$BUNDLE/Contents/MacOS/smb-id"
    codesign --force --options runtime --timestamp --sign "$SIGN_APP" "$BUNDLE"
    codesign --verify --strict --verbose=2 "$BUNDLE"
else
    codesign --force --deep --sign - "$BUNDLE"
fi

install -m 644 "pkg/$ID.plist" "$B/root/Library/LaunchAgents/"

# extended attributes would end up as ._ files in the package
xattr -cr "$B/root"
export COPYFILE_DISABLE=1

# do not "relocate" the app if a copy already exists elsewhere
pkgbuild --analyze --root "$B/root" "$B/component.plist"
plutil -replace 0.BundleIsRelocatable -bool NO "$B/component.plist"

pkgbuild --root "$B/root" --component-plist "$B/component.plist" --scripts pkg/scripts \
    --identifier "$ID" --version "$VERSION" --install-location / "$B/component.pkg"
PKG="$B/MountWell-$VERSION.pkg"
if [ -n "$SIGN_PKG" ]; then
    productbuild --sign "$SIGN_PKG" --timestamp --package "$B/component.pkg" "$PKG"
else
    productbuild --package "$B/component.pkg" "$PKG"
fi

if [ -n "$SIGN_APP" ] && [ -n "$SIGN_PKG" ] && [ "$NOTARIZE" = 1 ]; then
    if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        notary=(--keychain-profile "$NOTARY_PROFILE")
    else
        notary=()
    fi
    if [ ${#notary[@]} -gt 0 ]; then
        # --wait returns 0 also for "Invalid"; only "Accepted" can be stapled
        out=$(xcrun notarytool submit "$PKG" "${notary[@]}" --wait --output-format plist)
        status=$(printf '%s' "$out" | plutil -extract status raw -)
        if [ "$status" != Accepted ]; then
            id=$(printf '%s' "$out" | plutil -extract id raw -)
            echo "notarization: $status" >&2
            xcrun notarytool log "$id" "${notary[@]}" >&2 || true
            exit 1
        fi
        xcrun stapler staple "$PKG"
    elif [ "$REQUIRE_SIGNING" = 1 ]; then
        echo "REQUIRE_SIGNING=1, but no notarization credentials" >&2
        exit 1
    else
        echo "not notarized: no profile \"$NOTARY_PROFILE\" (xcrun notarytool store-credentials)" >&2
    fi
fi
pkgutil --check-signature "$PKG" | sed -n 's/^ *Status: /signature: /p'
echo "done: $PKG"
