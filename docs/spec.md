# Mountwell specification

What Mountwell must do. Requirements are numbered so issues, commits and tests can refer
to them (e.g. "M-4"). The reasons behind individual decisions are in
`docs/maintainer-notes.md`; how to work on the code is in `docs/programming-guide.md`.

## 1. Purpose

Mountwell mounts SMB shares on macOS while their file server is reachable and unmounts
them when it is not. A user who moves between the office network, VPN, home and other
networks never sees Finder hang on a dead share and never mounts drives by hand.

**Users:** people on macOS 14 or later who use SMB shares from one or more file servers
that are only reachable in certain networks.

**Out of scope:** other protocols (AFP, NFS, WebDAV), storing or managing passwords
(macOS keychain does that), server-side configuration, the Mac App Store.

## 2. Mounting (background service)

- **M-1** A per-user background service runs on every network change, every 60 seconds
  and once at login, for every logged-in user, whether or not the app is running.
- **M-2** For each configured share: if the server answers on TCP port 445 and the share is
  not mounted, mount it with the password from the user's keychain, without a dialog.
- **M-3** If a mounted share's server does not answer three times, 5 seconds apart, unmount
  it with force. A single failed attempt must not unmount a share.
- **M-4** A share may be restricted to networks, given as IP prefixes. It is mounted only
  while one of the Mac's own IPv4 addresses starts with one of the prefixes.
- **M-5** In a network that does not match M-4, a mounted share is unmounted without force
  while its server still answers. If that fails (open files), it stays mounted and the
  failure is logged; the next run tries again. If the server does not answer, unmount with
  force.
- **M-6** A share ejected by hand in the app (A-6) is not mounted again until it is mounted
  again (by the app, Finder or by hand) or its server is out of reach or the network does
  not match M-4. Then the eject is forgotten and M-2 applies again.
- **M-7** A share counts as mounted only if the mount table lists exactly its
  `server/share`, compared case-insensitively. `example.com/x` must not match
  `fileserver.example.com/x`, and `share` must not match `share-old`.
- **M-8** When automatic mounting is switched off (A-3), the service does nothing.
- **M-9** Without a configuration the service does nothing and exits successfully.
- **M-10** Every mount, unmount and failure is logged with a timestamp to
  `~/Library/Logs/mountwell.log`, in English. Runs without an action log nothing.
- **M-11** After a network change the service waits 3 seconds before checking, so DHCP and
  DNS can settle. Runs started from the app skip the wait.

## 3. Configuration

- **C-1** Per user, in `~/.config/mountwell/shares.conf`, one share per line:
  `smb://[user@]server/share [prefix,prefix,…]`. Blank lines and lines starting with `#`
  are ignored. The file stays editable by hand.
- **C-2** `~/.config/mountwell/disabled` exists ⇔ automatic mounting is off.
- **C-3** `~/.config/mountwell/ejected` lists shares ejected by hand, one `server/share` per
  line in lower case. The app adds entries, the service removes them (M-6).
- **C-4** On first run, configuration and log of the predecessor "SMB Automount"
  (`~/.config/smb-automount`, `~/Library/Logs/smb-automount.log`) are moved over, unless
  Mountwell's own already exist.

## 4. App

- **A-1** The main window lists the shares with name, server, status (mounted, reachable,
  unreachable, ejected, checking) and network restrictions. Status refreshes every 10
  seconds.
- **A-2** Shares can be added, edited and removed. Removing asks for confirmation; a
  mounted share stays mounted. Saving writes the configuration and runs a check at once.
