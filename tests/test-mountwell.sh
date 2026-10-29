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
cat > "$T/bin/osascript" <<'S'
#!/bin/bash
echo "osascript $*" >> "$STUB/calls"
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
chmod +x "$T/bin/"*

pass=0
fail=0

# setup <conf> <reachable hosts> <mount lines>
setup() {
    rm -rf "$T/home" "$T/calls" "$T/reachable" "$T/mounts" "$T/flaky" "$T/busy"
    mkdir -p "$T/home/.config/mountwell"
    printf '%b' "$1" > "$T/home/.config/mountwell/shares.conf"
    printf '%b' "$2" > "$T/reachable"
    printf '%b' "$3" > "$T/mounts"
    touch "$T/calls"
}

runit() {
    HOME="$T/home" STUB="$T" MOUNTWELL_RETRY_DELAY=0 PATH="$T/bin:$PATH" bash "$SCRIPT" --now >/dev/null 2>&1
}

expect() {   # expect <name> <expected line> [grep|nogrep]
    local name="$1" want="$2" mode="${3:-grep}" ok=1
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
expect "reachable, not mounted → mount" 'osascript -e mount volume "smb://fileserver.example.com/team"'
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
expect "matching network (second prefix) → mount" 'osascript -e mount volume'

setup 'smb://fileserver.example.com/team # Team Drive\n' 'fileserver.example.com\n' ''
runit
expect "alias without networks → mount" 'osascript -e mount volume "smb://fileserver.example.com/team"'

setup 'smb://fileserver.example.com/team 10.46. # Team Drive\n' 'fileserver.example.com\n' ''
runit
expect "alias after networks → mount" 'osascript -e mount volume "smb://fileserver.example.com/team"'

setup 'smb://fileserver.example.com/team 192.168.1. # Team Drive\n' 'fileserver.example.com\n' "$M"
runit
expect "alias after networks, wrong network → unmount" 'diskutil unmount /Volumes/team'

setup 'smb://fileserver.example.com/team\n' 'fileserver.example.com\n' ''
touch "$T/home/.config/mountwell/disabled"
runit
expect "disabled → do nothing" 'nc|osascript|diskutil' nogrep

setup '' 'fileserver.example.com\n' ''
rm "$T/home/.config/mountwell/shares.conf"
runit && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: exit code ≠ 0 without configuration"; }

setup '# comment\n\n   \nsmb://a.example/x\n# smb://b.example/y\n' 'a.example\nb.example\n' ''
runit
expect "comments and blank lines are ignored" 'b.example' nogrep
expect "entry after comments is processed" 'mount volume "smb://a.example/x"'

setup 'smb://a.example/x\nsmb://b.example/y\n' 'b.example\n' \
    '//u@a.example/x on /Volumes/x (smbfs)\n'
runit
expect "several shares: unmount a" 'diskutil unmount force /Volumes/x'
expect "several shares: mount b" 'mount volume "smb://b.example/y"'

setup 'smb://srv.example/share\n' 'srv.example\n' \
    '//u@srv.example/share-old on /Volumes/share-old (smbfs)\n'
runit
expect "similar name does not count as mounted" 'mount volume "smb://srv.example/share"'

setup 'smb://example.com/team\n' 'example.com\n' "$M"
runit
expect "host suffix does not count as mounted" 'mount volume "smb://example.com/team"'

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
expect "ejected share does not block other shares" 'mount volume "smb://fileserver.example.com/other"'

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
expect "old configuration taken over → mount" 'mount volume "smb://fileserver.example.com/team"'
[ -e "$T/home/.config/mountwell/shares.conf" ] && [ ! -e "$T/home/.config/smb-automount" ] \
    && grep -q "old entry" "$T/home/Library/Logs/mountwell.log" \
    && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: configuration/log not taken over"; }

setup 'smb://neu.example/x\n' '' ''
mkdir -p "$T/home/.config/smb-automount"
runit
[ -e "$T/home/.config/smb-automount" ] && grep -q neu.example "$T/home/.config/mountwell/shares.conf" \
    && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: existing Mountwell configuration overwritten"; }

echo "$pass/$((pass + fail)) script tests ok"
[ $fail = 0 ]
