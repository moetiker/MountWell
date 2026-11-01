# Testing in a clean macOS VM

`tools/test-vm` installs MountWell in a throwaway macOS VM that has never seen it
and checks what a new user gets. It needs [Tart](https://tart.run) and about 80 GB
of disk; the VM runs the same macOS as the Mac.

    tools/test-vm setup             # once: build the clean image mountwell-clean
    tools/test-vm run               # test the released cask
    tools/test-vm run --local       # test the package from ./build.sh
    tools/test-vm clean             # delete copies a killed run left behind

`--show` opens the VM window. The exit code of `run` is the number of failed checks.
`MOUNTWELL_VM` names another clean image.

## The clean image

`setup` builds `mountwell-clean` once, in about an hour, most of it the 17 GB IPSW:

1. `tart create --from-ipsw latest` installs the macOS the Mac runs.
2. On the first boot Tart's provisioning creates the user `admin` (password `admin`)
   with automatic login and SSH.
3. Over SSH: the key `~/.ssh/mountwell-test-vm`, passwordless sudo, no sleep or
   screen lock, the Command Line Tools and Homebrew.
4. The image is shut down and renamed to `mountwell-clean`.

A failed `setup` resumes after its last finished step; the step is kept in
`build/test-vm/mountwell-clean-building.stage`. A run never starts the clean image
itself. `tart delete mountwell-clean` removes it.

## A run

On the Mac:

1. With `--local`, `./build.sh` runs the tests and builds
   `build/MountWell-<version>.pkg`.
2. `tart clone` makes the copy `mountwell-test-<date-time>`. From here on, every exit
   deletes the copy: a finished run, a failure or Ctrl-C.
3. The copy boots without a window and the script waits for SSH.
4. `scp` copies `tests/vm/check.sh`, and the package with `--local`, to
   `~/mountwell-test/`.
5. SSH runs `check.sh cask` or `check.sh local <pkg>`. The output also goes to
   `build/test-vm/<vm>.check.log`.

In the VM, `tests/vm/check.sh`:

6. Installs MountWell. Without `--local` the way the README says: `brew tap`,
   `brew trust`, `brew install --cask mountwell`. With `--local`:
   `sudo installer -pkg`.
   Checks: `brew install` prints no warning and Gatekeeper accepts the app as
   notarized (cask only); MountWell.app is in /Applications; the package receipt
   `ch.oetiker.mountwell` has the app's version.
7. Checks the background service: `/Library/LaunchAgents/ch.oetiker.mountwell.plist`
   is there and belongs to root:wheel; the installer loaded it for the logged-in
   user; launchd starts `Contents/MacOS/mountwell-agent`; app and agent are signed by
   the same team; `sfltool dumpbtm` shows the service with a developer name and that
   team, so Login Items does not call it an unknown developer.
8. Check: the installer opened MountWell, since there is no `shares.conf` yet.
9. Writes a `shares.conf` with one switched-off share and starts the service.
   Check: the run exits with 0.
10. Uninstalls: without `--local` with `brew uninstall --zap --cask mountwell`, with
    `--local` with `uninstall.sh`.
    Checks: the app, the LaunchAgent plist and the receipt are gone; the service is
    no longer loaded; MountWell no longer runs. The zap removes the settings and the
    log; `uninstall.sh` keeps the settings.
11. Prints an `ok:` or `FAIL:` line per check and `== N failure(s)`, and exits with N.

Back on the Mac the copy is stopped and deleted. A run takes about 2 minutes, plus
the build and notarization with `--local`.

## Limits

- No share is mounted. Tart's VMs cannot reach each other, and macOS does not mount
  its own shares through the system's mount service (error 65), which is what
  `mount volume` uses. A packet filter redirect gets past both, but the mount then
  waits for a confirmation dialog nothing can click.
- An update from the previous version is not tested.
