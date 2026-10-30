#!/bin/bash
# Tests for mountwell.sh. nc, mount, osascript, diskutil, umount and ifconfig
# are replaced by stubs, so the tests need neither a network nor real mounts.
set -u
cd "$(dirname "$0")/.."
SCRIPT="${MOUNTWELL_SCRIPT:-$PWD/mountwell.sh}"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

# stubs: behaviour is controlled by files in $T, calls are recorded in $T/calls
cat > "$T/bin/nc" <<'S'
#!/bin/bash
host="${@: -2:1}"
echo "nc $host" >> "$STUB/calls"
# flaky: the first n attempts fail (short dropout)
if [ -e "$STUB/flaky" ]; then
    [ "$(grep -c '^nc ' "$STUB/calls")" -gt "$(cat "$STUB/flaky")" ]
    exit
fi
grep -qxF "$host" "$STUB/reachable" 2>/dev/null
S
cat > "$T/bin/mount" <<'S'
#!/bin/bash
cat "$STUB/mounts" 2>/dev/null
S
# records "osascript mount <url>": the URL must arrive as an argument, not in the script
cat > "$T/bin/osascript" <<'S'
#!/bin/bash
if [ "$*" = "-e on run argv -e mount volume (item 1 of argv) -e end run ${@: -1}" ]; then
    echo "osascript mount ${@: -1}" >> "$STUB/calls"
else
    echo "osascript $*" >> "$STUB/calls"
fi
S
cat > "$T/bin/diskutil" <<'S'
#!/bin/bash
echo "diskutil $*" >> "$STUB/calls"
# busy: files open, only a forced unmount succeeds
[ -e "$STUB/busy" ] && [ "$2" != force ] && exit 1
exit 0
S
cat > "$T/bin/umount" <<'S'
#!/bin/bash
echo "umount $*" >> "$STUB/calls"
S
cat > "$T/bin/ifconfig" <<'S'
#!/bin/bash
echo "	inet 127.0.0.1 netmask 0xff000000"
echo "	inet ${STUB_IP:-10.46.105.116} netmask 0xffffff00 broadcast 10.46.105.255"
S
# names resolve only when listed in $STUB/dns ("name ip")
cat > "$T/bin/dscacheutil" <<'S'
#!/bin/bash
ip=$(awk -v n="$5" '$1 == n {print $2}' "$STUB/dns" 2>/dev/null)
[ -n "$ip" ] && printf 'name: %s\nip_address: %s\n\n' "$5" "$ip"
exit 0
S
# keychain: SMB passwords exist for the servers listed in $STUB/keychain
cat > "$T/bin/security" <<'S'
#!/bin/bash
grep -qxF "$3" "$STUB/keychain" 2>/dev/null
S
cat > "$T/bin/route" <<'S'
#!/bin/bash
echo "   route to: $3"
echo "  interface: ${STUB_IFACE:-en0}"
S
cat > "$T/bin/ipconfig" <<'S'
#!/bin/bash
echo 10.46.105.1
S
cat > "$T/bin/arp" <<'S'
#!/bin/bash
# STUB_MAC=none: not in the ARP cache (right after a network change)
if [ "${STUB_MAC:-}" = none ]; then
    echo "? ($2) at (incomplete) on en0 ifscope [ethernet]"
else
    echo "? ($2) at ${STUB_MAC:-aa:bb:cc:0:11:22} on en0 ifscope [ethernet]"
fi
S
cat > "$T/bin/ping" <<'S'
#!/bin/bash
echo "ping $*" >> "$STUB/calls"
S
# SMB server IDs per address in $STUB/ids ("ip id"); no line: no answer
cat > "$T/bin/smb-id" <<'S'
#!/bin/bash
id=$(awk -v h="$1" '$1 == h {print $2}' "$STUB/ids" 2>/dev/null)
[ -n "$id" ] && echo "$id"
S
chmod +x "$T/bin/"*

pass=0
fail=0

# setup <conf> <reachable hosts> <mount lines>
setup() {
    rm -rf "$T/home" "$T/calls" "$T/reachable" "$T/mounts" "$T/flaky" "$T/busy" "$T/dns" "$T/keychain" "$T/ids"
    mkdir -p "$T/home/.config/mountwell"
    printf '%b' "$1" > "$T/home/.config/mountwell/shares.conf"
    printf '%b' "$2" > "$T/reachable"
    printf '%b' "$3" > "$T/mounts"
    touch "$T/calls"
}

