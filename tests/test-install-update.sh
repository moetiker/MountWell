#!/bin/bash
# Tests for app/install-update.sh with stubs for pkgutil and installer.
set -u
cd "$(dirname "$0")/.."
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/tmp"
pass=0
fail=0

# pkgutil stub: the signature in $T/sig, exit status in $T/sigrc; records the checked file
cat > "$T/pkgutil" <<'S'
#!/bin/bash
echo "$2" > "$STUB/checked"
cat "$STUB/sig"
exit "$(cat "$STUB/sigrc" 2>/dev/null || echo 0)"
S
# installer stub: records which file it installs and what that file contains
cat > "$T/installer" <<'S'
#!/bin/bash
echo "$2 $(cat "$2")" > "$STUB/installed"
S
chmod +x "$T/pkgutil" "$T/installer"

signature() {   # signature <status> <leaf>
    cat > "$T/sig" <<S
Package "update.pkg":
   Status: $1
   Notarization: trusted by the Apple notary service
   Certificate Chain:
    1. $2
       Expires: 2031-10-29 10:00:00 +0000
    2. Developer ID Certification Authority
       Expires: 2031-09-17 00:00:00 +0000
    3. Apple Root CA
S
}
OK="signed by a developer certificate issued by Apple for distribution"

run_install() {   # run_install <pkg> <team>; sets rc
    rm -f "$T/installed" "$T/checked"
    STUB="$T" MOUNTWELL_PKGUTIL="$T/pkgutil" MOUNTWELL_INSTALLER="$T/installer" MOUNTWELL_TMPBASE="$T/tmp" \
        bash app/install-update.sh "$@" >/dev/null 2>&1
    rc=$?
}

ok() { if eval "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; fi; }

echo "real package" > "$T/update.pkg"
signature "$OK" "Developer ID Installer: Jane Example (AB12CD34EF)"
run_install "$T/update.pkg" AB12CD34EF
ok "signed by the team → installed" '[ $rc = 0 ] && [ -f "$T/installed" ]'
ok "checked and installed copy is outside the user's file" 'grep -q "^$T/tmp/mountwell-update\." "$T/checked" && [ "$(cut -d" " -f1 "$T/installed")" = "$(cat "$T/checked")" ]'
ok "installed copy has the downloaded content" 'grep -q " real package$" "$T/installed"'
ok "temporary directory removed afterwards" '[ -z "$(ls "$T/tmp")" ]'

# the user's file is swapped right after the copy: the copy is what gets installed
cat > "$T/pkgutil" <<'S'
#!/bin/bash
echo "$2" > "$STUB/checked"
echo "evil package" > "$STUB/update.pkg"
cat "$STUB/sig"
S
run_install "$T/update.pkg" AB12CD34EF
ok "package swapped after the copy → the checked copy is installed" 'grep -q " real package$" "$T/installed"'
cat > "$T/pkgutil" <<'S'
#!/bin/bash
echo "$2" > "$STUB/checked"
cat "$STUB/sig"
exit "$(cat "$STUB/sigrc" 2>/dev/null || echo 0)"
S
echo "real package" > "$T/update.pkg"

run_install "$T/update.pkg" ZZ99ZZ99ZZ
ok "other team → exit 4, not installed" '[ $rc = 4 ] && [ ! -f "$T/installed" ]'

signature "$OK" "Developer ID Application: Jane Example (AB12CD34EF)"
run_install "$T/update.pkg" AB12CD34EF
ok "application certificate → exit 4" '[ $rc = 4 ] && [ ! -f "$T/installed" ]'

signature "signed by a certificate trusted by Mac OS X" "Developer ID Installer: Jane Example (AB12CD34EF)"
run_install "$T/update.pkg" AB12CD34EF
ok "other status → exit 4" '[ $rc = 4 ] && [ ! -f "$T/installed" ]'

signature "$OK" "Developer ID Installer: Jane Example (AB12CD34EF)"
echo 1 > "$T/sigrc"
run_install "$T/update.pkg" AB12CD34EF
ok "pkgutil fails → exit 4" '[ $rc = 4 ] && [ ! -f "$T/installed" ]'
rm "$T/sigrc"

run_install "$T/update.pkg" ab12cd34ef
ok "team ID in lower case → exit 3" '[ $rc = 3 ] && [ ! -f "$T/installed" ]'
run_install "$T/missing.pkg" AB12CD34EF
ok "missing package → exit 3" '[ $rc = 3 ]'
run_install "$T/update.pkg"
ok "no team → exit 3" '[ $rc = 3 ]'

echo "$pass/$((pass + fail)) install-update tests ok"
[ "$fail" = 0 ]
