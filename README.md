# Mountwell

Mounts SMB shares on macOS automatically **while the file server is reachable**
(office network or VPN up) and **unmounts them as soon as it is not**. Finder never
hangs on dead connections, and after starting the VPN the drives are simply there.

Mountwell ships as an installer package with a small app for configuration. The app
appears in the language the Mac is set to (English or German).

The predecessor was called "SMB Automount". The package removes its installation and
takes over its configuration and log.

## How it works

A LaunchAgent (`ch.oetiker.mountwell`) runs the script `mountwell` for every
logged-in user

- on every network change (`WatchPaths` on `/Library/Preferences/SystemConfiguration`),
- additionally every 60 seconds (for VPN clients that do not write the system configuration),
- once at login.

For each configured share the script checks:

| Server reachable on port 445? | Mounted? | Action |
|---|---|---|
| yes | no  | mount (`osascript … mount volume`, password from the keychain) |
| yes | yes | nothing |
| no (3 attempts, 5 s apart) | yes | unmount (`diskutil unmount force`) |
| no  | no  | nothing |

A share ejected by hand in the app is not mounted again until you mount it again or the
server goes out of reach (see *Eject* below).

If the file server's name points to an internal address (e.g. 192.168.10.20), it is only
reachable in the office network or over VPN. Reachability is therefore the only
criterion; there are no Wi-Fi names to maintain.

## Installing on a Mac

1. Double-click `Mountwell-<version>.pkg`, or in Terminal:
   `sudo installer -pkg Mountwell-0.0.1.pkg -target /`
2. The package is not signed with a Developer ID, so Gatekeeper blocks a double-click:
   click **Open Anyway** in *System Settings → Privacy & Security*.
   `sudo installer` does not ask.
3. The first time, the app opens automatically. Add shares, e.g.
   `smb://fileserver.example.com/team`, and click **Save**.
4. Press the **link button** once per share: Finder connects and asks for the password.
   Choose **Remember this password in my keychain**. Otherwise the background service
   cannot mount without asking.

The package installs:

- `/Applications/Mountwell.app`: the app, which also contains the script
  (`Contents/Resources/mountwell`) and `uninstall.sh`
- `/Library/LaunchAgents/ch.oetiker.mountwell.plist`: the service, for all users

An installation of SMB Automount (`/Applications/SMB Automount.app`, including the first
single-user version in `~/Library/LaunchAgents/…` and `~/.local/bin/smb-automount`)
is removed automatically.

## The app

The app shows an icon in the menu bar: shares with their status, the switch
*Mount Automatically*, *Check Now*, *Open at Login* and *Quit*. When the window is
closed, the app leaves the Dock and keeps running there. With *Open at Login* it starts
quietly after login, without a window. Mounting is done by the background service, even
when the app is not running.

- **Automatic**: switches the service on or off for this user
  (creates or removes `~/.config/mountwell/disabled`)
- **Background service running / not loaded**: whether the LaunchAgent runs; *Load* starts it
- **Shares** with a status icon: green = mounted, orange = reachable but not mounted,
  gray = server unreachable or ejected by hand
- **Eject** (button on a mounted share, context menu, or the share's submenu in the menu
  bar): unmounts the share and records it in `~/.config/mountwell/ejected`. The background
  service then leaves it alone until it is mounted again (**Mount** button, menu, or by
  hand in Finder) or the server goes out of reach, e.g. when you leave the office network.
  Ejecting in Finder alone does not stick: the service mounts the share again within a
  minute.
- **Only in networks**: optional restriction to IP prefixes, e.g. `10.46.,192.168.1.`.
  Empty means: always mount when the server is reachable. In another network the share is
  unmounted, but not forced while the server responds: if files are open, the share stays
  mounted and the log says so.
- **Remove** asks first. A mounted share stays mounted until it is ejected in Finder.
- **Save** writes the configuration and runs a check right away
- The window is as tall as the shares need, up to four; with more, the list scrolls.
- **Log**: the latest entries, newest first. Hidden by default; show and hide it via
  *View → Show Log* (⌘L). The app remembers the setting.
- **Checks while editing**: the app resolves the server name, shows the IP address and
  whether the SMB port responds, and helps with common mistakes: converting a Windows path
  (`\\server\share`), short names without a domain, names that do not resolve (VPN not up?),
  `.local` names, an IP address instead of a name (suggests the DNS name) and a private IP
  without a network restriction.
- **Help** (⌘? or `?` in the toolbar): explains the address format, DNS name vs. IP address
  and troubleshooting.
- **About Mountwell**: short description; version and "Created by Manuel Oetiker" are also
  shown in the status bar.
- Liquid Glass look on macOS 26, material effects on macOS 14/15. Follows the system's
  light and dark mode.

## Updates

