# Maintainer notes

Reasons and pitfalls. Each point names the symptom, so it can be checked whether it
still applies.

## Name and icon

- The predecessor was "SMB Automount" (`ch.oetiker.smb-automount`, package 1.0).
  `postinstall` removes it; script and `postinstall` move its configuration and log.
- "Mountly" is taken by a macOS mount app. "Mountwell" was free in October 2026.
- The icon is drawn by `app/make-icon.swift`; the SF Symbol license forbids app icons.

## Language

- `Localizable.strings` keys are the English texts, with `%@` and `%lld`; two integers
  become `%1$lld`/`%2$lld` in German.
- A `String` passed through a parameter is shown verbatim, so `Hint` takes `Text` and
  `Tag` takes `LocalizedStringKey`.
- Help texts are multi-line literals; the key is the text after Swift strips the
  indentation, lines joined by `\n`. Change the English text and the German key must
  follow, or the help silently falls back to English.
- `en.lproj/Localizable.strings` is empty but must exist, or macOS does not list English.

## Build

- Stale headers in `/usr/local/include` make `swiftc` fail with
  `#include nested too deeply`. `build.sh` and `tests/run.sh` export `SDKROOT`;
  `swiftc -sdk` does not cover `swift app/make-icon.swift`.
- `-swift-version 5` keeps Swift 6 concurrency checks from failing the build.
- No Xcode project: `swiftc -parse-as-library` per architecture, then `lipo`.
  `-parse-as-library` because `@main` clashes with top-level code.
- With several files only `main.swift` may hold top-level code, so the tests live in
  `tests/main.swift`.
- Apple silicon requires a signature; without a Developer ID it is ad hoc
  (`codesign --sign -`).

## Signing

- `build.sh` finds the certificates with `security find-identity`: codesigning policy for
  "Developer ID Application", basic policy for "Developer ID Installer" (the installer
  certificate is not a code signing identity).
- Notarization requires `--options runtime` and `--timestamp`. No entitlements are needed:
  the app starts `osascript`, `nc` and `pkgutil` as separate processes.
- `notarytool submit --wait` exits 0 also for "Invalid", so `build.sh` reads the status
  from the plist output and prints the log on anything but "Accepted".
- `AssociatedBundleIdentifiers` in the LaunchAgent only shows "Mountwell" in Login Items
  when app and agent come from a team-signed package (I-6).
- CI: `MACOS_CERTS_P12` holds both certificates in one .p12 (base64),
  `MACOS_CERTS_PASSWORD` its password, `NOTARY_KEY_P8`, `NOTARY_KEY_ID` and
  `NOTARY_ISSUER` the App Store Connect API key. They go into a temporary keychain;
  `set-key-partition-list` keeps `codesign` from asking for the keychain password.
  `release-build.yml` passes the secrets on with `secrets: inherit`.
- With the secrets set, `REQUIRE_SIGNING=1`: a release with `TEAM_ID` in it makes every
  installed app reject unsigned updates from then on.

## Package

- `BundleIsRelocatable` is off. Otherwise Installer updates the copy in
  `build/root/Applications/` instead of `/Applications`.
- Built inside a sandbox, files keep `com.apple.provenance` and `pkgbuild` adds `._`
  entries. Build from a normal Terminal.
- The LaunchAgent is in `/Library/LaunchAgents`, where `~` is not allowed in
  `StandardOutPath`, so the script writes its own log.
- `postinstall` runs as root, finds users via `loginwindow` and uses
  `launchctl bootstrap gui/<uid>` and `launchctl asuser … sudo -u … open`.
- `postinstall` removes both the per-user and system-wide SMB Automount agents, or two
  services would handle the same shares.
- `uninstall.sh` deletes its own bundle, so everything runs in `main()` followed by
  `exit`; bash would otherwise read on from the deleted file.
- `preinstall` records a running app in `/var/run/ch.oetiker.mountwell.relaunch.<uid>`
  for `postinstall`. A file in `/tmp` could be pre-created as a symlink.

## Mount script

- `WatchPaths` misses VPN clients that only add a `utun` interface; `StartInterval` 60
  catches them.
- Reachable means `nc -z -G 2 <host> 445`. `-G` does not bound a hanging DNS lookup.
- `mount` prints `//user@host/share on …` even without a user. The match requires `@` or
  `/` before and ` on ` after `server/share` (M-7).
