// The main window: share cards, log drawer, status bar.

import AppKit
import SwiftUI

struct ShareCard: View {
    let share: Share
    let mounted: Bool
    let ejected: Bool
    let reachable: Bool?
    let working: Bool
    let fallbackIPs: [String]          // remembered, one per network (M-12)
    let withPassword: Set<String>      // those with an SMB keychain entry
    let onEdit: () -> Void
    let onToggle: (Bool) -> Void
    let onForgetAddress: () -> Void
    let onDelete: () -> Void
    let onEject: () -> Void
    let onMount: () -> Void
    @State private var hovering = false

    private var state: (icon: String, color: Color, text: LocalizedStringKey) {
        if mounted { return ("externaldrive.fill.badge.checkmark", .green, "Mounted") }
        if !share.enabled { return ("pause.fill", .gray, "Off") }
        if ejected { return ("eject.fill", .gray, "Ejected") }
        switch reachable {
        case true?: return ("externaldrive.fill.badge.wifi", .orange, "Reachable")
        case false?: return ("externaldrive.fill.badge.xmark", .gray, "Unreachable")
        default: return ("externaldrive.fill", .gray, "Checking…")
        }
    }

    // the remembered addresses that differ from the configured one; for a share configured
    // by IP the entries only pin the server (M-14)
    private var viaIPs: [String] { fallbackIPs.filter { $0 != share.host } }
    private var missingPassword: [String] { viaIPs.filter { !withPassword.contains($0) } }

    private var fallbackHelp: String {
        guard !viaIPs.isEmpty else { return "" }
        let ips = viaIPs.joined(separator: ", ")
        if let ip = missingPassword.first {
            return String(localized: "No password saved for \(ip), so Mountwell does not use it when the name does not resolve. Right-click → Connect via \(ip) in Finder.")
        }
        return String(localized: "If the name does not resolve, Mountwell mounts via \(ips), in the network where it learned that address.")
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: state.icon)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.pulse, isActive: reachable == nil && !mounted && share.enabled)
                .frame(width: 46, height: 46)
                .background(state.color.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: state.color.opacity(0.35), radius: 6, y: 2)
                // on the icon, so the text next to it does not move
                .overlay(alignment: .bottomTrailing) {
                    if working {
                        ProgressView().controlSize(.small)
                            .padding(3)
                            .background(.regularMaterial, in: Circle())
                            .offset(x: 6, y: 6)
                            .help("Checking the server or mounting")
                    }
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(share.title).font(.headline)
                // with an alias the real share name stays visible next to the server
                HStack(spacing: 4) {
                    Text(verbatim: share.title == share.name ? share.host : "\(share.host)/\(share.name)")
                    if !viaIPs.isEmpty {
                        Text(verbatim: "· " + viaIPs.joined(separator: ", "))
                        if !missingPassword.isEmpty {
                            Image(systemName: "key.slash").foregroundStyle(.orange)
                        }
                    }
                }
                .font(.subheadline).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .help(fallbackHelp)
                HStack(spacing: 6) {
                    Tag(text: state.text, color: state.color)
                    ForEach(share.networkList, id: \.self) { net in
                        Tag(text: "only \(net)*", color: .blue, icon: "network")
                    }
                }
                .padding(.top, 2)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                if mounted {
                    Button(action: onEject) { Image(systemName: "eject") }
                        .help("Eject. Stays ejected until you mount it again or leave the network.")
                } else if reachable == true {
                    Button(action: onMount) { Image(systemName: "arrow.down.circle") }
                        .help("Mount now")
                }
                Button {
                    if let u = URL(string: share.url) { NSWorkspace.shared.open(u) }
                } label: {
                    Image(systemName: "link")
                }
                .help("Connect in Finder and save the password in the keychain")
                Button(action: onEdit) { Image(systemName: "pencil") }
                    .help("Edit")
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .help("Remove")
            }
            .glassButton()
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .opacity(hovering ? 1 : 0.55)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .opacity(share.enabled || hovering ? 1 : 0.6)
        .glassCard()
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(hovering ? 0.45 : 0), lineWidth: 1)
        }
        .animation(.smooth(duration: 0.2), value: hovering)
        .animation(.smooth, value: state.icon)
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onEdit)
        .contextMenu {
            if mounted {
                Button("Eject", action: onEject)
            } else {
                Button("Mount", action: onMount)
            }
            Toggle("Mount Automatically", isOn: Binding(get: { share.enabled }, set: onToggle))
            Divider()
            Button("Edit…", action: onEdit)
            Button("Connect in Finder") {
                if let u = URL(string: share.url) { NSWorkspace.shared.open(u) }
            }
            // the keychain password belongs to the server name; each IP needs its own once
            ForEach(viaIPs, id: \.self) { ip in
                Button("Connect via \(ip) in Finder") {
                    if let u = URL(string: share.replacingHost(with: ip)) { NSWorkspace.shared.open(u) }
                }
            }
            if !fallbackIPs.isEmpty {
                Button("Forget Remembered Server", action: onForgetAddress)
            }
            Divider()
            Button("Remove", role: .destructive, action: onDelete)
        }
    }
}