At launch and then daily, the app queries the GitHub releases
(`https://api.github.com/repos/<REPO>/releases/latest`). If there is a newer version with
a `.pkg` file, *Install Update …* appears in the menu bar and in the window's status bar.
*Check for Updates…* in the app menu or the menu bar checks right away. The app downloads
the package to `~/Library/Caches/ch.oetiker.mountwell/` and opens it in Installer, which
asks for an administrator password. The package quits the app and relaunches it afterwards.

Publishing a new version: push a tag, GitHub Actions does the rest.

```sh
git tag v0.0.3 && git push origin v0.0.3
```

The workflow tests and builds the package with the version from the tag, then creates
the release with the package attached and notes generated from the commits since the
previous release. The notes appear in the update dialog and can be edited on GitHub
afterwards. The repository must be public.

## Configuration (per user)

`~/.config/mountwell/shares.conf`, one share per line. The app writes this file, but it
can also be edited by hand:

```
smb://[user@]server/share   [optional IP prefixes, comma-separated]
```

Example:

```
smb://fileserver.example.com/team
smb://fileserver.example.com/photos
smb://nas.local/backup 192.168.1.
```

Without a configuration the service does nothing.

`~/.config/mountwell/ejected` lists shares ejected by hand (`server/share`, one per line).
The app maintains it; the script removes entries once the share is mounted again or the
server is out of reach.

## Checking on it

```sh
tail -f ~/Library/Logs/mountwell.log
launchctl print gui/$(id -u)/ch.oetiker.mountwell | grep -E 'runs|last exit'
mount -t smbfs
"/Applications/Mountwell.app/Contents/Resources/mountwell" --now   # run right away
```

Only mount and unmount actions are logged. An empty log means there was nothing to do.

## Uninstalling

```sh
sudo "/Applications/Mountwell.app/Contents/Resources/uninstall.sh"
```

Removes the app and the service. The configuration in `~/.config/mountwell` is kept.

## Continuous integration

`.github/workflows/build.yml` runs on GitHub Actions (`macos-26` runner, Xcode 26):

| Trigger | What happens |
|---|---|
| pull request | tests and build; the package is attached to the run as an artifact |
| push to `main` | the same, so `main` always builds |
| tag `v*` | build with the tag's version, then publish the GitHub release |

Builds that are not releases get version `0.0.0`, so an installed CI build always offers
the latest release as an update.

## Building the package

Requires Xcode (or the Command Line Tools) with the macOS SDK.

```sh
./build.sh                      # → build/Mountwell-0.0.1.pkg
VERSION=0.0.2 ./build.sh        # different version number
REPO=owner/repo ./build.sh      # different GitHub repository for updates
```

The package contains a Universal app (Apple silicon and Intel) and runs on macOS 14 and
later. The app is only ad-hoc signed. Distribution without a Gatekeeper prompt would need
an Apple Developer account (Developer ID Application/Installer) and notarization.

## Translations

English is the development language: the texts in the code are English.
`app/de.lproj/Localizable.strings` holds the German translation, keyed by the English text,
and `app/de.lproj/InfoPlist.strings` the German texts from `Info.plist`. A new UI text needs
an entry there in the same change. Another language is a new `<code>.lproj` folder plus the
code in `CFBundleLocalizations` in `app/Info.plist`.

## Tests

```sh
tests/run.sh
```

- `tests/main.swift`: the app logic (`app/Core.swift`): address parsing, converting Windows
  paths, detecting IP addresses and private networks, name resolution, version comparison
  and reading GitHub releases. With
  `MOUNTWELL_TEST_SERVER=fileserver.example.com tests/run.sh` a real internal server is
  checked as well, provided it resolves (office network/VPN).
- `tests/test-mountwell.sh`: the mount script with stubs for `nc`, `mount`, `osascript`,
  `diskutil` and `ifconfig`. Covers all cases (mount, unmount, short dropouts, wrong network,
  open files, disabled, ejected by hand, comments, several shares, similar names, taking
  over the predecessor's configuration) without a network and without real mounts.

`build.sh` runs the tests before packaging and stops on failure.

## Project layout

| File | Purpose |
|---|---|
| `mountwell.sh` | the actual script |
| `app/Mountwell.swift` | configuration app (SwiftUI) |
| `app/Core.swift` | logic without UI (addresses, name resolution, updates) |
| `app/Info.plist` | app metadata (`@VERSION@` and `@REPO@` are filled in at build time) |
| `app/de.lproj/` | German translation |
| `app/make-icon.swift` | draws the app icon |
| `pkg/ch.oetiker.mountwell.plist` | LaunchAgent |
| `pkg/scripts/preinstall`, `postinstall` | unload the service and quit the app, then load it for logged-in users |
| `uninstall.sh` | uninstaller |
| `build.sh` | tests and builds the app and the package |
| `tests/` | tests, see above |
| `docs/spec.md` | what Mountwell must do, numbered requirements |
| `docs/programming-guide.md` | how to work on the code: architecture, conventions, translation, tests, releases |
| `docs/maintainer-notes.md` | pitfalls and the reasons behind decisions |

## License

MIT, see [LICENSE](LICENSE). © 2026 Manuel Oetiker
