# Mountwell specification

What Mountwell must do. Issues, commits and tests refer to the numbers (for example
"M-4"). Reasons are in `docs/maintainer-notes.md`.

## 1. Purpose

Mountwell mounts SMB shares on macOS 14 or later while their server is reachable and
unmounts them when it is not, so Finder never hangs on a dead share.

Out of scope: AFP, NFS, WebDAV, password management (the keychain does that), server
configuration, the Mac App Store.

## 2. Mounting (background service)

- **M-1** A per-user service runs at login, on every network change and every 60 seconds,
  whether the app runs or not.
- **M-2** A configured share whose server answers on TCP 445 is mounted with the keychain
  password, without a dialog.
- **M-3** A mounted share whose server fails three checks 5 seconds apart is unmounted with
  force. One failed check does nothing.
- **M-4** A share may be limited to IP prefixes. It is mounted only while one of the Mac's
  IPv4 addresses starts with one of them. Empty entries in the list are ignored; a list
  of only empty entries means no limit.
- **M-5** Outside those networks a mounted share is unmounted without force while its
  server answers; if files are open it stays and the next run retries. If the server does
  not answer, unmount with force.
- **M-6** A share ejected in the app (A-6) is not remounted until it is mounted again by
  any means, its server is unreachable or the network does not match M-4.
- **M-7** A share is mounted only if the mount table lists exactly its `server/share`,
  case-insensitive. `example.com/x` does not match `fileserver.example.com/x`, `share`
  does not match `share-old`.
- **M-8** With automatic mounting off (A-3) the service does nothing.
- **M-9** Without a configuration the service does nothing and exits 0.
- **M-10** Mounts, unmounts and failures are logged with a timestamp, in English, to
  `~/Library/Logs/mountwell.log`. Runs without an action log nothing.
