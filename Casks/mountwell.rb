# Homebrew cask for MountWell. This repository is its own tap.
cask "mountwell" do
  version "0.3.1"
  sha256 "a0aee02949da4c87d783fe46637540d6fc0f94b0647f5710d6aefedf8ab9a2d6"

  # 0.3.1 was released before the rename and its package still carries the old name
  url "https://github.com/moetiker/MountWell/releases/download/v#{version}/Mountwell-#{version}.pkg"
  name "MountWell"
  desc "Mounts SMB shares while the server is reachable and unmounts them when not"
  homepage "https://github.com/moetiker/MountWell"

  # the app offers and installs its own updates
  auto_updates true
  depends_on macos: ">= :sonoma"

  pkg "Mountwell-#{version}.pkg"

  uninstall launchctl: "ch.oetiker.mountwell",
            pkgutil:   "ch.oetiker.mountwell",
            delete:    [
              "/Applications/MountWell.app",
              "/Library/LaunchAgents/ch.oetiker.mountwell.plist",
            ]

  zap trash: [
    "~/.config/mountwell",
    "~/Library/Logs/mountwell.log",
  ]
end
