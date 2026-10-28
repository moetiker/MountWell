// Mountwell: configuration UI for the mountwell background script.
// Edits ~/.config/mountwell/shares.conf and shows status and log.
// UI texts are English; de.lproj/Localizable.strings holds the German translation.

import AppKit
import Combine
import ServiceManagement
import SwiftUI

let agentLabel = "ch.oetiker.mountwell"
let agentPlist = "/Library/LaunchAgents/\(agentLabel).plist"
let home = FileManager.default.homeDirectoryForCurrentUser
let configDir = home.appendingPathComponent(".config/mountwell")
let configFile = configDir.appendingPathComponent("shares.conf")
let disabledFile = configDir.appendingPathComponent("disabled")
// shares ejected by hand; mountwell.sh does not mount them again until the entry is gone
let ejectedFile = configDir.appendingPathComponent("ejected")
let logFile = home.appendingPathComponent("Library/Logs/mountwell.log")
let scriptPath = Bundle.main.path(forResource: "mountwell", ofType: nil)
    ?? "/Applications/Mountwell.app/Contents/Resources/mountwell"
let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
// "owner/repo" on GitHub, filled in by build.sh
let updateRepo = (Bundle.main.object(forInfoDictionaryKey: "MountwellUpdateRepo") as? String).flatMap { $0.contains("/") ? $0 : nil }

@MainActor
final class Model: ObservableObject {
    @Published var shares: [Share] = []
    @Published var enabled = true
    @Published var mountPoints: [String: String] = [:]   // hostShare → /Volumes/…
    @Published var ejected: Set<String> = []
    @Published var reachable: [String: Bool] = [:]
    @Published var agentLoaded = false
    @Published var log: [String] = []
    @Published var busy = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    private var timer: Timer?

    // keeps running without a window, for the menu bar icon
    init() {
        load()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var mountedCount: Int { shares.filter { isMounted($0) }.count }

    func isMounted(_ s: Share) -> Bool { mountPoints[s.hostShare] != nil }
    func isEjected(_ s: Share) -> Bool { ejected.contains(s.hostShare) }

    var menuBarIcon: String {
        if !enabled { return "externaldrive.badge.xmark" }
        return mountedCount > 0 ? "externaldrive.fill.badge.checkmark" : "externaldrive"
    }

    func load() {
        let text = (try? String(contentsOf: configFile, encoding: .utf8)) ?? ""
        shares = text.split(separator: "\n").compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !t.hasPrefix("#") else { return nil }
            let parts = t.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            let nets = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            return Share(url: String(parts[0]), networks: nets)
        }
        enabled = !FileManager.default.fileExists(atPath: disabledFile.path)
    }

