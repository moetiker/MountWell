# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
except that the first subsection is called `New` rather than `Added`. The release
workflow matches on `### New`; renaming it silently drops the section from the
release notes.

This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### New

### Changed
- Settings move from `~/.config/mountwell` to `~/Library/Application Support/MountWell`, where macOS apps keep them. The update moves them; nothing to do by hand.
- System Settings → General → Login Items shows the background service as MountWell with its developer instead of as from an unknown developer.

### Fixed
- Homebrew installs 0.4.0. Homebrew 7 loads the cask only after `brew trust moetiker/mountwell`; the README now says so.

## 0.4.0 - 2026-10-30
### New
- Install with Homebrew: `brew tap moetiker/mountwell https://github.com/moetiker/MountWell`, then `brew install --cask mountwell`.

### Changed
- Mountwell is now called MountWell: the app is `MountWell.app` and the package `MountWell-<version>.pkg`. The update replaces the old app; settings in `~/.config/mountwell` stay.

## 0.3.1 - 2026-10-30
### Changed
- Mountwell is signed with a Developer ID and notarized by Apple: the package opens without "Open Anyway". From this version on, Mountwell installs only updates signed by its developer, after the administrator password and without the Installer window.

## 0.3.0 - 2026-10-29
### New
- When a server name does not resolve, Mountwell mounts the share via the server's last known IP address. It does so only in the network where it learned the address (same address range and same router), only if the same server answers there and only once the password for that address is in the keychain. The window shows the address next to the server; right-click the share to "Connect via … in Finder" or "Forget Remembered Server".
- A share entered by IP address is tied to its server on the first mount; a different device at the same address in another network gets no login attempt. This also happens while "Mount Automatically" is off for the share and you connect to it yourself.

### Changed
- The update dialog says when this version of Mountwell cannot check who signed the update package.
- Once Mountwell releases are signed, an update installs after the administrator password without opening the Installer window, and only if it is signed by the developer of Mountwell.

### Fixed
- A share address containing `"` or `\` could run commands through AppleScript when it was mounted, from the app or the background service. Mounting now passes the address as an argument.
- A network list with an empty entry, for example `10.46.,,192.168.1.`, let the share mount in every network.
- A share whose folder in /Volumes contains " on " was unmounted at the wrong path and stayed mounted when its server was gone.
- Mounting one share showed the spinner on other shares too, and "Check Now" became clickable again while the check was still running.
- An eject could be forgotten when the background service ran at the same moment; the share was then mounted again.
- The last share in a hand-edited shares.conf without a final line break was ignored.
- Installing with nobody logged in, or for a user whose home folder name contains a space, acted on the wrong account.

## 0.2.0 - 2026-10-29
### New
- "Import Mounted Shares…" in the menu bar menu proposes the SMB shares that are mounted right now but not in Mountwell yet.
- A spinner on a share's icon shows while Mountwell mounts or ejects it, or takes a while to reach its server.
- "Mount Automatically" per share (context menu, edit window, menu bar) turns a share off without removing it; Mountwell then neither mounts nor unmounts it.

### Changed
- With no window open, Mountwell checks the state once a minute instead of every 10 seconds, and it no longer checks the servers of mounted shares.

## 0.1.0 - 2026-10-29
### New
- Settings (⌘,) with "Run at Login" and "Show Window at Login"; both are also in the menu bar menu.
- A share can have an alias, shown in the window and the menu instead of the share name.
- The menu bar menu shows each share by its alias, or else as server/share.
- Help explains aliases and starting at login.

### Changed
- "Open at Login" in the menu bar menu is now called "Run at Login".

## 0.0.3 - 2026-10-28
### Changed
- The window is as tall as the shares need, up to four; with more, the list scrolls.
- The log opens and closes like a drawer, and the window grows and shrinks with it.
- The update dialog shows release notes as plain text, without Markdown marks.

## 0.0.2 - 2026-10-28
### New
- Eject a share by hand from its card, its context menu or the menu bar. Mountwell leaves an ejected share alone until you mount it again or leave the network.
- Mount a reachable share right away, also when Automatic is off.

### Changed
- The Automatic switch in the toolbar is smaller.

### Fixed
- A host name that is the end of another one, such as `example.com` and `fileserver.example.com`, no longer counts as mounted.

## 0.0.1 - 2026-10-28
### New
- First release: mounts SMB shares while their server is reachable and unmounts them when it is not, with a configuration app, a menu bar icon, an installer package and updates from GitHub Releases. English and German UI.
