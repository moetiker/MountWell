# Homebrew cask for MountWell. This repository is its own tap.
cask "mountwell" do
  version "0.4.1"
  sha256 "a719adb97ede2255f28dace848fe569b5a129d162771cf1ab7299d4fc3c5a706"

  url "https://github.com/moetiker/MountWell/releases/download/v#{version}/MountWell-#{version}.pkg"
  name "MountWell"
  desc "Mounts SMB shares while the server is reachable and unmounts them when not"
  homepage "https://github.com/moetiker/MountWell"

  # the app offers and installs its own updates
  auto_updates true
  depends_on macos: :sonoma

  pkg "MountWell-#{version}.pkg"

  uninstall launchctl: "ch.oetiker.mountwell",
            pkgutil:   "ch.oetiker.mountwell",
            delete:    [
              "/Applications/MountWell.app",
              "/Library/LaunchAgents/ch.oetiker.mountwell.plist",
            ]

  zap trash: [
    "~/Library/Application Support/MountWell",
    "~/.config/mountwell",
    "~/Library/Logs/mountwell.log",
  ]
end
