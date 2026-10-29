# Mountwell

[![CI](https://github.com/moetiker/mountwell/actions/workflows/ci.yml/badge.svg)](https://github.com/moetiker/mountwell/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/moetiker/mountwell)](https://github.com/moetiker/mountwell/releases/latest)

Mountwell mounts SMB shares on macOS while their file server is reachable, in the office
network or over VPN, and unmounts them when it is not. Finder no longer hangs on a share
whose server is gone, and after the VPN comes up the shares are there.

![The Mountwell window with three shares](docs/screenshot.png)

- A background service checks every share on each network change and every minute.
- Shares can be limited to networks by IP prefix, given an alias, switched off, and ejected by hand.
- Shares already mounted in Finder can be imported from the menu bar menu.
- A menu bar icon shows the state; the app checks addresses while you type them.
- Mountwell can start at login, with or without its window (Settings, ⌘,).
- The app follows the Mac's language (English or German) and finds its own updates.

macOS 14 or later, Apple silicon or Intel.

## Install

Download `Mountwell-<version>.pkg` from the
[latest release](https://github.com/moetiker/mountwell/releases/latest) and open it.
The package is not signed with a Developer ID, so choose **Open Anyway** in
*System Settings → Privacy & Security*, or install it in Terminal:

```sh
sudo installer -pkg Mountwell-<version>.pkg -target /
```

Add your shares in the app, for example `smb://fileserver.example.com/team`. Then press
the link button of each share once and choose **Remember this password in my keychain**,
so the background service can mount without asking.

## Configuration

The app writes `~/.config/mountwell/shares.conf`, one share per line, with an optional
list of IP prefixes and an optional alias after `#`. A leading `!` switches a share off:

```
smb://fileserver.example.com/team
smb://nas.example.com/photos 192.168.10. # Photos at home
!smb://fileserver.example.com/archive
```

The log is `~/Library/Logs/mountwell.log`.

## Uninstall

```sh
sudo "/Applications/Mountwell.app/Contents/Resources/uninstall.sh"
```

The configuration in `~/.config/mountwell` stays.

## Development

```sh
./build.sh      # tests, then build/Mountwell-<version>.pkg
```

- [`docs/spec.md`](docs/spec.md): what Mountwell must do
- [`docs/programming-guide.md`](docs/programming-guide.md): architecture, conventions, translation, tests, releases
- [`docs/maintainer-notes.md`](docs/maintainer-notes.md): pitfalls and the reasons behind decisions

## License

MIT, see [LICENSE](LICENSE). Created by Manuel Oetiker.
