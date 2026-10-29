#!/bin/bash
# mountwell: mounts SMB shares only while their server is reachable
# (right network or VPN up) and unmounts them again when it is not.
#
# Configuration: ~/.config/mountwell/shares.conf
#   [!]smb://user@server/share  [IP prefixes, comma-separated]  [# alias]
# The alias after "#" is a display name for the app; this script ignores it.
# A share starting with "!" is disabled: it is neither mounted nor unmounted.
# The optional second field also restricts mounting to networks,
# e.g. "10.46.,192.168.1." (one of our own IPs must start with one of them).
# If ~/.config/mountwell/disabled exists, nothing happens.
# Shares listed in ~/.config/mountwell/ejected (one server/share per line, written
# by the app's eject button) are not mounted again until the entry is removed:
# by mounting them again, or when the server is out of reach.

set -u
CONFDIR="$HOME/.config/mountwell"
CONF="${MOUNTWELL_CONF:-$CONFDIR/shares.conf}"
LOG="${MOUNTWELL_LOG:-$HOME/Library/Logs/mountwell.log}"
PORT=445
TIMEOUT=2
# before a mounted share counts as gone: this many attempts, this many seconds apart
TRIES=3
RETRY_DELAY="${MOUNTWELL_RETRY_DELAY:-5}"
EJECTED="$CONFDIR/ejected"

log() {
    local line
    line="$(date '+%F %T') $*"
    echo "$line" >> "$LOG"
    [ -t 1 ] && echo "$line"
    return 0
}

# take over configuration and log from the predecessor "SMB Automount"
if [ -d "$HOME/.config/smb-automount" ] && [ ! -e "$CONFDIR" ]; then
    mv "$HOME/.config/smb-automount" "$CONFDIR"
fi
if [ -e "$HOME/Library/Logs/smb-automount.log" ] && [ ! -e "$HOME/Library/Logs/mountwell.log" ]; then
    mv "$HOME/Library/Logs/smb-automount.log" "$HOME/Library/Logs/mountwell.log"
fi

[ -e "$CONFDIR/disabled" ] && exit 0
[ -r "$CONF" ] || exit 0
mkdir -p "$(dirname "$LOG")"

# give the network a moment to settle after a change
[ "${1:-}" = "--now" ] || sleep 3

my_ips=$(ifconfig | awk '/inet /{print $2}' | grep -v '^127\.')

in_allowed_net() {
    local prefixes="$1" p ip
    [ -z "$prefixes" ] && return 0
    IFS=',' read -ra list <<< "$prefixes"
    for p in "${list[@]}"; do
        p="${p// /}"
        for ip in $my_ips; do
            [[ "$ip" == "$p"* ]] && return 0
        done
    done
    return 1
}

# reachable <attempts>: does $host answer on the SMB port?
reachable() {
    local i
    for ((i = 1; i <= $1; i++)); do
        nc -z -G "$TIMEOUT" "$host" "$PORT" >/dev/null 2>&1 && return 0
        [ "$i" -lt "$1" ] && sleep "$RETRY_DELAY"
    done
    return 1
}

# ejected by hand in the app?
is_ejected() {
    [ -f "$EJECTED" ] && grep -qixF "$1" "$EJECTED"
}

# forget a manual eject: the share gets mounted automatically again
unmark() {
    [ -f "$EJECTED" ] && grep -qixF "$1" "$EJECTED" || return 0
    grep -vixF "$1" "$EJECTED" > "$EJECTED.tmp"
    mv "$EJECTED.tmp" "$EJECTED"
}

mountpoint_of() {
    # mount prints e.g. "//user@server/share on /Volumes/share (smbfs, ...)"
    # the name must follow "@" or "//", so "example.com/x" does not match "fileserver.example.com/x"
    mount -t smbfs | grep -iF -e "@$1 on " -e "//$1 on " | sed -E 's/^.* on (.*) \(smbfs.*$/\1/' | head -1
}

while read -r url nets; do
    [[ -z "$url" || "$url" == \#* || "$url" == \!* ]] && continue
    nets="${nets%%#*}"           # "# alias" is for the app only
    nets="${nets//[[:space:]]/}"
    rest="${url#smb://}"
    rest="${rest#*@}"            # strip user@
    host="${rest%%/*}"
    share="${rest#*/}"
    key="$host/$share"
    mp=$(mountpoint_of "$key")
    # mounted again (by hand or via the app): no longer ejected
    [ -n "$mp" ] && unmark "$key"

    if in_allowed_net "${nets:-}"; then
        if [ -z "$mp" ]; then
            if ! reachable 1; then
                unmark "$key"    # server out of reach: mount again next time
            elif ! is_ejected "$key"; then
                log "mounting $url"
                osascript -e "mount volume \"$url\"" >/dev/null 2>&1 \
                    || log "mount failed: $url"
            fi
        elif ! reachable "$TRIES"; then
            # server unreachable several times: a normal unmount would hang
            log "$host unreachable, unmounting $mp"
            diskutil unmount force "$mp" >/dev/null 2>&1 || umount -f "$mp"
        fi
    elif [ -n "$mp" ]; then
        if reachable 1; then
            # server still there: do not force, open files block the unmount
            log "wrong network, unmounting $mp"
            diskutil unmount "$mp" >/dev/null 2>&1 \
                || log "unmount failed (files open?): $mp"
        else
            log "wrong network and $host unreachable, unmounting $mp"
            diskutil unmount force "$mp" >/dev/null 2>&1 || umount -f "$mp"
        fi
    else
        unmark "$key"    # left the network: mount again next time
    fi
done < "$CONF"