- `osascript … mount volume` is used because it takes the password from the keychain. It
  must have been saved once in Finder, or every run shows a dialog.
- `diskutil unmount force`, then `umount -f`: a plain unmount fails once the server is
  gone and Finder hangs.
- A forced unmount discards open files, hence three tries 5 s apart (`TRIES`,
  `MOUNTWELL_RETRY_DELAY`). A Wi-Fi dropout once unmounted a working share.
- An eject in Finder looks like a lost connection. The app's eject writes `ejected` first;
  the entry lasts until the network or server changes (M-6).
- The first version logged "no configuration" every minute and exited 1 (now M-9).
- For a CNAME the reverse lookup returns the host name, not the alias; the app suggests
  that host name for an IP.

## App

- Liquid Glass needs macOS 26; below, `glassCard` and `glassButton` use materials.
  Minimum macOS 14 for `buttonBorderShape(.circle)` and `ContentUnavailableView`.
- Address checks (`getaddrinfo`, `getnameinfo`) block, so they run detached, debounced
  500 ms, cancelled by `.task(id:)`.
- Toolbar switches use `.controlSize(.mini)`; the regular size looked oversized.
- The toolbar hides a switch's label, so a second switch there ("At Login") looked
  identical to "Automatic". A labelled switch in the status bar followed and was dropped
  again: the login settings live in Settings and the menu bar menu.
- "Open at Login" was read as "open the window at login". It is now Run at Login, with
  Show Window at Login as a separate setting.
- The window sizes to its content (`.contentSize`, `onGeometryChange`, `visibleShares`).
- Inserting the log panel made the window jump while the view animated. The panel stays
  in the tree and only its clipped container height animates.
- `.commands` has no `openWindow`, so the menu is a separate `Commands` struct.
- `Window`, not `WindowGroup`: ⌘N opened windows with their own `Model` that overwrote
  each other's `shares.conf`.
- The `Model` belongs to the app so `MenuBarExtra` works without a window.
- Without a window the app switches to `.accessory`. `LSUIElement` would also remove the
  menus.
- Login item: `SMAppService.mainApp`; a login launch is detected by
  `keyAELaunchedAsLogInItem` and closes the window.
- `NSLocalNetworkUsageDescription` is needed because `nc` probes the local network
  (macOS 15).
- Updates read `MountwellUpdateRepo` from `Info.plist`. The anonymous API allows 60
  requests per hour and returns 404 for private repositories.
- `URLSession` downloads carry no quarantine, so Installer opens the package without
  Gatekeeper. Anyone who can publish releases could ship root code, so a build with
  `TEAM_ID` runs `pkgutil --check-signature` and requires a Developer ID Installer
  certificate whose name ends in that team ID. Older certificates without the team ID
  in the name (XQuartz 2.7.8, 2015) are rejected. A build without `TEAM_ID`, such as
  0.0.3, installs any package.
- The cached package is always `Mountwell-Update.pkg`; a version from the network does
  not belong in a path.

## CI and releases

- No repo-infra piece builds Swift, so `ci-local.yml` and `release-build-local.yml` do.
- `macos-26` runners provide the Liquid Glass SDK; Intel is cross-compiled with
  `-target x86_64-apple-macos14.0`.
- `build.sh` reads `VERSION` unless the environment sets it.
- Releases from tags with `--generate-notes` had empty notes, shown as raw Markdown.
  Notes now come from `CHANGES.md`; `plainNotes` strips the Markdown.

## Screenshot

- `tools/screenshot.sh` renders `ContentView` with `Model(live: false)` and example
  shares. `-D SCREENSHOT` drops `@main`.
- An offscreen capture misses Liquid Glass, so `SCREENSHOT` builds use a light fill.
- `screencapture -l` needs Screen Recording and would show the real configuration.

## Tests

- The script stubs work only because the script calls tools without a path.
- `HOME` is a temporary directory.
- Counter-check: replace `diskutil unmount force` by `true` (`MOUNTWELL_SCRIPT=…`) and the
  forced-unmount tests fail.

## Open

- A real VPN or Wi-Fi disconnect has not been observed, only simulated.
- No real update from one version to the next has been tested.
- Signing and notarization have not run yet; no certificates existed when they were
  added.
