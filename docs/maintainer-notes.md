# Maintainer notes

What had to be known, or went wrong, while building Mountwell. Each point names the
symptom so it can be checked later whether it still applies.

## Name

- Until the rename the project was called "SMB Automount" (bundle ID
  `ch.oetiker.smb-automount.app`, label `ch.oetiker.smb-automount`, package 1.0).
  Mountwell starts at version 0.0.1 under a new package ID. `postinstall` removes the
  old installation; the script and `postinstall` move `~/.config/smb-automount` and the
  old log, as long as nothing new exists yet.
- "Mountly" was rejected because there already is a macOS app of that name that mounts
  drives (mountlyapp.vercel.app), plus a company and an npm package. In October 2026
  "Mountwell" turned up neither in the Mac App Store nor as an app; mountwell.com is
  registered, though.
- The icon shows a mountain (mount, mountain) and is drawn in `app/make-icon.swift`.
  Before, it was an SF Symbol, whose license does not allow use in app icons.

## Language

- Everything in the repository is English. Only the app UI follows the Mac's language.
  English is the development language (`CFBundleDevelopmentRegion` `en`), German lives in
  `app/de.lproj/`.
- `Localizable.strings` keys are the English texts. Interpolations become `%@` for
  strings and `%lld` for integers; with two integers German uses `%1$lld`/`%2$lld`.
- Only `Text("…")`, `Button("…")`, `LocalizedStringKey` and `String(localized:)` are
  looked up. A `String` passed through a parameter is shown verbatim, which is why
  `Hint` takes `Text` and `Tag` takes `LocalizedStringKey`.
- The help texts are multi-line literals. Their keys are the literal's content after
  Swift strips the indentation, with `\n` between lines. When the English text changes,
  the German key must change with it, or the help silently falls back to English.
- `en.lproj/Localizable.strings` only contains a comment. It has to exist so macOS lists
  English as supported.
- The log written by `mountwell.sh` is always English. `LogPanel` picks its icons from
  the words `mounting`, `unmounting` and `failed`.

## Build environment

- With stale headers in `/usr/local/include` (e.g. `stdbool.h`, `Block.h`), `swiftc`
  without an explicit SDK fails with `#include nested too deeply` and
  `could not build Objective-C module 'Accessibility'`. `build.sh` and `tests/run.sh`
  therefore set `SDKROOT`. `swiftc -sdk` alone is not enough: `swift app/make-icon.swift`
  (interpreter) needs the exported `SDKROOT`.
- With Swift 6 the build uses `-swift-version 5`, so the strict concurrency checks of
  Swift 6 do not raise errors. The one remaining warning
  (`reference to captured var 'reach' in concurrently-executing code`) is fixed by
  copying the variable into a constant before `MainActor.run`.
- There is no Xcode project. The app is compiled per architecture with
  `swiftc -parse-as-library` and combined into a Universal app with `lipo`.
  `-parse-as-library` is needed because `@main` otherwise clashes with top-level code.
- With several source files Swift only allows top-level code in `main.swift`.
  `tests/CoreTests.swift` failed with `expressions are not allowed at the top level`
  and is therefore named `tests/main.swift`.
- `internal` is a keyword and not allowed as a variable name
  (`keyword 'internal' cannot be used as an identifier here`).
- `Timer.publish(...).autoconnect()` as a property produces the warning
  `'Combine' was not imported by this file` without `import Combine`.
- On Apple silicon every executable must be signed. Without a Developer ID it is signed
  ad hoc (`codesign --sign -`).
- The icon is drawn at build time (`app/make-icon.swift`) and turned into
  `AppIcon.icns` with `iconutil`. There are no image files in the repository.

## Package

- `BundleIsRelocatable` is switched off. Otherwise Installer puts the app wherever
  LaunchServices already knows a copy with the same bundle ID. After a build exactly such
  a copy sits in `build/root/Applications/`, and the LaunchAgent points to
  `/Applications/Mountwell.app`.
- Files carrying the `com.apple.provenance` attribute (created e.g. when building from
  inside a sandbox) keep it through `xattr -cr`, and `pkgbuild` adds `._` entries for
  them to the package. Built from a normal Terminal, they do not appear.
- Without a Developer ID certificate (`security find-identity -v -p basic`) the package
  stays unsigned, and Gatekeeper asks on double-click.
