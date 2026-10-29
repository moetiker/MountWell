#!/bin/bash
# install-update <package> <team ID>: run as root by the app (do shell script … with
# administrator privileges) to install an update package signed by that Apple team.
#
# The package is first copied into a directory only root can write, and checked and
# installed from there. Checked in the user's cache and opened in Installer, it could be
# swapped between the check and the moment Installer read it, and the user would then
# type the administrator password for someone else's package.
#
# Exit status: 0 installed, 3 bad arguments, 4 not signed by the team, 5 install failed.
set -u

PKGUTIL=/usr/sbin/pkgutil
INSTALLER=/usr/sbin/installer
TMPBASE=/private/var/tmp
# the tests run as a normal user with stubs; as root the fixed paths always apply
if [ "$(id -u)" != 0 ]; then
    PKGUTIL="${MOUNTWELL_PKGUTIL:-$PKGUTIL}"
    INSTALLER="${MOUNTWELL_INSTALLER:-$INSTALLER}"
    TMPBASE="${MOUNTWELL_TMPBASE:-$TMPBASE}"
fi

[ $# = 2 ] && [ -f "$1" ] && [[ "$2" =~ ^[A-Z0-9]{10}$ ]] || exit 3
team="$2"

dir=$(mktemp -d "$TMPBASE/mountwell-update.XXXXXX") || exit 5
trap 'rm -rf "$dir"' EXIT
chmod 700 "$dir"
cp "$1" "$dir/update.pkg" || exit 5

# the same rules as installerTeamID in app/Core.swift: a Developer ID Installer
# certificate of this team, issued by Apple's Developer ID CA, trusted by pkgutil
out=$("$PKGUTIL" --check-signature "$dir/update.pkg" 2>&1) || exit 4
lines=$(printf '%s\n' "$out" | sed 's/^[[:space:]]*//')
leaf=$(grep -m 1 '^1\. ' <<< "$lines")
grep -qxF "Status: signed by a developer certificate issued by Apple for distribution" <<< "$lines" \
    && [[ "$leaf" == "1. Developer ID Installer: "*" ($team)" ]] \
    && grep -qxF "2. Developer ID Certification Authority" <<< "$lines" \
    && grep -qxF "3. Apple Root CA" <<< "$lines" \
    || exit 4

"$INSTALLER" -pkg "$dir/update.pkg" -target / >/dev/null 2>&1 || exit 5
exit 0