- **A-3** A switch turns automatic mounting on and off for the current user.
- **A-4** While an address is edited, the app checks it and helps with: wrong format
  (offers to convert `\\server\share` and `server/share`), names that do not resolve,
  short names without a domain (suggests the full name using the Mac's search domain),
  `.local` names, IP addresses (offers the DNS name from a reverse lookup), private IPs
  without a network restriction (offers the /24 prefix), and whether port 445 answers. The
  check must not block typing.
- **A-5** A button per share opens the share in Finder, so the user can save the password
  in the keychain once.
- **A-6** A mounted share can be ejected from its card, its context menu and the menu bar.
  The eject is recorded (C-3) before unmounting without force. If unmounting fails, the
  record is removed and the user is told that files may be open.
- **A-7** A reachable, unmounted share can be mounted right away, also when automatic
  mounting is off. This forgets an earlier eject.
- **A-8** The window shows whether the background service is loaded and can load it.
- **A-9** The window is exactly as tall as the share list needs, for up to four shares;
  with more, the list scrolls. A log panel (latest 50 entries, newest first) opens and
  closes like a drawer via View → Show Log (⌘L); the window grows and shrinks with it.
  The setting is remembered.
- **A-10** A menu bar icon shows the overall state and offers, per share, Show in Finder,
  Eject or Mount, plus Mount Automatically, Check Now, Open Mountwell, Open at Login,
  Check for Updates and Quit.
- **A-11** Closing the window removes the Dock icon; the menu bar icon stays. Opening the
  app again brings the window back. Started as a login item, the app shows no window.
- **A-12** Help (⌘?) explains the address format, DNS names vs. IP addresses,
  troubleshooting, network restrictions, ejecting and the keychain.
- **A-13** Only one main window exists.
- **A-14** Liquid Glass on macOS 26, material effects on macOS 14/15; light and dark mode.

## 5. Language

- **L-1** The UI appears in the language the Mac is set to: English (development language)
  or German. Every visible text, including hints, tags, dialogs, menus, help and the
  local network permission prompt, is translated.
- **L-2** Everything else is English: code, comments, log, scripts, tests, documentation,
  commit messages, release notes, the GitHub repository.

## 6. Installation and removal

- **I-1** Distribution is an installer package for macOS 14 or later, Universal (Apple
  silicon and Intel), installing `/Applications/Mountwell.app` and a system-wide
  LaunchAgent `ch.oetiker.mountwell`.
- **I-2** Installing loads the service for all logged-in users and opens the app for users
  without a configuration.
- **I-3** Installing over a running Mountwell quits it first and relaunches it afterwards.
- **I-4** Installing removes the predecessor SMB Automount (system-wide and single-user
  variants) and takes over its configuration (C-4).
- **I-5** An uninstaller in the app bundle removes app and service and keeps the
  configuration.
- **I-6** In System Settings → Login Items the service appears as Mountwell.

## 7. Updates

- **U-1** At launch and then every 24 hours, the app checks the latest release of the
  GitHub repository built into the app. A check from the menu also reports "up to date"
  and errors; automatic checks stay silent unless there is an update.
- **U-2** A release counts as an update if its version (the tag without a leading `v`) is
  numerically newer than the installed one and it has a `.pkg` asset.
- **U-3** An available update is shown in the menu bar and the window's status bar. The
  user confirms in a dialog showing version and release notes; nothing installs
  without that confirmation and the administrator password.
- **U-4** The package is downloaded over HTTPS to the user's cache under a fixed name and
  opened in Installer. It is trusted because it comes from the GitHub repository; there
  is no signature check (see section 9).

## 8. Build, CI and release

- **B-1** `./build.sh` runs all tests and, only if they pass, builds the Universal app and
  the package. `VERSION` and `REPO` can be set from the environment.
- **B-2** GitHub Actions (`.github/workflows/build.yml`, macOS 26 runner) tests and builds
  every pull request and every push to `main` and attaches the package to the run. These
  builds have version `0.0.0`.
- **B-3** Pushing a tag `v<version>` builds that version and publishes the GitHub release
  with the package. The version comes only from the tag.
- **B-4** The repository is public and is released under the MIT license, which also ships
  inside the app bundle.
- **B-5** Nothing in the repository identifies the author's systems or networks; examples
  use `example.com` and documentation addresses.

## 9. Non-goals and known limits

- The package and app are not signed with a Developer ID and not notarized. The first
  installation of a downloaded package needs "Open Anyway". Signing is a separate,
  optional step (needs an Apple Developer Program membership).
- Ejecting in Finder alone is not remembered; the service mounts the share again (M-6
  covers ejecting from the app only).
- Hanging DNS lookups are not bounded by the 2-second connection timeout.
- The UI is not tested automatically.

## 10. Open questions

- **Q-1 Release notes.** With `--generate-notes` and direct pushes to `main`, GitHub lists
  no changes (it only lists merged pull requests), and the update dialog shows the raw
  Markdown link to the comparison. Proposed: write the notes in an annotated tag
  (`git tag -a v0.0.3 -m "…"`), publish them with `--notes-from-tag`, and fail the
  release if the tag has no message. Undecided.