- The LaunchAgent lives system-wide in `/Library/LaunchAgents`. `~` is not allowed in
  `StandardOutPath` there, so the script writes its log itself to
  `~/Library/Logs/mountwell.log`.
- `postinstall` runs as root. It finds logged-in users through their `loginwindow`
  processes and loads the service with `launchctl bootstrap gui/<uid>`. It opens the app
  with `launchctl asuser <uid> sudo -u <user> open`, otherwise it would run as root.
- The predecessor SMB Automount first ran as a per-user LaunchAgent in
  `~/Library/LaunchAgents`, later system-wide. `postinstall` removes both variants so
  that two services do not handle the same shares.
- `uninstall.sh` deletes the app bundle it lives in. The whole procedure sits in
  `main()` with `exit` right after it, so bash does not keep reading from the deleted file.

## Mount script

- `WatchPaths` on `/Library/Preferences/SystemConfiguration` fires on Wi-Fi and
  Ethernet changes. Many VPN clients only set up a `utun` interface and write nothing
  there. `StartInterval` 60 covers those cases.
- After a network change the script waits 3 seconds for DHCP and DNS. `--now` skips this
  for calls from the app and the tests.
- Reachable means: `nc -z -G 2 <host> 445` connects. `-G` only limits the connection
  setup, not a hanging DNS lookup.
- `mount -t smbfs` prints `//user@host/share on /Volumes/share (smbfs, ...)`, even when
  the URL has no user. The comparison ignores case and looks for `host/share on `. The
  trailing ` on ` makes sure `share-old` does not count as `share` (test "similar name").
- Mounting uses `osascript -e 'mount volume "smb://..."'` because that takes the password
  from the keychain. The password must have been saved once via Finder with "Remember
  this password in my keychain", otherwise every background run shows a password dialog.
- Unmounting uses `diskutil unmount force`, falling back to `umount -f`. A normal unmount
  fails when the server is gone, and Finder then hangs on the drive.
- A forced unmount discards open files. A mounted server therefore only counts as gone
  after 3 failed attempts 5 s apart (`TRIES`, `MOUNTWELL_RETRY_DELAY`). A single lost
  attempt during a Wi-Fi dropout would otherwise unmount a working share.
- Wrong network but the server responds: only `diskutil unmount` without `force`. If that
  fails because of open files, the share stays mounted and the next run tries again.
- Ejecting in Finder cannot be told apart from a lost connection, so the next run would
  mount the share again. The app's eject therefore writes `server/share` to
  `~/.config/mountwell/ejected` before `diskutil unmount` (without `force`; if that fails
  because of open files, the entry is removed again and the app says so). The script
  skips listed shares and forgets the entry when the share is mounted again, when the
  server does not answer, or when the network does not match. So an eject lasts until
  you leave the network, not forever.
- Matching `mount` output requires `@` or `/` right before `server/share`, otherwise
  `example.com/team` would match `fileserver.example.com/team` (`mountPoint(of:in:)` in
  `app/Core.swift`; the script compares the same way via `grep -iF`).
- Without a configuration, or with `~/.config/mountwell/disabled`, the script exits
  quietly with code 0. The first version wrote "no configuration" to the log every minute
  and exited with 1.
- If the server name is a CNAME, the reverse lookup of the IP returns the host's name,
  not the alias. When an IP is entered, the app therefore suggests the host name.

## App

- Liquid Glass (`glassEffect`, `GlassEffectContainer`, button styles `.glass` and
  `.glassProminent`) exists from macOS 26. Below that, the helpers `glassCard` and
  `glassButton` use materials and `.bordered`.
- The minimum version is macOS 14, because of `buttonBorderShape(.circle)` and
  `ContentUnavailableView`.
- The address check in the editor uses `getaddrinfo` and `getnameinfo`. Both block, so
  they run in `Task.detached`. `.task(id: share.host)` cancels the check on the next
  keystroke; a 500 ms delay avoids one DNS lookup per character.
- The "Automatic" switch in the toolbar uses `.controlSize(.mini)`; the regular switch
  looked oversized next to the toolbar buttons.
- The main window has no fixed height. The share list measures its content and its
  first card with `onGeometryChange` and takes exactly that height up to 4 shares
  (`visibleShares`); with more it stays at 4 cards and scrolls. The window uses
  `.windowResizability(.contentSize)`, so it grows and shrinks with the list and the log
  panel. `onGeometryChange` is back-deployed to macOS 13 and builds for macOS 14.