# runit: one run of the script. A crash counts as a failure of its own, otherwise every
# "nothing happens" test passes when the script dies early.
runit() {
    local rc=0
    HOME="$T/home" STUB="$T" MOUNTWELL_RETRY_DELAY=0 MOUNTWELL_SMBID="$T/bin/smb-id" PATH="$T/bin:$PATH" \
        bash "$SCRIPT" --now >/dev/null 2>"$T/stderr" || rc=$?
    if [ "$rc" != 0 ] || grep -qE 'unbound variable|syntax error|command not found|No such file' "$T/stderr"; then
        fail=$((fail + 1))
        echo "FAIL: script crashed (exit $rc) in the test after: ${last:-start}"
        sed 's/^/      /' "$T/stderr"
    fi
    return 0
}

expect() {   # expect <name> <expected line> [grep|nogrep]
    local name="$1" want="$2" mode="${3:-grep}" ok=1
    last="$name"
    if [ "$mode" = grep ]; then
        grep -qF -- "$want" "$T/calls" || ok=0
    else
        grep -qE -- "$want" "$T/calls" && ok=0
    fi
    if [ $ok = 1 ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: $name"
        sed 's/^/      /' "$T/calls"
    fi
}

M='//anna@fileserver.example.com/team on /Volumes/team (smbfs, nodev, nosuid, mounted by anna)\n'

setup 'smb://fileserver.example.com/team\n' 'fileserver.example.com\n' ''
runit
expect "reachable, not mounted → mount" 'osascript mount smb://fileserver.example.com/team'
grep -q 'mounting smb://fileserver.example.com/team' "$T/home/Library/Logs/mountwell.log" \
    && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: log entry missing"; }

setup 'smb://fileserver.example.com/team\n' 'fileserver.example.com\n' "$M"
runit
expect "reachable, mounted → do nothing" 'osascript|diskutil' nogrep

setup 'smb://fileserver.example.com/team\n' '' "$M"
runit
expect "unreachable, mounted → unmount" 'diskutil unmount force /Volumes/team'
[ "$(grep -c '^nc ' "$T/calls")" = 3 ] && pass=$((pass + 1)) \
    || { fail=$((fail + 1)); echo "FAIL: not checked three times before unmounting"; }

setup 'smb://fileserver.example.com/team\n' '' "$M"
echo 2 > "$T/flaky"
runit
expect "short dropout (2 failed attempts) → do not unmount" 'diskutil' nogrep

setup 'smb://fileserver.example.com/team\n' '' ''
runit
expect "unreachable, not mounted → do nothing" 'osascript|diskutil' nogrep

setup 'smb://FileServer.Example.com/Team\n' 'FileServer.Example.com\n' "$M"
runit
expect "comparison ignores case" 'osascript|diskutil' nogrep

setup 'smb://fileserver.example.com/team 192.168.1.\n' 'fileserver.example.com\n' "$M"
runit
expect "wrong network, server there → normal unmount" 'diskutil unmount /Volumes/team'
expect "wrong network, server there → do not force" 'force|umount' nogrep

setup 'smb://fileserver.example.com/team 192.168.1.\n' 'fileserver.example.com\n' "$M"
touch "$T/busy"
runit
expect "wrong network, files open → do not force" 'force|umount' nogrep
grep -q 'unmount failed (files open?): /Volumes/team' "$T/home/Library/Logs/mountwell.log" \
    && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: log entry for blocked unmount missing"; }

setup 'smb://fileserver.example.com/team 192.168.1.\n' '' "$M"
runit
expect "wrong network, server gone → force" 'diskutil unmount force /Volumes/team'

setup 'smb://fileserver.example.com/team 192.168.1.\n' 'fileserver.example.com\n' ''
runit
expect "wrong network, not mounted → do not even check the server" '^nc ' nogrep

setup 'smb://fileserver.example.com/team 192.168.1.,10.46.\n' 'fileserver.example.com\n' ''
runit
expect "matching network (second prefix) → mount" 'osascript mount '

setup 'smb://fileserver.example.com/team # Team Drive\n' 'fileserver.example.com\n' ''
runit
expect "alias without networks → mount" 'osascript mount smb://fileserver.example.com/team'

setup 'smb://fileserver.example.com/team 10.46. # Team Drive\n' 'fileserver.example.com\n' ''
runit
expect "alias after networks → mount" 'osascript mount smb://fileserver.example.com/team'

setup 'smb://fileserver.example.com/team 192.168.1. # Team Drive\n' 'fileserver.example.com\n' "$M"
runit
expect "alias after networks, wrong network → unmount" 'diskutil unmount /Volumes/team'

setup '!smb://fileserver.example.com/team\n' 'fileserver.example.com\n' ''
runit
expect "disabled share, not mounted → do nothing" 'nc|osascript|diskutil' nogrep

setup '! smb://fileserver.example.com/team 192.168.1. # Team\n' '' "$M"
runit
expect "disabled share, mounted, wrong network, unreachable → leave it" 'nc|osascript|diskutil|umount' nogrep

setup '!smb://a.example/x\nsmb://fileserver.example.com/team\n' 'fileserver.example.com\n' ''
runit
expect "disabled share does not stop the others" 'osascript mount smb://fileserver.example.com/team'

setup 'smb://fileserver.example.com/team\n' 'fileserver.example.com\n' ''
touch "$T/home/.config/mountwell/disabled"
runit
expect "disabled → do nothing" 'nc|osascript|diskutil' nogrep

# remembered servers: DNS fallback and servers configured by IP
A="$T/home/.config/mountwell/servers.yaml"
LOGF="$T/home/Library/Logs/mountwell.log"
MIP='//anna@10.46.1.20/team on /Volumes/team (smbfs, nodev, nosuid, mounted by anna)\n'
NET="10.46.105. aa:bb:cc:0:11:22"
ENTRY="fileserver.example.com 10.46.1.20 $NET 0123abcd"

# servers.yaml as "<name> <ip> <network> <router> <id>" lines, read independently of the script
table() {
    awk '/^  - name: /{if (l) print l; l = ""} /^  - name: |^    (ip|network|router|server_id): / {
        v = $0; sub(/^[^:]*: */, "", v); gsub(/"/, "", v); l = (l == "" ? v : l " " v)} END {if (l) print l}' "$1" 2>/dev/null
}

# servers <entry>…: write servers.yaml the way the script does
servers() {
    echo "servers:"
    local e
    for e in "$@"; do
        set -- $e
        printf '  - name: "%s"\n    ip: "%s"\n    network: "%s"\n    router: "%s"\n    server_id: "%s"\n    seen: "2026-01-01T00:00:00"\n' "$1" "$2" "$3" "$4" "$5"
    done
}

# check <name> <servers.yaml> <expected entry> [absent]
check() {
    if { [ "${4:-}" = absent ] && ! table "$2" | grep -qxF "$3"; } \
        || { [ "${4:-}" != absent ] && table "$2" | grep -qxF "$3"; }; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1)); echo "FAIL: $1"; sed 's/^/      /' "$2" 2>/dev/null
    fi
}

