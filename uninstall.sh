#!/bin/bash
# Removes Mountwell (app and background service).
# Usage: sudo "/Applications/Mountwell.app/Contents/Resources/uninstall.sh"
# The configuration in ~/.config/mountwell is kept.
main() {
    LABEL=ch.oetiker.mountwell
    if [ "$(id -u)" -ne 0 ]; then
        echo "please run with sudo" >&2
        exit 1
    fi
    for uid in $(ps -axo uid=,comm= | awk '/loginwindow$/{print $1}' | sort -u); do
        launchctl bootout "gui/$uid/$LABEL" 2>/dev/null
    done
    rm -f "/Library/LaunchAgents/$LABEL.plist"
    rm -rf "/Applications/Mountwell.app"
    pkgutil --forget "$LABEL" >/dev/null 2>&1
    echo "Mountwell uninstalled (configuration kept)"
}
main "$@"
exit
