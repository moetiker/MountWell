// Updates from GitHub releases (U-1 to U-4).

import AppKit
import SwiftUI

struct UpdateError: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    @Published private(set) var available: Release?
    @Published private(set) var busy = false
    private var timer: Timer?

    // at launch and then daily; only speaks up when there is something new
    func start() {
        guard timer == nil, updateRepo != nil else { return }
        Task { await check(manual: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check(manual: false) }
        }
    }

    func check(manual: Bool) async {
        guard let repo = updateRepo, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                throw UpdateError(status == 404
                    ? String(localized: "No version has been published on GitHub yet, or the repository is not public.")
                    : String(localized: "GitHub responded with status \(status)."))
            }
            guard let r = parseRelease(data) else {
                throw UpdateError(String(localized: "The latest version on GitHub contains no installer package."))
            }
            available = isNewer(r.version, than: appVersion) ? r : nil
            if manual {
                if let r = available {
                    offer(r)
                } else {
                    info(String(localized: "Mountwell Is Up to Date"), String(localized: "Version \(appVersion) is the latest."))
                }
            }
        } catch {
            if manual { info(String(localized: "Checking for Updates Failed"), error.localizedDescription) }
        }
    }

    func offer(_ r: Release) {
        let a = NSAlert()
        a.messageText = String(localized: "Mountwell \(r.version) Is Available")
        var text = String(localized: "Version \(appVersion) is installed. The installer will ask for an administrator password.")
        if updateTeamID == nil {
            text += "\n\n" + String(localized: "This version of Mountwell cannot check who signed the package. Install it only if you trust the release on GitHub.")
        }
        if !r.notes.isEmpty { text += "\n\n" + plainNotes(r.notes) }
        a.informativeText = text
        a.addButton(withTitle: String(localized: "Install"))
        a.addButton(withTitle: String(localized: "Later"))
        NSApp.activate()
        if a.runModal() == .alertFirstButtonReturn {
            Task { await install(r) }
        }
    }

    // Downloads the package. Signed builds hand it to install-update as root, which copies,
    // checks and installs it out of the user's reach; unsigned builds have no team to check
    // against and open it in Installer. preinstall quits the app, postinstall relaunches it.
    private func install(_ r: Release) async {
        busy = true
        defer { busy = false }
        do {
            let (tmp, resp) = try await URLSession.shared.download(from: r.pkgURL)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                throw UpdateError(String(localized: "The package could not be downloaded."))
            }
            let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(agentLabel)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // fixed name: the version comes from the network and does not belong in a path
            let pkg = dir.appendingPathComponent("Mountwell-Update.pkg")
            try? FileManager.default.removeItem(at: pkg)
            try FileManager.default.moveItem(at: tmp, to: pkg)
            // whoever can publish a release could otherwise ship code that runs as root
            if let team = updateTeamID {
                let path = pkg.path
                let r = await Task.detached { run("/usr/sbin/pkgutil", ["--check-signature", path]) }.value
                guard r.status == 0, installerTeamID(r.output) == team else {
                    try? FileManager.default.removeItem(at: pkg)
                    throw UpdateError(String(localized: "The package is not signed by the developer of Mountwell. It was deleted and not installed."))
                }
                try await installVerified(pkg, team: team)
                return
            }
            NSWorkspace.shared.open(pkg)
        } catch {
            info(String(localized: "Update Failed"), error.localizedDescription)
        }
    }

    // install-update runs as root and comes from the installed app bundle, which only root
    // can change; a copy anywhere else (a development build) is not trusted with root
    private func installVerified(_ pkg: URL, team: String) async throws {
        let script = "/Applications/Mountwell.app/Contents/Resources/install-update"
        let attrs = try? FileManager.default.attributesOfItem(atPath: script)
        guard (attrs?[.ownerAccountID] as? NSNumber)?.intValue == 0,
              let perms = (attrs?[.posixPermissions] as? NSNumber)?.intValue, perms & 0o022 == 0
        else {
            throw UpdateError(String(localized: "Mountwell is not installed in Applications, so it cannot install updates itself. Install the new version from GitHub."))
        }
        let prompt = String(localized: "Mountwell wants to install an update.")
        let path = pkg.path
        let r = await Task.detached {
            run("/usr/bin/osascript", [
                "-e", "on run argv",
                "-e", "do shell script (quoted form of item 1 of argv) & \" \" & (quoted form of item 2 of argv) & \" \" & (quoted form of item 3 of argv) with prompt (item 4 of argv) with administrator privileges",
                "-e", "end run", script, path, team, prompt])
        }.value
        try? FileManager.default.removeItem(at: pkg)
        if r.status == 0 { return }
        if r.output.contains("(-128)") { return }   // the user cancelled the password dialog
        if r.output.contains("(4)") {
            throw UpdateError(String(localized: "The package is not signed by the developer of Mountwell. It was deleted and not installed."))
        }
        throw UpdateError(String(localized: "The update could not be installed."))
    }

    private func info(_ title: String, _ text: String) {
        showAlert(title, text)
    }
}