# fallback <reachable> <mounts>: name does not resolve, server remembered, password saved
fallback() {
    setup 'smb://anna@fileserver.example.com/team\n' "$1" "$2"
    servers "$ENTRY" > "$A"
    echo 10.46.1.20 > "$T/keychain"
    echo "10.46.1.20 0123abcd" > "$T/ids"
}

setup 'smb://anna@fileserver.example.com/team\n' 'fileserver.example.com\n' ''
echo "fileserver.example.com 10.46.1.20" > "$T/dns"
echo "10.46.1.20 0123abcd" > "$T/ids"
runit
check "name resolves → address, network, router and server ID remembered" "$A" "$ENTRY"
expect "name resolves → mounted by name" 'osascript mount smb://anna@fileserver.example.com/team'

setup 'smb://anna@fileserver.example.com/team\n' 'fileserver.example.com\n' ''
echo "fileserver.example.com 10.46.1.20" > "$T/dns"
echo "10.46.1.20 0123abcd" > "$T/ids"
STUB_IFACE=utun4 runit
check "over VPN → no router" "$A" "fileserver.example.com 10.46.1.20 10.46.105. - 0123abcd"

setup 'smb://anna@fileserver.example.com/team\n' 'fileserver.example.com\n' ''
echo "fileserver.example.com 10.46.1.20" > "$T/dns"
servers "$ENTRY" > "$A"
runit
check "server does not answer with an ID → entry kept as it was" "$A" "$ENTRY"

