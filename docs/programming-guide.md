# Programming guide

How to work on Mountwell. What the software must do is in `docs/spec.md`; why things are
the way they are, and what went wrong before, is in `docs/maintainer-notes.md`. Read the
notes before changing the build, the package scripts or the mount script.

## Setup

- macOS 14 or later with Xcode 26 (or its Command Line Tools). The macOS 26 SDK is needed
  for the Liquid Glass APIs; the app still runs on macOS 14.
- No Xcode project, no package manager, no dependencies. Everything is built with
  `swiftc`, `lipo`, `pkgbuild` and `productbuild`.

```sh
tests/run.sh          # all tests, takes seconds
./build.sh            # tests, then build/Mountwell-<version from VERSION>.pkg
VERSION=0.0.9 ./build.sh
tools/screenshot.sh   # renders docs/screenshot.png with example shares
```

Install a local build with `open build/Mountwell-<version>.pkg`. A local build carries the
version of the latest release, so the app does not offer that release as an update.

## Architecture

```
LaunchAgent (launchd, per user)          Mountwell.app (SwiftUI)
  └─ Resources/mountwell (bash)            ├─ Core.swift      logic, no UI, tested
       reads   ~/.config/mountwell/*       ├─ Mountwell.swift UI, model, updater
       writes  ~/Library/Logs/mountwell.log└─ de.lproj        German translation
```

- **The script does the mounting.** `mountwell.sh` runs from launchd whether the app runs
  or not. Mounting logic belongs there, not in the app.
- **The app edits files and shows state.** It writes `shares.conf`, `disabled` and
  `ejected`, reads the mount table and the log, and runs the script with `--now`. The
  only mounting it does itself is the explicit Mount and Eject actions.
- **Files are the interface** between app and script (spec section 3). A new setting is a
  new line format or file there, documented in the spec and the script header.
- **`Core.swift` holds everything testable without UI**: parsing, name resolution, mount
  table matching, version comparison, release parsing. If logic in `Mountwell.swift` can
  be tested, move it to `Core.swift` and test it.

## Conventions

### Language

- All code, comments, identifiers, log messages, test names, docs and commit messages are
  English (spec L-2).
- UI texts are English in the code and translated in `app/de.lproj/Localizable.strings`.

### Swift

- Swift 5 language mode (`-swift-version 5`); the code must also build without new
  warnings.
- Match the existing style: small structs, no third-party code, comments only where the
  reason is not obvious from the code.
- Blocking work (processes, DNS, `nc`) never runs on the main actor; use
  `Task.detached` and hop back with `MainActor.run`.
- Run external programs through `run(_:_:)` in `Core.swift` with absolute paths.
- Paths and identifiers live in the constants at the top of `Mountwell.swift`.

### Bash (`mountwell.sh`, package scripts)

- Must work with the system bash 3.2. `set -u`; quote every expansion.
- Call `nc`, `mount`, `osascript`, `diskutil`, `umount` and `ifconfig` **without** an
  absolute path. The tests replace them with stubs via `PATH`.
- Log messages start with a verb in `-ing` form or describe a failure with `failed`;
  `LogPanel` in the app picks its icons from `mounting`, `unmounting` and `failed`.
- Package scripts run as root. Never write predictable files in `/tmp`; use `/var/run`.

## UI texts and translation

Every visible text must be translatable (spec L-1):

1. Write the English text as a literal in `Text("…")`, `Button("…")`, `Label("…", …)`,
   `.help("…")`, `Toggle("…", …)` or `String(localized: "…")` for AppKit APIs.
2. Never pass a visible text through a `String` parameter; it is shown untranslated. Use
   `LocalizedStringKey` or `Text` as the parameter type (see `Tag` and `Hint`).
3. Use `Text(verbatim:)` for text that must not be translated (URLs, version, author).
4. Add the German translation to `app/de.lproj/Localizable.strings`. The key is the
   English text with interpolations as `%@` (strings) or `%lld` (integers); for two
   integers use `%1$lld`/`%2$lld` in the German text.
