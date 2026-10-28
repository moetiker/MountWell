// Renders docs/screenshot.png from the real main window with example shares,
// so the picture shows no real server or user. Run tools/screenshot.sh.
// Named main.swift because Swift only allows top-level code there.

import AppKit
import SwiftUI

let out = CommandLine.arguments[1]
NSApplication.shared.setActivationPolicy(.accessory)

MainActor.assumeIsolated {
    let m = Model(live: false)
    m.shares = [
        Share(url: "smb://fileserver.example.com/team", networks: ""),
        Share(url: "smb://fileserver.example.com/projects", networks: ""),
        Share(url: "smb://nas.example.com/photos", networks: "192.168.10."),
    ]
    m.mountPoints = [
        "fileserver.example.com/team": "/Volumes/team",
        "fileserver.example.com/projects": "/Volumes/projects",
    ]
    m.reachable = ["fileserver.example.com": true, "nas.example.com": false]
    m.agentLoaded = true

    let window = NSWindow(contentRect: NSRect(x: -5000, y: 0, width: 680, height: 400),
                          styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .aqua)
    window.toolbarStyle = .unified
    let host = NSHostingController(rootView: ContentView(m: m).frame(width: 680))
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

    let view = window.contentView!.superview!
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    print("wrote \(out) (\(rep.pixelsWide)×\(rep.pixelsHigh))")
}