fallback '10.46.1.20\n' ''
runit
expect "name does not resolve, same network, router and server → mount via IP" 'osascript mount smb://anna@10.46.1.20/team'

fallback '10.46.1.20\n' ''
STUB_IP=192.168.1.23 runit
expect "other network → remembered IP not contacted" 'nc 10.46.1.20|osascript' nogrep

fallback '10.46.1.20\n' ''
STUB_MAC=aa:bb:cc:0:99:99 runit
expect "same range, other router → remembered IP not contacted" 'nc 10.46.1.20|osascript' nogrep

fallback '10.46.1.20\n' ''
echo "10.46.1.20 ffff0000" > "$T/ids"
runit
expect "same network, other server at the IP → not mounted" 'osascript' nogrep
grep -qF "not mounting smb://anna@fileserver.example.com/team: the server at 10.46.1.20 is not the one seen before" "$LOGF" \
    && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: other server → logged"; }
runit
if [ "$(grep -c 'not the one seen before' "$LOGF")" = 1 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: repeated refusal logged once"; fi

fallback '10.46.1.20\n' ''
rm "$T/keychain"
runit
expect "no keychain password for the IP → no fallback, no password dialog" 'nc 10.46.1.20|osascript' nogrep

fallback '10.46.1.20\n' "$MIP"
runit
expect "mounted via IP, IP answers → stays mounted" 'diskutil|umount|osascript' nogrep

fallback '' "$MIP"
runit
expect "mounted via IP, IP gone → unmounted" 'diskutil unmount force /Volumes/team'

fallback '10.46.1.20\n' ''
echo "fileserver.example.com/team" > "$T/home/.config/mountwell/ejected"
runit
expect "ejected share is not mounted via IP either" 'osascript' nogrep

# switched off: remembered while mounted by hand, never mounted or unmounted
setup '!smb://manuel@10.46.1.20/data # Data\n' '10.46.1.20\n' '//manuel@10.46.1.20/data on /Volumes/data (smbfs, nodev, nosuid, mounted by anna)\n'
echo "10.46.1.20 0123abcd" > "$T/ids"
runit
check "switched off, configured by IP, mounted by hand → server remembered" "$A" "10.46.1.20 10.46.1.20 $NET 0123abcd"
expect "switched off, mounted by hand → left alone" 'osascript|diskutil|umount' nogrep

setup '! smb://anna@fileserver.example.com/team\n' 'fileserver.example.com\n' "$M"
echo "fileserver.example.com 10.46.1.20" > "$T/dns"
echo "10.46.1.20 0123abcd" > "$T/ids"
runit
check "switched off (with space), name resolves, mounted by hand → server remembered" "$A" "$ENTRY"

setup '!smb://anna@fileserver.example.com/team\n' 'fileserver.example.com\n' ''
echo "fileserver.example.com 10.46.1.20" > "$T/dns"
echo "10.46.1.20 0123abcd" > "$T/ids"
runit
check "switched off, not mounted → nothing remembered" "$A" "$ENTRY" absent
expect "switched off, not mounted → server not contacted" 'nc|osascript' nogrep

# mounted by name, DNS drops out: checked via the remembered IP, not force-unmounted
setup 'smb://anna@fileserver.example.com/team\n' '10.46.1.20\n' "$M"
servers "$ENTRY" > "$A"
STUB_MAC=aa:bb:cc:0:99:99 runit
expect "mounted by name, name does not resolve, IP answers → stays mounted" 'diskutil|umount' nogrep
expect "mounted by name, name does not resolve → probed via the remembered IP" 'nc 10.46.1.20'

setup 'smb://anna@fileserver.example.com/team\n' '' "$M"
servers "$ENTRY" > "$A"
runit
expect "mounted by name, name does not resolve, IP gone too → unmounted" 'diskutil unmount force /Volumes/team'

# router not in the ARP cache
setup 'smb://anna@fileserver.example.com/team\n' 'fileserver.example.com\n' ''
echo "fileserver.example.com 10.46.1.20" > "$T/dns"
echo "10.46.1.20 0123abcd" > "$T/ids"
STUB_MAC=none runit
expect "router MAC unknown → router pinged once" 'ping -c 1 -t 1 10.46.105.1'
check "router MAC unknown → nothing remembered" "$A" "fileserver.example.com 10.46.1.20 10.46.105. ? 0123abcd" absent
if [ -s "$A" ] && table "$A" | grep -q .; then fail=$((fail + 1)); echo "FAIL: router MAC unknown → no entry at all"; else pass=$((pass + 1)); fi

fallback '10.46.1.20\n' ''
STUB_MAC=none runit
expect "router MAC unknown → remembered IP not used" 'osascript' nogrep

# YAML file
setup 'smb://anna@fileserver.example.com/team\n' 'fileserver.example.com\n' ''
echo "fileserver.example.com 10.46.1.20" > "$T/dns"
echo "10.46.1.20 12345678" > "$T/ids"
STUB_MAC=12:34:56:10:20:30 runit
grep -qxF '    router: "12:34:56:10:20:30"' "$A" && grep -qxF '  - name: "fileserver.example.com"' "$A" \
    && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: servers.yaml quotes its values"; cat "$A"; }
setup 'smb://anna@fileserver.example.com/team\n' '' ''
printf '%s\nold.example.com 10.1.1.1 10.1.1.\n10.9.9.9 10.9.9.9 10.9.9. - ab12\n' "$ENTRY" > "$T/home/.config/mountwell/addresses"
runit
check "old addresses file → entry converted" "$A" "$ENTRY"
check "old addresses file → IP entry converted" "$A" "10.9.9.9 10.9.9.9 10.9.9. - ab12"
check "old addresses file → three-field line dropped" "$A" "old.example.com 10.1.1.1 10.1.1." absent
[ ! -e "$T/home/.config/mountwell/addresses" ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: old addresses file removed after converting"; }

# one run at a time
setup 'smb://fileserver.example.com/team\n' 'fileserver.example.com\n' ''
sleep 30 & holder=$!
shlock -f "$T/home/.config/mountwell/.run.lock" -p $holder
HOME="$T/home" STUB="$T" MOUNTWELL_RETRY_DELAY=0 MOUNTWELL_LOCK_WAIT=0 MOUNTWELL_SMBID="$T/bin/smb-id" PATH="$T/bin:$PATH" bash "$SCRIPT" --now >/dev/null 2>&1
kill $holder 2>/dev/null; wait $holder 2>/dev/null
expect "another run holds the lock → nothing done" 'nc|osascript' nogrep
grep -qF "skipped: another run is still going" "$LOGF" && pass=$((pass + 1)) \
    || { fail=$((fail + 1)); echo "FAIL: another run holds the lock → skip logged"; }
runit
expect "lock of a finished run → taken over" 'osascript mount '

# review fixes
setup 'smb://fileserver.example.com/x"&(do_shell_script)&"\n' 'fileserver.example.com\n' ''
runit
expect "quote in the URL → passed to osascript as an argument, unchanged" 'osascript mount smb://fileserver.example.com/x"&(do_shell_script)&"'

setup 'smb://fileserver.example.com/team 10.99.,,192.168.77.\n' 'fileserver.example.com\n' ''
runit
expect "empty entry in the network list → does not match every network" 'osascript' nogrep

setup 'smb://fileserver.example.com/team ,\n' 'fileserver.example.com\n' ''
runit
expect "network list of only commas → no limit, as the app shows it" 'osascript mount smb://fileserver.example.com/team'

setup 'smb://fileserver.example.com/Data%20on%20NAS\n' '' '//anna@fileserver.example.com/Data%20on%20NAS on /Volumes/Data on NAS (smbfs, nodev, nosuid, mounted by anna)\n'
runit
expect "mount point containing \" on \" → unmounted at the right path" 'diskutil unmount force /Volumes/Data on NAS'

setup 'smb://nas@nas.example.com/team\n' '10.46.1.20\n' ''
servers "nas.example.com 10.46.1.20 $NET 0123abcd" > "$A"
echo 10.46.1.20 > "$T/keychain"
echo "10.46.1.20 0123abcd" > "$T/ids"
runit
expect "user name equal to the server name → only the server replaced" 'osascript mount smb://nas@10.46.1.20/team'

setup 'smb://anna@fileserver.example.com/team\n' 'fileserver.example.com\n' ''
echo "fileserver.example.com 192.168.1.30" > "$T/dns"
echo "192.168.1.30 99990000" > "$T/ids"
servers "$ENTRY" > "$A"
STUB_MAC=aa:bb:cc:0:77:77 STUB_IP=192.168.1.23 runit
check "name resolves in a second network → office entry kept" "$A" "$ENTRY"
check "name resolves in a second network → second entry added" "$A" "fileserver.example.com 192.168.1.30 192.168.1. aa:bb:cc:0:77:77 99990000"

setup 'smb://anna@fileserver.example.com/team\n' '10.46.1.20\n' ''
servers "fileserver.example.com 192.168.1.30 192.168.1. aa:bb:cc:0:77:77 99990000" "$ENTRY" > "$A"
echo 10.46.1.20 > "$T/keychain"
echo "10.46.1.20 0123abcd" > "$T/ids"
runit
expect "two networks remembered → fallback uses the entry of the current one" 'osascript mount smb://anna@10.46.1.20/team'

setup 'smb://10.46.1.20/team\n' '10.46.1.20\n' ''
servers "10.46.1.20 10.46.1.20 192.168.1. aa:bb:cc:0:77:77 0123abcd" > "$A"
echo "10.46.1.20 0123abcd" > "$T/ids"
runit
expect "configured by IP, only seen in another network → not mounted" 'osascript' nogrep
grep -qF "not mounting smb://10.46.1.20/team: 10.46.1.20 is in a different network than before" "$LOGF" \
    && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: other network → logged"; }

setup 'smb://10.46.1.20/team\n' '10.46.1.20\n' "$MIP"
servers "10.46.1.20 10.46.1.20 192.168.1. aa:bb:cc:0:77:77 0123abcd" > "$A"
echo "10.46.1.20 ffff0000" > "$T/ids"
runit
check "configured by IP, mounted by hand in a new network → pinned there too" "$A" "10.46.1.20 10.46.1.20 $NET ffff0000"
check "configured by IP, mounted in a new network → first network kept" "$A" "10.46.1.20 10.46.1.20 192.168.1. aa:bb:cc:0:77:77 0123abcd"

setup 'smb://a.example/x\nsmb://b.example/y' 'a.example\nb.example\n' ''
runit
expect "last line without a newline → still read" 'osascript mount smb://b.example/y'

# configured by IP
IPENTRY="10.46.1.20 10.46.1.20 $NET 0123abcd"
setup 'smb://10.46.1.20/team\n' '10.46.1.20\n' ''
runit
expect "configured by IP, nothing remembered → mounted as before" 'osascript mount smb://10.46.1.20/team'

setup 'smb://10.46.1.20/team\n' '10.46.1.20\n' "$MIP"
echo "10.46.1.20 0123abcd" > "$T/ids"
runit
check "configured by IP, mounted → server remembered" "$A" "$IPENTRY"

setup 'smb://10.46.1.20/team\n' '10.46.1.20\n' ''
servers "$IPENTRY" > "$A"
echo "10.46.1.20 0123abcd" > "$T/ids"
runit
expect "configured by IP, same network and server → mounted" 'osascript mount smb://10.46.1.20/team'

setup 'smb://10.46.1.20/team\n' '10.46.1.20\n' ''
servers "$IPENTRY" > "$A"
echo "10.46.1.20 0123abcd" > "$T/ids"
STUB_MAC=aa:bb:cc:0:99:99 runit
expect "configured by IP, other router with the same range → not mounted" 'osascript' nogrep

setup 'smb://10.46.1.20/team\n' '10.46.1.20\n' ''
servers "$IPENTRY" > "$A"
echo "10.46.1.20 ffff0000" > "$T/ids"
runit
expect "configured by IP, other server at the IP → not mounted" 'osascript' nogrep

setup '' 'fileserver.example.com\n' ''
rm "$T/home/.config/mountwell/shares.conf"
runit && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: exit code ≠ 0 without configuration"; }

setup '# comment\n\n   \nsmb://a.example/x\n# smb://b.example/y\n' 'a.example\nb.example\n' ''
runit
expect "comments and blank lines are ignored" 'b.example' nogrep
expect "entry after comments is processed" 'osascript mount smb://a.example/x'

setup 'smb://a.example/x\nsmb://b.example/y\n' 'b.example\n' \
    '//u@a.example/x on /Volumes/x (smbfs)\n'
runit
expect "several shares: unmount a" 'diskutil unmount force /Volumes/x'
expect "several shares: mount b" 'osascript mount smb://b.example/y'

setup 'smb://srv.example/share\n' 'srv.example\n' \
    '//u@srv.example/share-old on /Volumes/share-old (smbfs)\n'
runit
expect "similar name does not count as mounted" 'osascript mount smb://srv.example/share'

setup 'smb://example.com/team\n' 'example.com\n' "$M"
runit
expect "host suffix does not count as mounted" 'osascript mount smb://example.com/team'

# ejected by hand in the app
E="$T/home/.config/mountwell/ejected"
setup 'smb://fileserver.example.com/team\n' 'fileserver.example.com\n' ''
echo "FileServer.Example.com/team" > "$E"
runit
expect "ejected, reachable → do not mount again" 'osascript' nogrep
grep -qix "fileserver.example.com/team" "$E" && pass=$((pass + 1)) \
    || { fail=$((fail + 1)); echo "FAIL: eject entry lost while server reachable"; }

setup 'smb://fileserver.example.com/team\nsmb://fileserver.example.com/other\n' 'fileserver.example.com\n' ''
printf 'fileserver.example.com/team\n' > "$E"
runit
expect "ejected share does not block other shares" 'osascript mount smb://fileserver.example.com/other'

setup 'smb://fileserver.example.com/team\n' '' ''
echo "fileserver.example.com/team" > "$E"
runit
grep -qi "fileserver.example.com/team" "$E" && { fail=$((fail + 1)); echo "FAIL: eject not forgotten when server out of reach"; } \
    || pass=$((pass + 1))

setup 'smb://fileserver.example.com/team 192.168.1.\n' 'fileserver.example.com\n' ''
echo "fileserver.example.com/team" > "$E"
runit
grep -qi "fileserver.example.com/team" "$E" && { fail=$((fail + 1)); echo "FAIL: eject not forgotten in another network"; } \
    || pass=$((pass + 1))

setup 'smb://fileserver.example.com/team\n' 'fileserver.example.com\n' "$M"
echo "fileserver.example.com/team" > "$E"
runit
grep -qi "fileserver.example.com/team" "$E" && { fail=$((fail + 1)); echo "FAIL: eject not forgotten after mounting again"; } \
    || pass=$((pass + 1))
expect "mounted again by hand → leave it mounted" 'diskutil|osascript' nogrep

# predecessor SMB Automount: configuration and log are taken over
setup '' 'fileserver.example.com\n' ''
rm -rf "$T/home/.config/mountwell"
mkdir -p "$T/home/.config/smb-automount" "$T/home/Library/Logs"
printf 'smb://fileserver.example.com/team\n' > "$T/home/.config/smb-automount/shares.conf"
echo "old entry" > "$T/home/Library/Logs/smb-automount.log"
runit
expect "old configuration taken over → mount" 'osascript mount smb://fileserver.example.com/team'
[ -e "$T/home/.config/mountwell/shares.conf" ] && [ ! -e "$T/home/.config/smb-automount" ] \
    && grep -q "old entry" "$T/home/Library/Logs/mountwell.log" \
    && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: configuration/log not taken over"; }

setup 'smb://neu.example/x\n' '' ''
mkdir -p "$T/home/.config/smb-automount"
runit
[ -e "$T/home/.config/smb-automount" ] && grep -q neu.example "$T/home/.config/mountwell/shares.conf" \
    && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: existing MountWell configuration overwritten"; }

echo "$pass/$((pass + fail)) script tests ok"
[ $fail = 0 ]