struct Tag: View {
    let text: LocalizedStringKey
    let color: Color
    var icon: String? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(color.opacity(scheme == .dark ? 0.24 : 0.14), in: Capsule())
    }
}

struct LogPanel: View {
    let lines: [String]
    let onClose: () -> Void

    // icon per message from mountwell.sh; the log itself is always English
    private func look(_ msg: Substring) -> (String, Color) {
        if msg.contains("failed") { return ("xmark.circle.fill", .red) }
        if msg.hasPrefix("mounting") { return ("arrow.down.circle.fill", .green) }
        if msg.contains("unmounting") { return ("eject.circle.fill", .orange) }
        return ("circle.fill", .secondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Log", systemImage: "list.bullet.rectangle")
                    .font(.headline)
                Spacer()
                Group {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([logFile])
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("Show log file in Finder")
                    Button(action: onClose) { Image(systemName: "xmark") }
                        .help("Hide log (⌘L)")
                }
                .glassButton()
                .buttonBorderShape(.circle)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    if lines.isEmpty {
                        Text("No entries yet").foregroundStyle(.secondary)
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        let msg = line.dropFirst(20)
                        let (icon, color) = look(msg)
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: icon).foregroundStyle(color).imageScale(.small)
                            Text(line.prefix(19)).foregroundStyle(.secondary)
                            Text(msg)
                        }
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 140)
        }
        .padding(14)
        .glassCard()
    }
}

struct StatusBar: View {
    @ObservedObject var m: Model
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(m.agentLoaded ? Color.green : Color.red)
                .frame(width: 7, height: 7)
                .shadow(color: m.agentLoaded ? .green : .red, radius: 3)
            Text(m.agentLoaded ? "Background service running" : "Background service not loaded")
            if !m.agentLoaded {
                Button("Load") { m.loadAgent() }
                    .controlSize(.small)
                    .glassButton()
            }
            if m.busy {
                ProgressView().controlSize(.mini)
            }
            Spacer()
            if let r = updater.available {
                Button("Update to \(r.version)") { updater.offer(r) }
                    .controlSize(.small)
                    .glassButton(prominent: true)
                    .disabled(updater.busy)
            }
            Text(verbatim: "Version \(appVersion) · Created by Manuel Oetiker")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassCard(cornerRadius: 14)
    }
}

struct ContentView: View {
    @ObservedObject var m: Model
    @State private var editing: Share?
    @State private var editingIsNew = false
    @State private var deleting: Share?
    @State private var contentHeight: CGFloat = 0
    @State private var cardHeight: CGFloat = 78
    @State private var logHeight: CGFloat = 0
    @AppStorage("showLog") private var showLog = false

    // up to this many shares the list grows with them, beyond that it scrolls
    private let visibleShares = 4