    func save() {
        var text = """
            # smb://[user@]server/share   [optional IP prefixes, comma-separated]
            # Managed by Mountwell.app

            """
        for s in shares {
            let url = s.url.trimmingCharacters(in: .whitespaces)
            guard !url.isEmpty else { continue }
            let nets = s.networks.replacingOccurrences(of: " ", with: "")
            text += nets.isEmpty ? "\(url)\n" : "\(url) \(nets)\n"
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
    func eject(_ s: Share) {
        guard let mp = mountPoints[s.hostShare] else { return }
        setEjected(s, true)
        busy = true
        Task.detached {
            let result = run("/usr/sbin/diskutil", ["unmount", mp])
            await MainActor.run {
                self.busy = false
                if result.status != 0 {
                    self.setEjected(s, false)
                    showAlert(String(localized: "“\(s.name)” could not be ejected"),
                              String(localized: "Files on it may still be open. Close them and try again."))
                }
                self.refresh()
            }
        }
    }

    // Mount right away, also when "Automatic" is off, and forget an earlier eject
    func mount(_ s: Share) {
        setEjected(s, false)
        busy = true
        let url = s.url.replacingOccurrences(of: "\"", with: "\\\"")
        Task.detached {
            run("/usr/bin/osascript", ["-e", "mount volume \"\(url)\""])
            await MainActor.run {
                self.busy = false
                self.refresh()
            }
        }
    }

    private func setEjected(_ s: Share, _ on: Bool) {
        var set = Self.readEjected()
        if on { set.insert(s.hostShare) } else { set.remove(s.hostShare) }
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        if set.isEmpty {
            try? FileManager.default.removeItem(at: ejectedFile)
        } else {
            try? (set.sorted().joined(separator: "\n") + "\n").write(to: ejectedFile, atomically: true, encoding: .utf8)
        }
        ejected = set
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
        busy = true
        Task.detached {
            run(scriptPath, ["--now"])
            await MainActor.run {
                self.busy = false
                self.refresh()
            }
        }
    }

    func refresh() {
        let snapshot = shares
        Task.detached(priority: .utility) {
            let mountOut = run("/sbin/mount", ["-t", "smbfs"]).output
            var points: [String: String] = [:]
            for hs in snapshot.map(\.hostShare) {
                if let mp = mountPoint(of: hs, in: mountOut) { points[hs] = mp }
            }
            let mountPoints = points
            let ejected = Model.readEjected()
            var reach: [String: Bool] = [:]
            for h in Set(snapshot.map(\.host)) where !h.isEmpty {
                reach[h] = smbReachable(h)
            }
            let agent = run("/bin/launchctl", ["print", "gui/\(getuid())/\(agentLabel)"]).status == 0
            let lines = ((try? String(contentsOf: logFile, encoding: .utf8)) ?? "")
                .split(separator: "\n").suffix(50).reversed().map(String.init)
            let reachable = reach
            await MainActor.run {
                self.mountPoints = mountPoints
                self.ejected = ejected
                self.reachable = reachable
                self.agentLoaded = agent
                self.log = lines
            }
        }
    }
}

func showAlert(_ title: String, _ text: String) {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = text
    NSApp.activate()
    a.runModal()
}

// MARK: - Updates

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
        if !r.notes.isEmpty { text += "\n\n" + r.notes }
        a.informativeText = text
        a.addButton(withTitle: String(localized: "Install"))
        a.addButton(withTitle: String(localized: "Later"))
        NSApp.activate()
        if a.runModal() == .alertFirstButtonReturn {
            Task { await install(r) }
        }
    }

    // downloads the package and opens it in Installer; preinstall quits the app, postinstall relaunches it
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
            NSWorkspace.shared.open(pkg)
        } catch {
            info(String(localized: "Update Failed"), error.localizedDescription)
        }
    }

    private func info(_ title: String, _ text: String) {
        showAlert(title, text)
    }
}

// MARK: - Liquid Glass with fallback for macOS 14/15

extension View {
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 18) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }
}

// Colored background, stronger in dark mode so the glass stands out
struct Backdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            LinearGradient(
                colors: [Color.accentColor.opacity(dark ? 0.30 : 0.20), Color.purple.opacity(dark ? 0.16 : 0.08), .clear],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Color.cyan.opacity(dark ? 0.14 : 0.10), .clear],
                center: .bottomTrailing, startRadius: 0, endRadius: 520
            )
        }
        .ignoresSafeArea()
    }
}

struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

// MARK: - Main window

struct ShareCard: View {
    let share: Share
    let mounted: Bool
    let ejected: Bool
    let reachable: Bool?
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onEject: () -> Void
    let onMount: () -> Void
    @State private var hovering = false

