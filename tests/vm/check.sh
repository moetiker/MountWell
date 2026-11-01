#!/bin/bash
# Runs inside the test VM as admin, copied there by tools/test-vm run:
#
#   check.sh cask              install the released cask the way the README says
#   check.sh local <pkg>       install a local build (./build.sh)
#
# Prints "ok:" and "FAIL:" lines and exits with the number of failures.
set -uo pipefail

APP=/Applications/MountWell.app
LABEL=ch.oetiker.mountwell
PLIST=/Library/LaunchAgents/$LABEL.plist
AGENT=$APP/Contents/MacOS/mountwell-agent
CONF=~/"Library/Application Support/MountWell"
LOG=~/Library/Logs/mountwell.log
failures=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; failures=$((failures + 1)); }
team() { codesign -dv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p'; }
loaded() { launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; }
app_runs() { pgrep -qf "^$APP/Contents/MacOS/MountWell"; }

eval "$(/opt/homebrew/bin/brew shellenv)"

echo "== install ($1)"
case $1 in
cask)
    brew tap moetiker/mountwell https://github.com/moetiker/MountWell
    brew trust moetiker/mountwell
    out=$(brew install --cask mountwell 2>&1)
    echo "$out"
    if grep -qi warning <<<"$out"; then bad "brew install printed a warning"; else ok "brew install without warnings"; fi
    if spctl -a -t exec -vv "$APP" 2>&1 | grep -q "source=Notarized Developer ID"; then
        ok "Gatekeeper accepts the app as notarized"
    else
        bad "Gatekeeper does not accept the app: $(spctl -a -t exec -vv "$APP" 2>&1 | tr '\n' ' ')"
    fi
    ;;
local)
    sudo installer -pkg "$2" -target / || bad "installer failed"
    ;;
esac
[ -d "$APP" ] && ok "MountWell.app is in /Applications" || { bad "no $APP"; exit "$failures"; }
version=$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)
receipt=$(pkgutil --pkg-info "$LABEL" 2>/dev/null | sed -n 's/^version: //p')
[ "$receipt" = "$version" ] && ok "package receipt $LABEL $receipt" \
    || bad "package receipt says '$receipt', the app $version"

echo "== background service"
[ -f "$PLIST" ] && ok "$PLIST is installed" || bad "no $PLIST"
[ "$(stat -f %Su:%Sg "$PLIST" 2>/dev/null)" = root:wheel ] && ok "$PLIST belongs to root:wheel" \
    || bad "$PLIST belongs to $(stat -f %Su:%Sg "$PLIST" 2>/dev/null)"
loaded && ok "the installer loaded $LABEL for the logged-in user" || bad "$LABEL is not loaded"
program=$(launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | sed -n 's/^[[:space:]]*program = //p')
[ "$program" = "$AGENT" ] && ok "launchd starts mountwell-agent" || bad "launchd starts '$program'"
app_team=$(team "$APP")
if [ -n "$app_team" ] && [ "$app_team" != "not set" ] && [ "$(team "$AGENT")" = "$app_team" ]; then
    ok "app and agent are signed by team $app_team"
else
    bad "app team '$app_team', agent team '$(team "$AGENT")'"
fi
# Login Items shows a service from an unknown developer unless its program is signed
# by the team of the app named in AssociatedBundleIdentifiers.
# dumpbtm lists one block per item, each starting with "#<n>:"
btm=$(sudo sfltool dumpbtm 2>/dev/null | awk -v url="URL: $PLIST" '
    /^ *#[0-9]+:/ { if (found) exit; block = "" }
    { block = block $0 "\n" }
    index($0, url) { found = 1 }
    END { if (found) printf "%s", block }')
developer=$(sed -n 's/^ *Developer Name: //p' <<<"$btm")
btm_team=$(sed -n 's/^ *Team Identifier: //p' <<<"$btm")
if [ -n "$developer" ] && [ "$developer" != "(null)" ] && [ "$btm_team" = "$app_team" ]; then
    ok "Login Items shows the service as from $developer ($btm_team)"
else
    bad "Login Items shows the service with developer '$developer', team '$btm_team'"
fi

echo "== first start"
# without shares.conf the installer opens the window for the first share
for _ in $(seq 20); do app_runs && break; sleep 1; done
app_runs && ok "the installer opened MountWell" || bad "MountWell does not run after the install"

# the script runs and finishes cleanly with one switched-off share
mkdir -p "$CONF"
echo '!smb://fileserver.example.com/team' > "$CONF/shares.conf"
launchctl kickstart -k "gui/$(id -u)/$LABEL"
for _ in $(seq 20); do
    launchctl print "gui/$(id -u)/$LABEL" | grep -q 'state = running' || break
    sleep 1
done
code=$(launchctl print "gui/$(id -u)/$LABEL" | sed -n 's/^[[:space:]]*last exit code = //p')
[ "$code" = 0 ] && ok "a run of the service exits with 0" || bad "a run of the service exits with '$code'"

echo "== uninstall"
# for the zap and for the promise that the plain uninstall keeps the settings
echo "test" >> "$LOG"
case $1 in
cask)
    if brew uninstall --zap --cask mountwell; then
        [ -e "$CONF" ] && bad "brew uninstall --zap left $CONF" || ok "brew uninstall --zap removes the settings"
        [ -e "$LOG" ] && bad "brew uninstall --zap left $LOG" || ok "brew uninstall --zap removes the log"
    else
        bad "brew uninstall --zap failed"
    fi
    ;;
local)
    if sudo "$APP/Contents/Resources/uninstall.sh"; then
        [ -f "$CONF/shares.conf" ] && ok "uninstall.sh keeps the settings" || bad "uninstall.sh removed $CONF/shares.conf"
    else
        bad "uninstall.sh failed"
    fi
    ;;
esac
[ -d "$APP" ] && bad "uninstall left $APP" || ok "uninstall removes the app"
[ -f "$PLIST" ] && bad "uninstall left $PLIST" || ok "uninstall removes $PLIST"
loaded && bad "$LABEL is still loaded after uninstall" || ok "uninstall unloads $LABEL"
pkgutil --pkg-info "$LABEL" >/dev/null 2>&1 && bad "the receipt $LABEL is still there" \
    || ok "uninstall forgets the receipt"
app_runs && bad "MountWell still runs after uninstall" || ok "MountWell no longer runs"

echo "== $failures failure(s)"
exit "$failures"