- The log panel is a drawer. With `.contentSize` an inserted or removed view makes the
  window jump to the new height at once while the view is still animating. So the panel
  always stays in the view tree; only its container height animates between 0 and the
  measured panel height (`logHeight`), clipped and faded. The window follows that height
  frame by frame. Hidden, it ignores clicks and is hidden from VoiceOver.
- The help window is opened with `openWindow(id:)`. The environment is not directly
  available in `.commands`, so the menu lives in its own `Commands` struct with
  `@Environment(\.openWindow)`.
- The main window is a `Window`, not a `WindowGroup`. With `WindowGroup`, ⌘N opened more
  windows, each with its own `Model`, which overwrote each other's `shares.conf`.
- The `Model` belongs to the app, not the window, so the menu bar icon (`MenuBarExtra`)
  stays current without a window. The timer lives in the `Model`.
- Without a window the AppDelegate switches to `.accessory` (no Dock icon); `showWindow`
  switches back to `.regular` before opening. With `LSUIElement` there would never be a
  Dock icon and no menus (View, Help) either.
- "Open at Login" uses `SMAppService.mainApp`. The app recognises a launch as login item
  by `keyAELaunchedAsLogInItem` in the launch Apple event and then closes the window.
- `NSLocalNetworkUsageDescription` is in `Info.plist` because the app checks servers on
  the local network through `nc` (Local Network privacy since macOS 15).
- Updates come from GitHub Releases. The repository is stored as `MountwellUpdateRepo`
  in `Info.plist` (`REPO` in `build.sh`). Without a valid value there are no update
  menus. The unauthenticated API allows 60 requests per hour and IP and returns 404 for
  private repositories.
- The package is downloaded with `URLSession`. Files from `URLSession` get no quarantine
  attribute, so Installer opens the unsigned package without a Gatekeeper prompt. The
  only check is that it comes from GitHub over HTTPS. Whoever can create releases in the
  repository can therefore ship code that runs as root. With a Developer ID the app could
  run `pkgutil --check-signature` before opening it.
- In the cache the package is always called `Mountwell-Update.pkg`. The version comes
  from the network and does not belong in a file path.
- `preinstall` quits a running app with `pkill -x "Mountwell"` and records that in
  `/var/run/ch.oetiker.mountwell.relaunch.<uid>`. `postinstall` then relaunches it.
  `/var/run` belongs to root; a file in `/tmp` could be created as a symlink by users
  beforehand.
- The About text comes via `orderFrontStandardAboutPanel` with `.credits`, the copyright
  line from `NSHumanReadableCopyright` in `app/Info.plist`.

## GitHub Actions

- The runner is `macos-26`: the Liquid Glass APIs need the macOS 26 SDK. The runner is
  Apple silicon; the Intel half of the Universal app is cross-compiled with
  `-target x86_64-apple-macos14.0`, as locally.
- The icon is drawn with AppKit on the runner; that works without a display because it
  renders into an `NSBitmapImageRep`.
- Releases are published by the workflow with the job's `GITHUB_TOKEN`
  (`contents: write`) via `gh release create --verify-tag`. Only tags matching `v*`
  trigger it. The version comes from the tag, so tag and app version cannot diverge.
- Non-release builds use version `0.0.0`; `isNewer` treats every release as newer.

## Tests

- `tests/test-mountwell.sh` puts stubs for `nc`, `mount`, `osascript`, `diskutil`,
  `umount` and `ifconfig` in front of `PATH`. This works because the script calls these
  programs without an absolute path. Switching the script to `/sbin/mount` or similar
  makes the tests meaningless.
- `HOME` points to a temporary directory so the user's configuration, `disabled` and log
  stay untouched.
- Counter-check: with a copy of the script in which `diskutil unmount force` is replaced
  by `true` (`MOUNTWELL_SCRIPT=...`), the forced-unmount tests fail.

## Open

- Actually disconnecting VPN or Wi-Fi has not been observed yet, only simulated.
- The UI is not tested automatically. Screenshots and UI scripting need the Screen
  Recording and Accessibility permissions.
- The update function is only covered by tests of `isNewer` and `parseRelease`, not yet
  by a real update from one version to the next.
- Signing and notarization need an Apple Developer account with "Developer ID
  Application" and "Developer ID Installer".