5. Help texts are multi-line literals; their key is the text after indentation is
   stripped, lines joined with `\n`. Changing the English help text changes the key.
6. Check the file with `plutil -lint app/de.lproj/Localizable.strings`.

German style: "du", Swiss spelling (ss, not ß), Apple's German terms (Sichern, Abbrechen,
Schlüsselbund, Darstellung), a space before "…" in menu items ("Bearbeiten …").

A missing key falls back to English silently. Before a release, switch the Mac (or the
app via `defaults write ch.oetiker.mountwell.app AppleLanguages '("de")'`) to German and
click through every screen you touched.

## Tests

| What | Where | How |
|---|---|---|
| Core logic | `tests/main.swift` | `check(got, expected, "name")` |
| Mount script | `tests/test-mountwell.sh` | `setup <conf> <reachable hosts> <mount lines>`, `runit`, `expect <name> <line> [grep\|nogrep]` |

- Every change to `Core.swift` or `mountwell.sh` comes with a test that fails without it.
- Script stubs are controlled by files: `reachable` (hosts that answer), `mounts`
  (mount table), `flaky` (first n `nc` calls fail), `busy` (non-forced unmount fails).
  Calls are recorded in `calls`.
- Tests never touch the network or real mounts. `HOME` points to a temporary directory.
- Optional check against a real server: `MOUNTWELL_TEST_SERVER=<name> tests/run.sh`.
- The UI has no automated tests. Describe what you checked by hand in the pull request.

## Workflow

1. Branch from `main`; `main` is protected and takes pull requests only.
2. Change code, tests, translation and docs together: spec for behaviour, README for
   users, maintainer notes for non-obvious reasons and pitfalls.
3. `tests/run.sh` and `./build.sh` must pass. CI runs the same on every pull request and
   push to `main`; the pull request merges once `ci-passed` and `changelog-updated` are
   green. Add an entry to `CHANGES.md`, or the label `no-changelog` at creation for a
   change users do not notice (`gh pr create --label no-changelog`).
4. Commit messages: English, imperative subject line under ~70 characters, body explains
   why.
5. Never commit internal host names, IP addresses, user names or anything else about a
   real network (spec B-5). Use `fileserver.example.com`, `192.168.10.20`, `anna`.

## Releasing

1. Every user-visible change has its entry under `[Unreleased]` in `CHANGES.md`
   (`### New`, `### Changed`, `### Fixed`; never `### Added`, the release ignores it).
2. In GitHub Actions run **Create release PR** and pick bugfix, feature or major. It
   builds and tests the release branch and opens the release pull request.
3. Merge that pull request. Publishing tags it and makes the release public with
   `Mountwell-<version>.pkg`; installed apps offer it within 24 hours or at their next
   launch.

The version lives in `VERSION` and only the release changes it. Versions are numeric
`major.minor.patch`; `isNewer` compares them component by component. Never move or
reuse a published tag: installed apps may already have seen it. A failed publish is
re-run from the Actions page (**Re-run failed jobs**), never dispatched again.

## Things that are easy to break

- **Package scripts** (`pkg/scripts/*`) run as root on every user's Mac. Test an install
  over a running app and over a fresh Mac before releasing changes there.
- **The LaunchAgent label and paths** are referenced in the app, the scripts, the plist
  and the uninstaller. Change them everywhere or nowhere.
- **The mount table match** (`mountPoint(of:in:)` and `mountpoint_of`) must stay
  equivalent in Swift and bash.
- **The screenshot** shows example shares only. Regenerate it with `tools/screenshot.sh`
  after a visible change; never replace it with a capture of a real configuration.
- **`Info.plist` placeholders** `@VERSION@` and `@REPO@` are filled in by `build.sh`.
- **Window sizing**: the main window follows its content (`.contentSize`). Anything with
  an unbounded height in `ContentView` makes the window grow without limit.
