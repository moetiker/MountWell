// Renders the pictures in docs/ from the real views with example shares, so they show no
// real server or user, and no version number (SCREENSHOT hides it). Run tools/screenshot.sh.
// Named main.swift because Swift only allows top-level code there.
//
//   docs/screenshot.png         the main window
//   docs/screenshot-add.png     adding a share: a Windows path is offered as smb:// address
//   docs/screenshot-import.png  Import Mounted Shares

import AppKit
import SwiftUI

let dir = CommandLine.arguments[1]
NSApplication.shared.setActivationPolicy(.accessory)

@MainActor
func render<V: View>(_ view: V, width: CGFloat, toolbar: Bool, to name: String) {
    let style: NSWindow.StyleMask = toolbar ? [.titled, .closable, .miniaturizable, .fullSizeContentView] : [.titled]
    let window = NSWindow(contentRect: NSRect(x: -5000, y: 0, width: width, height: 400),
                          styleMask: style, backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .aqua)
    if toolbar { window.toolbarStyle = .unified }
    let host = NSHostingController(rootView: view.frame(width: width))
    host.sizingOptions = [.preferredContentSize]   // the window follows the content, as in the app
    window.contentViewController = host
    window.setFrameOrigin(NSPoint(x: -5000, y: 0))
    // key and active, so controls show the accent colour instead of the inactive gray
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)

    // let SwiftUI lay out, measure the share list and size the window
    RunLoop.main.run(until: Date().addingTimeInterval(2))
    window.setContentSize(host.view.fittingSize)
    RunLoop.main.run(until: Date().addingTimeInterval(1))

    let v = window.contentView!.superview!
    let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
    v.cacheDisplay(in: v.bounds, to: rep)
    let out = "\(dir)/\(name)"
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    print("wrote \(out) (\(rep.pixelsWide)×\(rep.pixelsHigh))")
    window.orderOut(nil)
}

MainActor.assumeIsolated {
    let m = Model(live: false)
    m.shares = [
        Share(url: "smb://fileserver.example.com/team", networks: "", alias: "Team Drive"),
        Share(url: "smb://fileserver.example.com/projects", networks: ""),
        Share(url: "smb://nas.example.com/photos", networks: "192.168.10.", alias: "Photos at home"),
        Share(url: "smb://fileserver.example.com/archive", networks: "", enabled: false),
    ]
    m.mountPoints = [
        "fileserver.example.com/team": "/Volumes/team",
        "fileserver.example.com/projects": "/Volumes/projects",
    ]
    m.reachable = ["fileserver.example.com": true, "nas.example.com": false]
    m.addresses = ["fileserver.example.com": ["10.46.1.20"]]
    m.addressesWithPassword = ["10.46.1.20"]
    m.agentLoaded = true
    render(ContentView(m: m), width: 680, toolbar: true, to: "screenshot.png")

    render(ShareEditor(share: Share(url: "\\\\fileserver.example.com\\team", networks: ""), isNew: true) { _ in },
           width: 520, toolbar: false, to: "screenshot-add.png")

    let found = """
        //anna@fileserver.example.com/archive on /Volumes/archive (smbfs, nodev, nosuid, mounted by anna)
        //anna@nas.example.com/music on /Volumes/music (smbfs, nodev, nosuid, mounted by anna)
        """
    let items = importProposals(found, configured: []).map { ImportItem(share: $0.share, mountPoint: $0.mountPoint) }
    render(ImportSheet(items: items) { _ in }, width: 520, toolbar: false, to: "screenshot-import.png")
}
