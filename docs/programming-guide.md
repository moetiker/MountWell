# Programming guide

Requirements are in `docs/spec.md`, reasons and pitfalls in `docs/maintainer-notes.md`.
Read the notes before changing the build, the package scripts or the mount script.

## Setup

macOS 14 or later with Xcode 26 or its Command Line Tools (the macOS 26 SDK provides
Liquid Glass). No Xcode project and no dependencies.

```sh
tests/run.sh            # all tests
./build.sh              # tests, then build/MountWell-<VERSION>.pkg
VERSION=0.0.9 ./build.sh
tools/screenshot.sh     # renders docs/screenshot.png from example shares
```

Signing: with "Developer ID Application" and "Developer ID Installer" in the keychain
and a notarization profile, `./build.sh` signs and notarizes by itself:

```sh
xcrun notarytool store-credentials mountwell --key <AuthKey.p8> --key-id <id> --issuer <uuid>
./build.sh              # "signature: signed by a developer certificate …"
SIGN_APP= SIGN_PKG= TEAM_ID= ./build.sh   # unsigned, as without certificates
```

## Architecture

- `mountwell.sh`: run by launchd, does all automatic mounting.
- `app/Core.swift`: logic without UI (parsing, name resolution, mount table matching,
  versions, releases). Testable logic goes here.
- `app/Model.swift`: the state behind window and menu bar; reads and writes the files
  in `~/.config/mountwell/` under the script's lock. Mounts only on explicit Mount and
  Eject.
- `app/MountWell.swift`: paths, entry point, menu commands, app delegate.
- `app/MainWindow.swift`, `ShareEditor.swift`, `Import.swift`, `Help.swift`,
  `MenuBar.swift`, `Glass.swift`: the views, one file per window or menu.
- `app/Updater.swift`: update check and install (U-1 to U-4).
- `app/smb-id/`: prints a server's SMB ServerGuid for the script (M-12).
- `app/install-update.sh`: checks and installs a signed update as root (U-4).
- `app/de.lproj/`: German translation.

App and script talk through the files in `~/.config/mountwell/` (spec section 3). A new
setting is a new file or line format, documented in the spec and the script header.

## Conventions

- Everything is English (spec L-2); only UI texts are translated (spec L-1).
- Swift 5 language mode, no new warnings, no third-party code.
- Blocking work runs in `Task.detached`, never on the main actor.
- External programs run through `run(_:_:)` in `Core.swift` with absolute paths.
- Bash must work with bash 3.2 and `set -u`; quote every expansion.
- The script calls `nc`, `mount`, `osascript`, `diskutil`, `umount` and `ifconfig`
  without a path, so the tests can stub them.
- Log lines use `mounting`, `unmounting` or `failed`; `LogPanel` picks icons from them.
- Package scripts run as root: no predictable files in `/tmp`, use `/var/run`.

## Translation

- Visible text is a literal in `Text`, `Button`, `Label`, `.help`, `Toggle` or
  `String(localized:)`. A `String` parameter is not translated; use `LocalizedStringKey`
  or `Text` (see `Tag`, `Hint`). `Text(verbatim:)` for URLs, version, author.
- Add the German text to `app/de.lproj/Localizable.strings` and run `plutil -lint` on it.
  Key format: see the maintainer notes.
- German: "du", Swiss spelling (ss), Apple's terms (Sichern, Abbrechen, Schlüsselbund),
  a space before "…".
- Check by hand: `defaults write ch.oetiker.mountwell.app AppleLanguages '("de")'`.

## Tests

- `tests/main.swift`: `check(got, expected, "name")` for `Core.swift`.
- `tests/test-mountwell.sh`: `setup <conf> <reachable> <mounts>`, `runit`,
  `expect <name> <line> [grep|nogrep]`. Stubs read `reachable`, `mounts`, `flaky`, `busy`
  and log to `calls`.
- Every change to `Core.swift` or the script comes with a test that fails without it.
- Real server, optional: `MOUNTWELL_TEST_SERVER=<name> tests/run.sh`.
- The UI is tested by hand; say what you checked in the pull request.

## Workflow and releases

- `main` takes pull requests only, with green `ci-passed` and a `CHANGES.md` entry
  (`### New`, `### Changed`, `### Fixed`) or the label `no-changelog` set at creation.
- Commit messages: English, imperative subject under 70 characters, body says why.
- No real host names, IPs or user names (spec B-5). Use `fileserver.example.com`,
  `192.168.10.20`, `anna`.
- Release: Actions → **Create release PR** (bugfix, feature, major), then merge the
  release pull request. Never move or reuse a tag; re-run a failed publish with
  **Re-run failed jobs**.

## Easy to break

- `pkg/scripts/*`: test an install over a running app and on a fresh Mac.
- The LaunchAgent label and paths appear in app, scripts, plist and uninstaller.
- `mountPoint(of:in:)` and `mountpoint_of` must match the same way.
- Regenerate the screenshot after visible changes, never from a real configuration.
- Anything with unbounded height in `ContentView` makes the window grow without limit.