    private var state: (icon: String, color: Color, text: LocalizedStringKey) {
        if mounted { return ("externaldrive.fill.badge.checkmark", .green, "Mounted") }
        if ejected { return ("eject.fill", .gray, "Ejected") }
        switch reachable {
        case true?: return ("externaldrive.fill.badge.wifi", .orange, "Reachable")
        case false?: return ("externaldrive.fill.badge.xmark", .gray, "Unreachable")
        default: return ("externaldrive.fill", .gray, "Checking…")
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: state.icon)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.pulse, isActive: reachable == nil && !mounted)
                .frame(width: 46, height: 46)
                .background(state.color.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: state.color.opacity(0.35), radius: 6, y: 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(share.name).font(.headline)
                Text(share.host).font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
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
            Divider()
            Button("Edit…", action: onEdit)
            Button("Connect in Finder") {
                if let u = URL(string: share.url) { NSWorkspace.shared.open(u) }
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
        VStack(spacing: 14) {
            ScrollView {
                GlassGroup {
                    VStack(spacing: 10) {
                        if m.shares.isEmpty {
                            ContentUnavailableView {
                                Label("No Shares", systemImage: "externaldrive.badge.plus")
                            } description: {
                                Text("Add an SMB share, e.g. smb://fileserver.example.com/team")
                            } actions: {
                                Button("Add Share") { add() }
                                    .glassButton(prominent: true)
                            }
                            .padding(.vertical, 30)
                        }
                        ForEach(m.shares) { share in
                            ShareCard(
                                share: share,
                                mounted: m.isMounted(share),
                                ejected: m.isEjected(share),
                                reachable: m.reachable[share.host],
                                onEdit: {
                                    editingIsNew = false
                                    editing = share
                                },
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

            if showLog {
                LogPanel(lines: m.log) { showLog = false }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            StatusBar(m: m)
                .zIndex(1)   // the log slides out from behind the status bar
        }
        .animation(.spring(duration: 0.35, bounce: 0.15), value: showLog)
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
        .confirmationDialog(
            "Remove Share?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { share in
            Button("Remove “\(share.name)”", role: .destructive) { m.delete(share) }
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

// MARK: - Editing with address check

struct Hint: View {
    enum Kind { case ok, info, warning, error }
    let kind: Kind
    let title: Text
    var detail: Text? = nil
    var actionTitle: LocalizedStringKey? = nil
    var action: (() -> Void)? = nil

    private var look: (String, Color) {
        switch kind {
        case .ok: return ("checkmark.circle.fill", .green)
        case .info: return ("info.circle.fill", .blue)
        case .warning: return ("exclamationmark.triangle.fill", .orange)
        case .error: return ("xmark.octagon.fill", .red)
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: look.0).foregroundStyle(look.1)
            VStack(alignment: .leading, spacing: 3) {
                title.fontWeight(.medium)
                if let detail {
                    detail.font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .controlSize(.small)
                        .glassButton()
                        .padding(.top, 2)
                }
            }
        }
    }
}

struct ShareEditor: View {
    @State var share: Share
    let isNew: Bool
    let onSave: (Share) -> Void
    @State private var check: HostCheck?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.connected.to.line.below")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                Text(isNew ? "New Share" : "Edit Share").font(.title2.bold())
                Spacer()
                Button {
                    openWindow(id: "help")
                } label: {
                    Image(systemName: "questionmark")
                }
                .glassButton()
                .buttonBorderShape(.circle)
                .help("Help on addresses, DNS names and IP addresses")
            }
            .padding([.horizontal, .top], 20)

            Form {
                Section {
                    TextField("Address", text: $share.url, prompt: Text(verbatim: "smb://server/share"))
                    TextField("Only in networks", text: $share.networks, prompt: Text("optional, e.g. 10.46.,192.168.1."))
                }
                Section("Check") {
                    VStack(alignment: .leading, spacing: 10) {
                        hints
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .formStyle(.grouped)
            .task(id: share.host) {
                check = nil
                let host = share.host
                guard share.isValid, !host.isEmpty else { return }
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                let result = await Task.detached { checkHost(host) }.value
                if !Task.isCancelled { check = result }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .glassButton()
                Button("Save") {
                    share.url = share.url.trimmingCharacters(in: .whitespaces)
                    onSave(share)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!share.isValid)
                .glassButton(prominent: true)
            }
            .controlSize(.large)
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 520)
    }

    @ViewBuilder
    private var hints: some View {
        if let suggestion = share.suggestedURL {
            Hint(kind: .warning, title: Text("Address in the wrong format"),
                 detail: Text("SMB addresses have the form smb://server/share."),
                 actionTitle: "Convert to \(suggestion)") { share.url = suggestion }
        } else if !share.isValid {
            Hint(kind: .info, title: Text("Enter an address"),
                 detail: Text("Form: smb://server/share. Server as DNS name (recommended, e.g. fileserver.example.com) or as IP address. Optionally with user: smb://name@server/share"))
        } else if let check, check.host == share.host {
            dnsHints(check)
            if check.reachable {
                Hint(kind: .ok, title: Text("SMB server responds (port 445)"),
                     detail: Text("The share will be mounted after saving. The first time, connect with the link button and save the password in the keychain."))
            } else if check.dns != .failed {
                Hint(kind: .warning, title: Text("SMB server is not responding right now"),
                     detail: Text("That is fine if you are not in the office network or the VPN is not running: the share is mounted automatically as soon as the server is reachable. Otherwise check the server name and firewall."))
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking \(share.host)…").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func dnsHints(_ c: HostCheck) -> some View {
        switch c.dns {
        case .failed:
            Hint(kind: .error, title: Text("“\(c.host)” cannot be resolved"), detail: failedDetail(c.host))
        case .resolved(let addrs):
            let isInternal = addrs.contains(where: isPrivateIP)
            Hint(kind: .ok, title: Text("Name resolved: \(addrs.prefix(3).joined(separator: ", "))"),
                 detail: isInternal
                    ? Text("Internal address: the server is only reachable in the office network or over VPN. That is exactly when it gets mounted.")
                    : Text("Public address. SMB over the internet is usually blocked; check that this really is the right server."))
            if !c.host.contains(".") {
                Hint(kind: .warning, title: Text("Short name without domain"),
                     detail: Text("Short names only work with a matching search domain and often not over VPN. Better use the full name, e.g. \(fullNameExample(c.host))."))
            }
        case .ip:
            if let name = c.reverseName {
                Hint(kind: .info, title: Text("IP address belongs to \(name)"),
                     detail: Text("A DNS name is more robust: the address can change, and the keychain entry is tied to the server name."),
                     actionTitle: "Use name") { share.url = share.replacingHost(with: name) }
            } else {
                Hint(kind: .info, title: Text("IP address without DNS name"),
                     detail: Text("Works, but the address can change. Use a DNS name if possible."))
            }
            if isPrivateIP(c.host) && share.networkList.isEmpty {
                Hint(kind: .warning, title: Text("Private IP without network restriction"),
                     detail: Text("Addresses like \(c.host) exist in many networks (e.g. at home or in a hotel). Enter your office network's prefix under “Only in networks” so no other device gets contacted."),
                     actionTitle: "Use prefix \(prefix24(c.host))") { share.networks = prefix24(c.host) }
            }
        }
    }

    private func failedDetail(_ host: String) -> Text {
        if host.hasSuffix(".local") {
            return Text(".local names (Bonjour) only work in the same local network, not over VPN. Is the device switched on and are you in the same network?")
        }
        var text = Text("Possible reasons: a typo in the name; internal names often only resolve while the VPN is running. Start the VPN and check again.")
        if !host.contains(".") {
            text = text + Text(verbatim: " ") + Text("Short names need a search domain. Try the full name, e.g. \(fullNameExample(host)).")
        }
        return text + Text(verbatim: " ") + Text("You can save anyway; the share is mounted as soon as the name resolves and the server is reachable.")
    }

    private func prefix24(_ ip: String) -> String {
        ip.split(separator: ".").prefix(3).joined(separator: ".") + "."
    }
}

// MARK: - Help

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.tint)
                    Text("Mountwell Help").font(.title.bold())
                }
                section("How it works", "bolt.horizontal.circle", """
                    On every network change, and every minute in addition, a background service checks whether the servers of your shares respond on SMB port 445. If a server responds, its shares are mounted; once it stops responding (different network, VPN disconnected), they are unmounted. So Finder never hangs on dead connections.
                    """)
                section("Entering an address", "link", """
                    Form: **smb://server/share**, e.g. smb://fileserver.example.com/team.
                    With user name: smb://name@server/share.
                    A Windows path like `\\\\server\\share` is detected while editing and converted.
                    """)
                section("DNS name or IP address?", "network", """
                    **Use the full DNS name if possible** (e.g. fileserver.example.com):
                    • IP addresses can change, names stay.
                    • The password saved in the keychain belongs to the server name.
                    • Private IP addresses (10.x, 172.16–31.x, 192.168.x) exist in many networks. At home or in a hotel, a different device can sit at the same address.

                    **Use an IP address only if there is no name**, and then enter the prefix of the right network under “Only in networks”.

                    While you type, the app checks the name: it shows the resolved address, suggests the matching name for an IP and warns about short names.
                    """)
                section("Name cannot be resolved?", "exclamationmark.magnifyingglass", """
                    • **Internal names** often only resolve in the office network or while the VPN is running. That is normal: the share is mounted as soon as you are connected.
                    • **Short names** (e.g. “fileserver”) need a matching search domain. Better enter the full name.
                    • **.local names** (Bonjour, e.g. nas.local) only work in the same local network, not over VPN.
                    • A typo? In Terminal, this helps: `host fileserver.example.com`
                    """)
                section("Only in networks", "line.3.horizontal.decrease.circle", """
                    Optional, comma-separated, e.g. **10.46.,192.168.1.**: the share is then only mounted when one of your own IP addresses starts with one of these prefixes. Leave it empty to always mount when the server is reachable. For servers with a DNS name and an internal address, this is usually not needed.
                    """)
                section("Ejecting", "eject", """
                    Use the **eject button** on a share, or its entry in the menu bar, to unmount it by hand. Mountwell then leaves it alone until you mount it again or the server goes out of reach, e.g. when you leave the office network. Ejecting in Finder does not work for this: the background service mounts the share again within a minute.
                    """)
                section("Password", "key", """
                    The background service takes the password from the keychain. So connect once per share with the **link button** and choose **“Remember this password in my keychain”** in the Finder dialog.
                    """)
                section("Troubleshooting", "stethoscope", """
                    • The log shows every mount and unmount. Show it via **View → Show Log** (⌘L).
                    • Red status dot at the bottom left: the background service is not loaded. Click “Load”.
                    • “Automatic” switch off: the service does nothing.
                    • Terminal: `tail -f ~/Library/Logs/mountwell.log`
                    """)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 520, idealWidth: 580, minHeight: 500, idealHeight: 640)
        .background { Backdrop() }
    }

    private func section(_ title: LocalizedStringKey, _ icon: String, _ text: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.headline)
            Text(text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 16)
    }
}

// MARK: - App

struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @AppStorage("showLog") private var showLog = false

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Mountwell") { showAbout() }
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
            Button("Mountwell Help") { openWindow(id: "help") }
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

// MARK: - Menu bar

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
            let reachable = m.reachable[share.host] == true
            let icon = m.isMounted(share) ? "checkmark.circle.fill"
                : m.isEjected(share) ? "eject.circle" : reachable ? "circle" : "xmark.circle"
            Menu {
                if let mp = m.mountPoints[share.hostShare] {
                    Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: mp)) }
                    Button("Eject") { m.eject(share) }
                } else {
                    Button("Mount") { m.mount(share) }
                        .disabled(!reachable)
                }
            } label: {
                Label(share.name, systemImage: icon)
            }
        }
        Divider()
        Toggle("Mount Automatically", isOn: Binding(get: { m.enabled }, set: { m.setEnabled($0) }))
        Button("Check Now") { m.runNow() }
            .disabled(m.busy || !m.enabled)
        Divider()
        Button("Open Mountwell…") { showWindow("main", openWindow) }
        Toggle("Open at Login", isOn: Binding(get: { m.launchAtLogin }, set: { m.setLaunchAtLogin($0) }))
        if updateRepo != nil {
            Button("Check for Updates…") { Task { await updater.check(manual: true) } }
                .disabled(updater.busy)
        }
        Divider()
        Button("Quit Mountwell") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
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
        // started as login item: stay quiet, no window
        let event = NSAppleEventManager.shared().currentAppleEvent
        if event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
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

@main
struct MountwellApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var m = Model()

    var body: some Scene {
        // Window, not WindowGroup: a single main window, otherwise several Models overwrite each other
        Window("Mountwell", id: "main") {
            ContentView(m: m)
        }
        .windowResizability(.contentSize)   // height follows the share list, see ContentView.listHeight
        .windowToolbarStyle(.unified)
        .commands { AppCommands() }

        Window("Mountwell Help", id: "help") {
            HelpView()
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra("Mountwell", systemImage: m.menuBarIcon) {
            MenuBarMenu(m: m)
        }
    }
}
