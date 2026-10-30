// The menu bar menu (A-10) and Settings (A-15).

import AppKit
import SwiftUI

// started as login item: open the window too? Off by default, the app then sits in the menu bar
let showWindowAtLoginKey = "showWindowAtLogin"

// "Run at Login" and "Show Window at Login", in the menu bar menu and in Settings
struct LoginToggles: View {
    @ObservedObject var m: Model
    @AppStorage(showWindowAtLoginKey) private var showWindowAtLogin = false

    var body: some View {
        Toggle("Run at Login", isOn: Binding(get: { m.launchAtLogin }, set: { m.setLaunchAtLogin($0) }))
        Toggle("Show Window at Login", isOn: $showWindowAtLogin)
            .disabled(!m.launchAtLogin)
    }
}

struct SettingsView: View {
    @ObservedObject var m: Model

    var body: some View {
        Form {
            Section {
                LoginToggles(m: m)
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .frame(width: 380)
        .fixedSize()
    }
}

// whether shares.conf lists at least one share
func hasShares() -> Bool {
    let text = (try? String(contentsOf: configFile, encoding: .utf8)) ?? ""
    return text.split(separator: "\n").contains { parseShareLine(String($0)) != nil }
}

// Show a window; without a window the app has no Dock icon (see AppDelegate)
@MainActor
func showWindow(_ id: String, _ openWindow: OpenWindowAction) {
    NSApp.setActivationPolicy(.regular)
    openWindow(id: id)
    NSApp.activate()
}

struct MenuBarMenu: View {
    @ObservedObject var m: Model
    @ObservedObject private var updater = Updater.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let r = updater.available {
            Button("Install Update \(r.version)…") { updater.offer(r) }
                .disabled(updater.busy)
            Divider()
        }
        if m.shares.isEmpty {
            Text("No Shares")
        }
        ForEach(m.shares) { share in
            shareMenu(share)
        }
        Divider()
        Toggle("Mount Automatically", isOn: Binding(get: { m.enabled }, set: { m.setEnabled($0) }))
        Button("Check Now") { m.runNow() }
            .disabled(m.busy || !m.enabled)
        Button("Import Mounted Shares…") {
            showWindow("main", openWindow)
            m.findImports()
        }
        Divider()
        Button("Open MountWell…") { showWindow("main", openWindow) }
        LoginToggles(m: m)
        if updateRepo != nil {
            Button("Check for Updates…") { Task { await updater.check(manual: true) } }
                .disabled(updater.busy)
        }
        Divider()
        Button("Quit MountWell") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func shareMenu(_ share: Share) -> some View {
        let reachable = m.reachable[share.host] == true
        let icon = m.isMounted(share) ? "checkmark.circle.fill" : !share.enabled ? "pause.circle"
            : m.isEjected(share) ? "eject.circle" : reachable ? "circle" : "xmark.circle"
        return Menu {
            if let mp = m.mountPoints[share.hostShare] {
                Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: mp)) }
                Button("Eject") { m.eject(share) }
            } else {
                Button("Mount") { m.mount(share) }
                    .disabled(!reachable)
            }
            Divider()
            Toggle("Mount Automatically", isOn: Binding(get: { share.enabled }, set: { m.setShareEnabled(share, $0) }))
        } label: {
            Label(share.menuTitle, systemImage: icon)
        }
    }
}
