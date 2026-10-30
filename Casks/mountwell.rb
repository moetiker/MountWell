# Homebrew cask for MountWell. This repository is its own tap.
cask "mountwell" do
  version "0.4.0"
  sha256 "cb7a4695d41ccf2ebba24feb33119280ab37ab8e56ab7e3eb792f0d16005742c"

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
    "~/.config/mountwell",
    "~/Library/Logs/mountwell.log",
  ]
end
