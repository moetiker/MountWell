#!/bin/bash
# mountwell: mounts SMB shares only while their server is reachable
# (right network or VPN up) and unmounts them again when it is not.
#
# Configuration: ~/.config/mountwell/shares.conf
#   [!]smb://user@server/share  [IP prefixes, comma-separated]  [# alias]
# The alias after "#" is a display name for the app; this script ignores it.
# A share starting with "!" is disabled: it is neither mounted nor unmounted. While it is
# mounted by hand, its server is still remembered (see servers.yaml below).
# The optional second field also restricts mounting to networks,
# e.g. "10.46.,192.168.1." (one of our own IPs must start with one of them).
# If ~/.config/mountwell/disabled exists, nothing happens.
# Shares listed in ~/.config/mountwell/ejected (one server/share per line, written
# by the app's eject button) are not mounted again until the entry is removed:
# by mounting them again, or when the server is out of reach.
# ~/.config/mountwell/servers.yaml remembers each server that answered: its IP, the
# network it was reached through (own /24 prefix and router MAC, "-" over VPN) and its
# SMB server ID. When a name does not resolve, the share is mounted via the remembered IP, but only from
# the same network (prefix and router), only if the keychain holds an SMB password for the
# IP and only if the server there reports the same server ID. A share configured by IP is
# remembered on its first mount; later mounts need the same network and server ID too.

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
SERVERS="$CONFDIR/servers.yaml"
# prints the SMB server ID of a host (app/smb-id); next to the app binary
SMBID="${MOUNTWELL_SMBID:-$(dirname "$0")/../MacOS/smb-id}"

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

# One run at a time: "Check Now" in the app and a run from launchd overlapped and both
# rewrote servers.yaml. shlock removes a lock whose process is gone.
LOCK="$CONFDIR/.run.lock"
locked=""
for ((i = 0; i < ${MOUNTWELL_LOCK_WAIT:-30}; i++)); do
    shlock -f "$LOCK" -p $$ && { locked=1; break; }
    sleep 1
done
if [ -z "$locked" ]; then
    log "skipped: another run is still going"
    exit 0
fi
trap 'rm -f "$LOCK"' EXIT

my_ips=$(ifconfig | awk '/inet /{print $2}' | grep -v '^127\.')

in_allowed_net() {
    local prefixes="$1" p ip any=""
    # bash 3.2 (the one launchd runs) calls an empty "${list[@]}" unbound under set -u
    [ -z "${prefixes//[, ]/}" ] && return 0
    IFS=',' read -ra list <<< "$prefixes"
    for p in "${list[@]}"; do
        p="${p// /}"
        # an empty entry ("10.46.,,192.168.1.") matched every address, also in a hotel
        [ -n "$p" ] || continue
        any=1
        for ip in $my_ips; do
            [[ "$ip" == "$p"* ]] && return 0
        done
    done
    [ -z "$any" ]    # no prefix at all: every network, as the app shows it
}

# reachable <attempts>: does $probe (the name, or the remembered IP) answer on the SMB port?
reachable() {
    local i
    for ((i = 1; i <= $1; i++)); do
        nc -z -G "$TIMEOUT" "$probe" "$PORT" >/dev/null 2>&1 && return 0
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

is_ip() {
    [[ "$1" =~ ^[0-9.]+$ || "$1" == *:* ]]
}

# IPv4 address of a name, empty when it does not resolve
resolve() {
    dscacheutil -q host -a name "$1" </dev/null 2>/dev/null | awk '/^ip_address:/{print $2; exit}'
}

# the network an IP is reached through: "<own /24 prefix> <router MAC or ->", e.g.
# "192.168.1. a4:2b:8c:10:20:30". Two networks with the same private range almost always
# have different routers. Over VPN there is no router to see; the VPN address comes from
# the VPN, so a hotel network still never matches. "?" when the router's MAC cannot be
# read: right after a network change the ARP cache is empty.
network_of() {
    local iface ip gw mac=-
    iface=$(route -n get "$1" </dev/null 2>/dev/null | awk '/interface:/{print $2; exit}')
    [ -n "$iface" ] || return 0
    ip=$(ifconfig "$iface" </dev/null 2>/dev/null | awk '/inet /{print $2}' | grep -v '^127\.' | head -1)
    [ -n "$ip" ] || return 0
    case "$iface" in
        utun*|ppp*|ipsec*) ;;
        *)
            gw=$(ipconfig getoption "$iface" router </dev/null 2>/dev/null)
            mac="?"
            if [ -n "$gw" ]; then
                mac=$(router_mac "$gw")
                if [ -z "$mac" ]; then
                    ping -c 1 -t 1 "$gw" </dev/null >/dev/null 2>&1
                    mac=$(router_mac "$gw")
                fi
                [ -n "$mac" ] || mac="?"
            fi
            ;;
    esac
    echo "${ip%.*}. $mac"
}