    // height of the share list: all of its content up to visibleShares cards, then fixed
    private var listHeight: CGFloat {
        let n = m.shares.count
        if n <= visibleShares { return contentHeight }
        return CGFloat(visibleShares) * cardHeight + CGFloat(visibleShares - 1) * 10 + 4
    }
    @Environment(\.openWindow) private var openWindow

    private var subtitle: String {
        let n = m.shares.count
        return n == 0 ? String(localized: "No Shares") : String(localized: "\(m.mountedCount) of \(n) mounted")
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                GlassGroup {
                    VStack(spacing: 10) {
                        if m.shares.isEmpty {
                            ContentUnavailableView {
                                Label("No Shares", systemImage: "externaldrive.badge.plus")
                            } description: {
                                Text("Add an SMB share, e.g. smb://fileserver.example.com/team")
                            } actions: {
                                HStack {
                                    Button("Add Share") { add() }
                                        .glassButton(prominent: true)
                                    Button("Import Mounted Shares…") { m.findImports() }
                                        .glassButton()
                                }
                            }
                            .padding(.vertical, 30)
                        }
                        ForEach(m.shares) { share in
                            ShareCard(
                                share: share,
                                mounted: m.isMounted(share),
                                ejected: m.isEjected(share),
                                reachable: m.reachable[share.host],
                                working: m.isWorking(share),
                                fallbackIPs: m.addresses[share.host] ?? [],
                                withPassword: m.addressesWithPassword,
                                onEdit: {
                                    editingIsNew = false
                                    editing = share
                                },
                                onToggle: { m.setShareEnabled(share, $0) },
                                onForgetAddress: { m.forgetAddress(share) },
                                onDelete: { deleting = share },
                                onEject: { m.eject(share) },
                                onMount: { m.mount(share) }
                            )
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
                        }
                    }
                    .padding(2)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                    .animation(.smooth, value: m.shares)
                }
            }
            .scrollContentBackground(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: listHeight)

            // Drawer: the log always stays in the view tree, only the height of its
            // container is animated. The window (contentSize) follows that height frame
            // by frame, so window and log move together instead of the window jumping.
            LogPanel(lines: m.log) { showLog = false }
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { logHeight = $0 }
                .padding(.top, 14)
                .frame(height: showLog ? logHeight + 14 : 0, alignment: .bottom)
                .clipped()
                .opacity(showLog ? 1 : 0)
                .allowsHitTesting(showLog)
                .accessibilityHidden(!showLog)
            StatusBar(m: m)
                .padding(.top, 14)
                .zIndex(1)   // the log slides out from behind the status bar
        }
        .animation(.smooth(duration: 0.3), value: showLog)
        .padding(16)
        .frame(minWidth: 640)
        .background { Backdrop() }
        .navigationTitle("Mountwell")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Toggle(isOn: Binding(get: { m.enabled }, set: { m.setEnabled($0) })) {
                    Text("Automatic")
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Mount and unmount shares automatically")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    m.runNow()
                } label: {
                    Label("Check Now", systemImage: "arrow.clockwise")
                }
                .disabled(m.busy || !m.enabled)
                .help("Check Now")
                Button {
                    add()
                } label: {
                    Label("Add Share", systemImage: "plus")
                }
                .help("Add Share")
                Button {
                    openWindow(id: "help")
                } label: {
                    Label("Help", systemImage: "questionmark")
                }
                .help("Help")
            }
        }
        .sheet(item: $editing) { share in
            ShareEditor(share: share, isNew: editingIsNew) { m.upsert($0) }
        }
        .sheet(isPresented: Binding(get: { m.imports != nil }, set: { if !$0 { m.imports = nil } })) {
            ImportSheet(items: m.imports ?? []) { m.importShares($0) }
        }
        .confirmationDialog(
            "Remove Share?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { share in
            Button("Remove “\(share.title)”", role: .destructive) { m.delete(share) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It will no longer be mounted automatically. If it is mounted right now, it stays mounted until you eject it in Finder.")
        }
    }

    private func add() {
        editingIsNew = true
        editing = Share(url: "smb://", networks: "")
    }
}