- **M-11** After a network change the service waits 3 seconds. Runs from the app do not.
- **M-12** While a server name resolves, the service remembers its IPv4 address, the
  network it is reached through (the /24 prefix of the Mac's own address on that
  interface and the MAC address of that interface's router, none over VPN) and the
  server's SMB2 ServerGuid (C-5). Only a server that answers with its ID is remembered.
  A name keeps one entry per network: an entry learned at home does not replace the
  office's.
- **M-13** When the name does not resolve, the service uses the remembered address for
  reachability, mounting and unmounting: the entry whose address is reached through the
  network it was learned in, only while the keychain holds an SMB entry for it. Before mounting, the server at
  the address must report the remembered ID. A share mounted via the address counts as
  mounted (M-7 with the address as server).
- **M-14** A share configured by IP address is remembered on its first mount in each
  network. In a network it was seen in, it is mounted only if the same server ID answers;
  in a network it has not been seen in yet, it is not mounted automatically until it has
  been mounted there by hand once.
- **M-20** The URL reaches `mount volume` as an argument of `osascript`, never as part of
  the script text (also in the app, A-7).
- **M-17** A mounted share whose name does not resolve is checked (M-3) via its
  remembered address, whatever the network, so a short DNS outage does not unmount it.
- **M-18** A router MAC that cannot be read (empty ARP cache after a network change) is
  retried once after pinging the router. If it is still unknown, nothing is remembered and
  the remembered address is not used for mounting in that run.
- **M-19** Only one run at a time; a second run waits up to 30 seconds, then exits.
- **M-16** A switched-off share (C-1) is never mounted or unmounted, but while it is
  mounted by hand its server is remembered as in M-12 and M-14.
- **M-15** A refusal under M-13 or M-14 is logged once, not on every run.

## 3. Configuration

- **C-1** `~/.config/mountwell/shares.conf`, one share per line:
  `[!]smb://[user@]server/share [prefix,prefix,…] [# alias]`. Blank lines and lines
  starting with `#` are ignored. The service ignores the alias. A leading `!` disables
  the share: the service neither mounts nor unmounts it.
- **C-2** `~/.config/mountwell/disabled` exists ⇔ automatic mounting is off.
- **C-3** `~/.config/mountwell/ejected` lists ejected shares, one lower-case
  `server/share` per line. The app adds, the service removes (M-6).
- **C-4** Configuration and log of the predecessor "SMB Automount" are moved over unless
  Mountwell's already exist.
- **C-5** `~/.config/mountwell/servers.yaml`, written by the service: a list `servers`
  with `name`, `ip`, `network` (own /24 prefix), `router` (MAC, `-` over VPN), `server_id`
  and `seen`, all quoted strings; one entry per server name or configured IP. Entries
  missing a field are ignored. The app removes an entry on Forget Remembered Server.

## 4. App

- **A-1** The window lists shares with name, server, status (mounted, reachable,
  unreachable, ejected, checking, off) and network limits, refreshed every 10 seconds while
  a window is open and every minute otherwise. Servers of mounted shares are not probed.
  A remembered address (C-5) shows next to the server, with a crossed-out key while the
  keychain has no entry for it; the context menu then offers to connect via the address
  and to forget the remembered server.
  A spinner on the icon shows while the share is mounted or ejected, and while the probe of
  an unmounted share that is on takes longer than half a second.
- **A-2** Shares can be added, edited and removed (with confirmation; a mounted share stays
  mounted). Saving writes the configuration and checks at once.
- **A-3** A switch turns automatic mounting on and off.
- **A-4** While an address is typed, the app checks it without blocking and helps with:
  wrong format (converts `\\server\share` and `server/share`), unresolvable names, short
  names (suggests the search domain), `.local` names, IP addresses (suggests the DNS
  name), private IPs without a limit (suggests the /24) and whether port 445 answers.
- **A-5** A button opens the share in Finder, to save the password in the keychain once.
- **A-6** A mounted share can be ejected from its card, context menu and the menu bar. The
  eject is recorded (C-3), then unmounted without force; on failure the record is removed
  and the user is told files may be open.
- **A-7** A reachable share can be mounted at once, also with automatic mounting off. This
  forgets an earlier eject.
- **A-8** The window shows whether the service is loaded and can load it.
- **A-9** The window fits up to four shares, then scrolls. A log drawer (latest 50
  entries, newest first) opens with View → Show Log (⌘L) and is remembered.
- **A-10** A menu bar icon shows the overall state. Its menu lists each share by its alias,
  or else as `server/share`, and offers per share Show in Finder, Eject or Mount, plus
  a per-share Mount Automatically switch (A-17), plus Mount Automatically, Check Now,
  Import Mounted Shares (A-18), Open Mountwell, Run at Login, Show Window at Login,
  Check for Updates and Quit.
- **A-11** Closing the window removes the Dock icon; the menu bar icon stays. Started as
  a login item, the app shows no window unless Show Window at Login is on or no share is
  configured yet. Started by hand, it always shows the window.
- **A-12** Help (⌘?) covers address format, DNS names vs. IPs, troubleshooting, network
  limits, aliases, importing, switching shares off, the DNS fallback, ejecting, the
  keychain and starting at login.
- **A-13** There is only one main window.
- **A-14** Liquid Glass on macOS 26, materials on macOS 14 and 15; light and dark mode.
- **A-15** Settings (⌘,) and the menu bar menu offer Run at Login (start the app at
  login) and Show Window at Login (off by default; only with Run at Login).
- **A-16** A share may have an alias (C-1). Window and menu show it instead of the share
  name; the card then shows `server/share` below it.
- **A-17** Each share has a Mount Automatically setting (context menu, editor, menu bar)
  that turns it off without removing it (C-1). The card then shows "Off" and is dimmed.
  Mounting and ejecting by hand still work.
- **A-18** Import Mounted Shares (menu bar menu, empty window) reads `mount -t smbfs`
  and proposes every mounted share that is not configured. The address keeps the user
  name and drops a password; no network limit is set.
  Address, limit and alias can be changed and each proposal deselected before import.

## 5. Language

- **L-1** The UI follows the Mac's language: English or German. Every visible text is
  translated, including the local network prompt.
- **L-2** Everything else is English: code, log, tests, docs, commits, releases.

## 6. Installation and removal

- **I-1** A Universal installer package for macOS 14 or later installs
  `/Applications/Mountwell.app` and the system-wide LaunchAgent `ch.oetiker.mountwell`.
- **I-2** Installing loads the service for all logged-in users and opens the app for users
  without a configuration.
- **I-7** Installing acts only on logged-in users with a uid of 501 or more, not on the
  login window's root session.
- **I-3** Installing over a running app quits and relaunches it.
- **I-4** Installing removes SMB Automount and takes over its configuration (C-4).
- **I-5** An uninstaller in the app bundle removes app and service, keeps the
  configuration.
- **I-6** Login Items in System Settings show the service as Mountwell.

## 7. Updates

- **U-1** The app checks the latest GitHub release at launch and every 24 hours. Automatic
  checks stay silent unless there is an update.
- **U-2** A release is an update if its tag (without `v`) is numerically newer and it has a
  `.pkg` asset.
- **U-3** The update shows in the menu bar and status bar. It installs only after the user
  confirms the dialog (version, notes) and enters the administrator password.
- **U-4** The package is downloaded over HTTPS under a fixed name. If the app was built
  with a team ID (`TEAM_ID`), `install-update` runs as root (after the administrator
  password): it copies the package into a directory only root can write, checks there
  that it carries a trusted Developer ID Installer signature of that team, and installs
  that copy. A package that fails the check is deleted and not installed. Without a team
  ID the package opens in Installer and the update dialog says that it cannot be checked.

## 8. Build, CI and release

- **B-1** `./build.sh` runs the tests and only then builds app and package. `VERSION`,
  `REPO` and `TEAM_ID` can come from the environment.
- **B-2** Every pull request and push to `main` is tested and built on `macos-26`;
  `ci-passed` sums it up.
- **B-3** *Create release PR* bumps `VERSION`, moves `[Unreleased]` in `CHANGES.md` under
  the new version and opens a pull request. Merging it tags and publishes the release
  with the package and that section as notes.
- **B-4** The repository is public, MIT licensed; the license ships in the app.
- **B-5** Nothing in the repository identifies the author's systems or networks.
- **B-6** `main` takes pull requests with green `ci-passed` and a `CHANGES.md` entry or
  the label `no-changelog`.
- **B-7** The setup follows the repo-infra standard; `repo_infra check` reports drift.
- **B-8** With Developer ID certificates in the keychain, `./build.sh` signs the app
  (hardened runtime) and the package, notarizes and staples it, and sets `TEAM_ID` from
  the installer certificate. Without them it builds unsigned. A release build with the
  signing secrets fails rather than ship an unsigned package, and so does one without
  them once the repository variable `REQUIRE_SIGNED_RELEASES` is `1`. A signed release
  package is checked (signature, Gatekeeper, stapled ticket, team ID in the app) before it
  is uploaded. `TEAM_ID` must be 10 upper-case letters and digits.

## 9. Known limits

- An unsigned build (no Developer ID certificates) needs "Open Anyway" the first time.
  Releases from 0.3.1 on are signed; installs of 0.3.0 and earlier take the first signed
  update without a signature check, since they have no team ID to check against.
- An eject in Finder is not remembered; the service mounts the share again.
- Hanging DNS lookups are not bounded by the 2-second timeout.
- The UI is not tested automatically.