router_mac() {
    arp -n "$1" </dev/null 2>/dev/null | awk '{print $4; exit}' | grep -E '^[0-9a-f]{1,2}(:[0-9a-f]{1,2}){5}$'
    return 0
}

server_id() {
    [ -x "$SMBID" ] && "$SMBID" "$1" </dev/null 2>/dev/null
    return 0
}

# servers.yaml as a table, one server per line: "<name> <ip> <network> <router> <id> <seen>".
# Only the shape write_servers produces is read; an entry missing a field is skipped.
servers_table() {
    [ -f "$SERVERS" ] || return 0
    awk '
        function val(l) { sub(/^[^:]*: */, "", l); gsub(/"/, "", l); return l }
        function flush() {
            if (n != "" && ip != "" && net != "" && mac != "" && id != "") print n, ip, net, mac, id, (seen == "" ? "-" : seen)
            n = ip = net = mac = id = seen = ""
        }
        /^  - name: /     { flush(); n = val($0); next }
        /^    ip: /        { ip = val($0) }
        /^    network: /   { net = val($0) }
        /^    router: /    { mac = val($0) }
        /^    server_id: / { id = val($0) }
        /^    seen: /      { seen = val($0) }
        END { flush() }
    ' "$SERVERS"
}

# table on stdin → servers.yaml. Values are quoted: unquoted, YAML 1.1 reads a MAC
# address made of digits as a base-60 number.
write_servers() {
    awk '
        BEGIN {
            print "# Servers that answered, written by the Mountwell background service."
            print "# Used when a name does not resolve (Help: \"When DNS fails\")."
            print "# Remove an entry, or use Forget Remembered Server, to learn it again."
        }
        NF >= 5 {
            if (!started) { print "servers:"; started = 1 }
            printf "  - name: \"%s\"\n    ip: \"%s\"\n    network: \"%s\"\n    router: \"%s\"\n    server_id: \"%s\"\n    seen: \"%s\"\n", $1, $2, $3, $4, $5, $6
        }
        END { if (!started) print "servers: []" }
    ' > "$SERVERS.tmp" && mv "$SERVERS.tmp" "$SERVERS"
}

# entries <name>: one line per network the name was seen in: "<ip> <network> <router> <id>"
entries() {
    servers_table | awk -v n="$1" 'tolower($1) == tolower(n) {print $2, $3, $4, $5}'
    return 0
}

# the entry of <name> whose IP is reached right now through the network it was learned in
entry_here() {
    local e_ip e_net e_mac e_id
    while read -r e_ip e_net e_mac e_id; do
        [ -n "$e_ip" ] && [ "$(network_of "$e_ip")" = "$e_net $e_mac" ] && { echo "$e_ip $e_net $e_mac $e_id"; return 0; }
    done <<< "$(entries "$1")"
    return 0
}

# learn <name> <ip>: one entry per name and network, so a name that resolves at home does
# not replace what was learned at the office. Only a server that answers with its ID is
# remembered.
learn() {
    local net id
    [[ "$1" =~ ^[A-Za-z0-9._:-]+$ ]] || return 0
    net=$(network_of "$2")
    # no network, or the router not readable yet: try again next run
    [ -n "$net" ] && [ "${net#* }" != "?" ] || return 0
    entries "$1" | awk -v l="$2 $net " 'index($0, l) == 1 {f = 1} END {exit !f}' && return 0
    id=$(server_id "$2")
    [ -n "$id" ] || return 0
    { servers_table | awk -v n="$1" -v p="${net% *}" -v m="${net#* }" '!(tolower($1) == tolower(n) && $3 == p && $4 == m)'
      echo "$1 $2 $net $id $(date '+%FT%T')"; } | write_servers
    log "remembered $1 = $2 (network ${net% *}, router ${net#* })"
}

# with_host <url> <host>: the URL with only its server replaced; a plain substitution also
# hit the user name in smb://nas@nas/x
with_host() {
    local rest="${1#smb://}" user=""
    if [[ "${rest%%/*}" == *@* ]]; then
        user="${rest%%@*}@"
        rest="${rest#*@}"
    fi
    echo "smb://$user$2/${rest#*/}"
}

has_password() {
    security find-internet-password -s "$1" -r "smb " </dev/null >/dev/null 2>&1
}

# a message that would repeat every minute: only if it is not among the last log lines
note() {
    tail -n 30 "$LOG" 2>/dev/null | cut -c21- | grep -qxF "$*" || log "$*"
}

# the line format of the development builds before servers.yaml:
# "<name> <ip> <prefix> <router> <id>". Complete lines are carried over; the first
# builds wrote only three fields, which have no server ID to check against.
OLD_ADDRESSES="$CONFDIR/addresses"
if [ -f "$OLD_ADDRESSES" ]; then
    if [ ! -f "$SERVERS" ]; then
        awk 'NF == 5 && $1 ~ /^[A-Za-z0-9._:-]+$/ {print $0, "-"}' "$OLD_ADDRESSES" | write_servers
        log "converted $(awk 'NF == 5' "$OLD_ADDRESSES" | wc -l | tr -d ' ') remembered servers to servers.yaml"
    fi
    rm -f "$OLD_ADDRESSES"
fi

mountpoint_of() {
    # mount prints e.g. "//user@server/share on /Volumes/share (smbfs, ...)"; the device is
    # percent-encoded and has no spaces, the mount point may contain " on "
    # the name must follow "@" or "//", so "example.com/x" does not match "fileserver.example.com/x"
    mount -t smbfs | grep -iF -e "@$1 on " -e "//$1 on " | sed -E 's/^[^ ]+ on (.*) \(smbfs[^)]*\)$/\1/' | head -1
}

# "|| [ -n "$url" ]": a hand-edited file without a final newline keeps its last share
while read -r url nets || [ -n "${url:-}" ]; do
    [[ -z "$url" || "$url" == \#* ]] && continue
    off=""
    if [[ "$url" == \!* ]]; then
        off=1
        if [ "$url" = "!" ]; then read -r url nets <<< "$nets"; else url="${url#!}"; fi
        [ -n "$url" ] || continue
    fi
    nets="${nets%%#*}"           # "# alias" is for the app only
    nets="${nets//[[:space:]]/}"
    rest="${url#smb://}"
    rest="${rest#*@}"            # strip user@
    host="${rest%%/*}"
    share="${rest#*/}"
    key="$host/$share"
    if [ -n "$off" ]; then
        # switched off: no mounting or unmounting, but a connection made by hand still
        # tells which server is the right one
        mp=$(mountpoint_of "$key")
        if [ -z "$mp" ] && ! is_ip "$host"; then
            for kip in $(entries "$host" | awk '{print $1}'); do
                mp=$(mountpoint_of "$kip/$share")
                [ -n "$mp" ] && break
            done
        fi
        if [ -n "$mp" ]; then
            if is_ip "$host"; then
                learn "$host" "$host"
            else
                ip=$(resolve "$host")
                [ -n "$ip" ] && learn "$host" "$ip"
            fi
        fi
        continue
    fi
    probe="$host"
    target="$url"
    ip=""
    refuse=""         # before mounting: why not, or the server ID that must answer
    expect_id=""
    mounted_ip=""
    known=$(entries "$host")
    read -r hip _ _ hid <<< "$(entry_here "$host")"
    if is_ip "$host"; then
        # pinned on an earlier mount: only through a network it was seen in, same server
        if [ -n "${hip:-}" ]; then
            expect_id="$hid"
        elif [ -n "$known" ]; then
            refuse="$host is in a different network than before"
        fi
    else
        ip=$(resolve "$host")
        if [ -n "$ip" ]; then
            learn "$host" "$ip"
        elif [ -n "${hip:-}" ] && has_password "$hip"; then
            # name does not resolve (DNS down, VPN DNS broken): the IP learned in this network
            probe="$hip"
            target=$(with_host "$url" "$hip")
            expect_id="$hid"
        fi
    fi
    mp=$(mountpoint_of "$key")
    if [ -z "$mp" ] && ! is_ip "$host"; then
        # mounted via a remembered IP earlier: the same share
        for kip in $(awk '{print $1}' <<< "$known"); do
            mp=$(mountpoint_of "$kip/$share")
            [ -n "$mp" ] && { mounted_ip="$kip"; break; }
        done
    fi
    # mounted, but the name does not resolve right now: check the remembered IP the share is
    # on. Probing the name failed three times and force-unmounted working shares whenever
    # DNS dropped out for a minute while a VPN came up.
    if [ -n "$mp" ] && [ "$probe" = "$host" ] && ! is_ip "$host" && [ -z "$ip" ]; then
        if [ -n "$mounted_ip" ]; then
            probe="$mounted_ip"
        elif [ -n "${hip:-}" ]; then
            probe="$hip"
        elif [ -n "$known" ]; then
            probe=$(awk '{print $1; exit}' <<< "$known")
        fi
    fi
    # a share configured by IP: a mount in a network not seen before says which server is
    # the right one there
    [ -n "$mp" ] && is_ip "$host" && [ -z "${hip:-}" ] && learn "$host" "$host"
    # mounted again (by hand or via the app): no longer ejected
    [ -n "$mp" ] && unmark "$key"

    if in_allowed_net "${nets:-}"; then
        if [ -z "$mp" ]; then
            if ! reachable 1; then
                unmark "$key"    # server out of reach: mount again next time
            elif is_ejected "$key"; then
                :
            elif [ -n "$refuse" ]; then
                note "not mounting $url: $refuse"
            elif [ -n "$expect_id" ] && [ "$(server_id "$probe")" != "$expect_id" ]; then
                # no credentials go to a different device at the same IP
                note "not mounting $url: the server at $probe is not the one seen before"
            else
                if [ "$target" = "$url" ]; then
                    log "mounting $url"
                else
                    log "mounting $url via $probe ($host does not resolve)"
                fi
                # the URL as an argument, never inside the script text: a '"' in it would
                # otherwise end the string and run what follows as AppleScript
                osascript -e 'on run argv' -e 'mount volume (item 1 of argv)' -e 'end run' "$target" \
                    >/dev/null 2>&1 || log "mount failed: $target"
            fi
        elif ! reachable "$TRIES"; then
            # server unreachable several times: a normal unmount would hang
            log "$probe unreachable, unmounting $mp"
            diskutil unmount force "$mp" >/dev/null 2>&1 || umount -f "$mp"
        fi
    elif [ -n "$mp" ]; then
        if reachable 1; then
            # server still there: do not force, open files block the unmount
            log "wrong network, unmounting $mp"
            diskutil unmount "$mp" >/dev/null 2>&1 \
                || log "unmount failed (files open?): $mp"
        else
            log "wrong network and $probe unreachable, unmounting $mp"
            diskutil unmount force "$mp" >/dev/null 2>&1 || umount -f "$mp"
        fi
    else
        unmark "$key"    # left the network: mount again next time
    fi
done < "$CONF"
