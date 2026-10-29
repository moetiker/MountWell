// Editing a share, with the address check while typing (A-4).

import AppKit
import SwiftUI

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
                    TextField("Alias", text: $share.alias, prompt: Text("optional, shown instead of the share name"))
                    Toggle("Mount automatically", isOn: $share.enabled)
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

}
