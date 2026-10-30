// MountWell: configuration UI for the mountwell background script.
// Edits shares.conf in ~/Library/Application Support/MountWell and shows status and log.
// This file holds the paths, the app's entry point and its menu commands; the rest is
// split by window in the other files of app/ (Core.swift is the logic without UI, shared
// with the tests).
// UI texts are English; de.lproj/Localizable.strings holds the German translation.

import AppKit
import Combine
import ServiceManagement
import SwiftUI

let agentLabel = "ch.oetiker.mountwell"
let agentPlist = "/Library/LaunchAgents/\(agentLabel).plist"
let home = FileManager.default.homeDirectoryForCurrentUser
// settings of MountWell 0.4 and earlier (~/.config/mountwell) or of SMB Automount move
// here on first use
let configDir: URL = {
    let dir = home.appendingPathComponent("Library/Application Support/MountWell")
    moveConfig(to: dir, from: [home.appendingPathComponent(".config/mountwell"),
                               home.appendingPathComponent(".config/smb-automount")])
    return dir
}()
let configFile = configDir.appendingPathComponent("shares.conf")
let disabledFile = configDir.appendingPathComponent("disabled")
// shares ejected by hand; mountwell.sh does not mount them again until the entry is gone
let ejectedFile = configDir.appendingPathComponent("ejected")
// servers that answered, written by mountwell.sh; used when a name does not resolve
let serversFile = configDir.appendingPathComponent("servers.yaml")
let logFile = home.appendingPathComponent("Library/Logs/mountwell.log")
let scriptPath = Bundle.main.path(forResource: "mountwell", ofType: nil)
    ?? "/Applications/MountWell.app/Contents/Resources/mountwell"
let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    ?? ProcessInfo.processInfo.environment["MOUNTWELL_VERSION"] ?? "dev"
// "owner/repo" on GitHub, filled in by build.sh
let updateRepo = (Bundle.main.object(forInfoDictionaryKey: "MountWellUpdateRepo") as? String).flatMap { $0.contains("/") ? $0 : nil }
// Apple team whose Developer ID must have signed an update, filled in by build.sh;
// empty for builds without one, which then install updates unchecked
let updateTeamID = (Bundle.main.object(forInfoDictionaryKey: "MountWellTeamID") as? String).flatMap { isTeamID($0) ? $0 : nil }

struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @AppStorage("showLog") private var showLog = false

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About MountWell") { showAbout() }
            if updateRepo != nil {
                Button("Check for Updates…") { Task { await Updater.shared.check(manual: true) } }
            }
        }
        // "View" menu, before the toolbar commands
        CommandGroup(before: .toolbar) {
            // explicitly LocalizedStringKey, otherwise the title is not translated
            let title: LocalizedStringKey = showLog ? "Hide Log" : "Show Log"
            Button(title) { showLog.toggle() }
                .keyboardShortcut("l", modifiers: .command)
            Divider()
        }
        CommandGroup(replacing: .help) {
            Button("MountWell Help") { openWindow(id: "help") }
                .keyboardShortcut("?", modifiers: .command)
        }
    }

    private func showAbout() {
        let text = String(localized: "Mounts SMB shares automatically as soon as their server is reachable, in the office network or over VPN, and unmounts them when the connection is gone. So Finder never hangs on dead drives.")
        let credits = NSMutableAttributedString(
            string: text + "\n\nCreated by Manuel Oetiker",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.labelColor,
            ])
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        credits.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Updater.shared.start()
        // after the last window closes, leave the Dock; only the menu bar icon stays
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            let closing = note.object as? NSWindow
            DispatchQueue.main.async {
                if !NSApp.windows.contains(where: { $0 !== closing && $0.isVisible && $0.canBecomeMain }) {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
        // started as login item: stay in the menu bar unless "Show Window at Login" is on.
        // Without shares the window opens anyway, otherwise a new user sees nothing.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let asLoginItem = event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if asLoginItem && !UserDefaults.standard.bool(forKey: showWindowAtLoginKey) && hasShares() {
            DispatchQueue.main.async {
                for w in NSApp.windows where w.canBecomeMain { w.close() }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // opening the app again in Finder brings the window back
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        NSApp.setActivationPolicy(.regular)
        return true
    }
}

#if !SCREENSHOT
@main
struct MountWellApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var m = Model()

    var body: some Scene {
        // Window, not WindowGroup: a single main window, otherwise several Models overwrite each other
        Window("MountWell", id: "main") {
            ContentView(m: m)
        }
        .windowResizability(.contentSize)   // height follows the share list, see ContentView.listHeight
        .windowToolbarStyle(.unified)
        .commands { AppCommands() }

        Window("MountWell Help", id: "help") {
            HelpView()
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra("MountWell", systemImage: m.menuBarIcon) {
            MenuBarMenu(m: m)
        }

        Settings {
            SettingsView(m: m)
        }
    }
}
#endif
