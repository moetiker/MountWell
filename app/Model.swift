// The state the window and the menu bar show: shares, mount points, reachability,
// remembered servers. Reads and writes the files mountwell.sh uses.

import AppKit
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class Model: ObservableObject {
    @Published var shares: [Share] = []
    @Published var enabled = true
    @Published var mountPoints: [String: String] = [:]   // hostShare → /Volumes/…
    @Published var ejected: Set<String> = []
    @Published var reachable: [String: Bool] = [:]
    @Published var addresses: [String: [String]] = [:]   // server name → remembered IPs, one per network
    @Published var addressesWithPassword: Set<String> = []   // IPs with an SMB keychain entry
    // servers whose port is being probed right now, and shares being mounted or ejected
    @Published var checking: Set<String> = []
    @Published var working: Set<String> = []
    @Published var agentLoaded = false
    @Published var log: [String] = []
    // the background script runs ("Check Now", after saving)
    @Published var scriptRunning = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    // proposals of "Import Mounted Shares"; non-nil shows the import sheet
    @Published var imports: [ImportItem]?
    private var timer: Timer?
    private var lastRefresh = Date.distantPast
    // servers being probed; they show in `checking` only once a probe takes a while
    private var probing: Set<String> = []
    // one refresh at a time: with several unreachable servers one takes longer than the
    // 10 s timer, and an older run finishing last showed stale state
    private var refreshing = false
    private var refreshAgain = false

    // keeps running without a window, for the menu bar icon;
    // live: false shows only what the caller sets (tools/screenshot)
    init(live: Bool = true) {
        guard live else { return }
        load()
        refresh()
        // every 10 s while a window shows the state, else once a minute for the menu bar icon:
        // each refresh starts mount, nc per server and launchctl
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let visible = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
                if visible || Date().timeIntervalSince(self.lastRefresh) >= 60 { self.refresh() }
            }
        }
    }

    var mountedCount: Int { shares.filter { isMounted($0) }.count }

    var busy: Bool { scriptRunning || !working.isEmpty }

    func isMounted(_ s: Share) -> Bool { mountPoints[s.hostShare] != nil }
    func isEjected(_ s: Share) -> Bool { ejected.contains(s.hostShare) }

    // the card's spinner: something is under way whose result is not shown yet
    func isWorking(_ s: Share) -> Bool {
        if working.contains(s.hostShare) { return true }
        guard s.enabled, !isMounted(s) else { return false }
        if checking.contains(s.host) { return true }
        // "Check Now": the service is about to mount what is reachable
        return scriptRunning && enabled && !isEjected(s) && reachable[s.host] == true
    }

    var menuBarIcon: String {
        if !enabled { return "externaldrive.badge.xmark" }
        return mountedCount > 0 ? "externaldrive.fill.badge.checkmark" : "externaldrive"
    }

    func load() {
        let text = (try? String(contentsOf: configFile, encoding: .utf8)) ?? ""
        shares = text.split(separator: "\n").compactMap { parseShareLine(String($0)) }
        enabled = !FileManager.default.fileExists(atPath: disabledFile.path)
    }

    func save() {
        var text = """
            # [!]smb://[user@]server/share   [optional IP prefixes, comma-separated]   [# optional alias]
            # "!" disables a share: it is neither mounted nor unmounted
            # Managed by MountWell.app

            """
        for s in shares {
            if let line = shareLine(s) { text += line + "\n" }
        }
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try? text.write(to: configFile, atomically: true, encoding: .utf8)
        runNow()
    }

    func upsert(_ share: Share) {
        if let i = shares.firstIndex(where: { $0.id == share.id }) {
            shares[i] = share
        } else {
            shares.append(share)
        }
        save()
    }

    func delete(_ share: Share) {
        shares.removeAll { $0.id == share.id }
        save()
    }

    // the service learns the server again the next time its name resolves or it is mounted
    func forgetAddress(_ share: Share) {
        addresses[share.host] = nil
        let host = share.host
        Task.detached {
            withRunLock {
                let text = (try? String(contentsOf: serversFile, encoding: .utf8)) ?? ""
                try? forgettingServer(host, in: text).write(to: serversFile, atomically: true, encoding: .utf8)
            }
            await MainActor.run { self.refresh() }
        }
    }

    func setShareEnabled(_ share: Share, _ on: Bool) {
        guard let i = shares.firstIndex(where: { $0.id == share.id }) else { return }
        shares[i].enabled = on
        save()
    }

    // proposals from the SMB shares mounted right now that are not configured yet
    func findImports() {
        let configured = shares
        let addresses = addresses
        Task.detached {
            let out = run("/sbin/mount", ["-t", "smbfs"]).output
            let found = importProposals(out, configured: configured, servers: addresses).map { ImportItem(share: $0.share, mountPoint: $0.mountPoint) }
            await MainActor.run {
                if found.isEmpty {
                    showAlert(String(localized: "Nothing to Import"),
                              String(localized: "Every mounted SMB share is already in MountWell. Connect to a share in Finder first, then import it here."))
                } else {
                    self.imports = found
                }
            }
        }
    }

    func importShares(_ items: [ImportItem]) {
        shares += items.filter(\.selected).map(\.share)
        save()
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        if on {
            try? FileManager.default.removeItem(at: disabledFile)
            runNow()
        } else {
            try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: disabledFile.path, contents: nil)
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Login item: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // Unmount by hand. Remembered in ejectedFile, otherwise the background
    // service would mount the share again within a minute.
    // The record and the unmount happen under the script's lock: a run in between still saw
    // the share mounted, took that for "mounted again" and dropped the record.
    func eject(_ s: Share) {
        guard let mp = mountPoints[s.hostShare] else { return }
        working.insert(s.hostShare)
        ejected.insert(s.hostShare)
        let key = s.hostShare
        Task.detached {
            let result = withRunLock { () -> (status: Int32, output: String) in
                Model.writeEjected(key, true)
                let r = run("/usr/sbin/diskutil", ["unmount", mp])
                if r.status != 0 { Model.writeEjected(key, false) }
                return r
            }
            await MainActor.run {
                self.working.remove(s.hostShare)
                if result.status != 0 {
                    self.ejected.remove(s.hostShare)
                    showAlert(String(localized: "“\(s.title)” could not be ejected"),
                              String(localized: "Files on it may still be open. Close them and try again."))
                }
                self.refresh()
            }
        }
    }

    // Mount right away, also when "Automatic" is off, and forget an earlier eject
    func mount(_ s: Share) {
        working.insert(s.hostShare)
        ejected.remove(s.hostShare)
        let key = s.hostShare
        let url = s.url.trimmingCharacters(in: .whitespaces)
        Task.detached {
            withRunLock { Model.writeEjected(key, false) }
            // the URL as an argument, never inside the script text: escaping only '"' let
            // a "\" in the URL end the string and run the rest as AppleScript
            run("/usr/bin/osascript", ["-e", "on run argv", "-e", "mount volume (item 1 of argv)", "-e", "end run", url])
            await MainActor.run {
                self.working.remove(s.hostShare)
                self.refresh()
            }
        }
    }

    // adds or removes one share in ejectedFile; the caller holds the run lock
    nonisolated static func writeEjected(_ hostShare: String, _ on: Bool) {
        var set = readEjected()
        if on { set.insert(hostShare) } else { set.remove(hostShare) }
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        if set.isEmpty {
            try? FileManager.default.removeItem(at: ejectedFile)
        } else {
            try? (set.sorted().joined(separator: "\n") + "\n").write(to: ejectedFile, atomically: true, encoding: .utf8)
        }
    }

    nonisolated static func readEjected() -> Set<String> {
        let text = (try? String(contentsOf: ejectedFile, encoding: .utf8)) ?? ""
        return Set(text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
    }

    func loadAgent() {
        run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", agentPlist])
        refresh()
    }

    func runNow() {
        scriptRunning = true
        Task.detached {
            run(scriptPath, ["--now"])
            await MainActor.run {
                self.scriptRunning = false
                self.refresh()
            }
        }
    }

    func refresh() {
        guard !refreshing else {
            refreshAgain = true
            return
        }
        refreshing = true
        lastRefresh = Date()
        let snapshot = shares
        Task.detached(priority: .utility) {
            let mountOut = run("/sbin/mount", ["-t", "smbfs"]).output
            let addresses = parseServers((try? String(contentsOf: serversFile, encoding: .utf8)) ?? "")
            // without -w only the entry's attributes are read: no keychain prompt
            let withPassword = Set(snapshot.flatMap { addresses[$0.host] ?? [] }.filter {
                run("/usr/bin/security", ["find-internet-password", "-s", $0, "-r", "smb "]).status == 0
            })
            var points: [String: String] = [:]
            for s in snapshot {
                // mounted by name, or by the service via the remembered IP
                if let mp = mountPoint(of: s.hostShare, in: mountOut)
                    ?? (addresses[s.host] ?? []).lazy.compactMap({ mountPoint(of: s.hostShare(via: $0), in: mountOut) }).first {
                    points[s.hostShare] = mp
                }
            }
            let mountPoints = points
            let ejected = Model.readEjected()
            // a mounted share shows "Mounted" whatever the port says; the service watches it
            let hosts = Set(snapshot.filter { mountPoints[$0.hostShare] == nil }.map(\.host)).filter { !$0.isEmpty }
            // a server that answers does so in milliseconds; a spinner for that would only flicker
            await MainActor.run {
                self.probing.formUnion(hosts)
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    let slow = self.probing.subtracting(self.checking)
                    if !slow.isEmpty { self.checking.formUnion(slow) }
                }
            }
            for h in hosts {
                let r = smbReachable(h)
                await MainActor.run {
                    self.probing.remove(h)
                    if self.reachable[h] != r { self.reachable[h] = r }
                    if self.checking.contains(h) { self.checking.remove(h) }
                }
            }
            let agent = run("/bin/launchctl", ["print", "gui/\(getuid())/\(agentLabel)"]).status == 0
            let lines = ((try? String(contentsOf: logFile, encoding: .utf8)) ?? "")
                .split(separator: "\n").suffix(50).reversed().map(String.init)
            // reachable is set per server above; only what changed: every assignment redraws the window
            await MainActor.run {
                if self.mountPoints != mountPoints { self.mountPoints = mountPoints }
                if self.ejected != ejected { self.ejected = ejected }
                if self.addresses != addresses { self.addresses = addresses }
                if self.addressesWithPassword != withPassword { self.addressesWithPassword = withPassword }
                if self.agentLoaded != agent { self.agentLoaded = agent }
                if self.log != lines { self.log = lines }
                self.refreshing = false
                if self.refreshAgain {
                    self.refreshAgain = false
                    self.refresh()
                }
            }
        }
    }
}

// Runs body while holding mountwell.sh's lock (M-19), so a run of the script does not
// read a file half way through a change or write its own copy back over it. Waits up to
// 30 s like the script; after that it goes ahead rather than lose the user's action.
func withRunLock<T>(_ body: () -> T) -> T {
    let lock = configDir.appendingPathComponent(".run.lock").path
    try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    var held = false
    for _ in 0..<150 {
        if run("/usr/bin/shlock", ["-f", lock, "-p", String(getpid())]).status == 0 { held = true; break }
        usleep(200_000)
    }
    defer { if held { try? FileManager.default.removeItem(atPath: lock) } }
    return body()
}

func showAlert(_ title: String, _ text: String) {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = text
    NSApp.activate()
    a.runModal()
}
