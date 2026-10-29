// Logic without UI: processes, name resolution, share addresses.
// Used by the app and by tests/main.swift.

import Foundation

@discardableResult
func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

func smbReachable(_ host: String) -> Bool {
    run("/usr/bin/nc", ["-z", "-G", "2", host, "445"]).status == 0
}

// MARK: - Name resolution

func isIPAddress(_ s: String) -> Bool {
    var a4 = in_addr()
    var a6 = in6_addr()
    return inet_pton(AF_INET, s, &a4) == 1 || inet_pton(AF_INET6, s, &a6) == 1
}

func isPrivateIP(_ ip: String) -> Bool {
    if ip.hasPrefix("10.") || ip.hasPrefix("192.168.") || ip.lowercased().hasPrefix("fd") { return true }
    if ip.hasPrefix("172."), let second = Int(ip.split(separator: ".")[1]) { return (16...31).contains(second) }
    return false
}

func resolve(_ host: String) -> [String] {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return [] }
    defer { freeaddrinfo(first) }
    var out: [String] = []
    var p: UnsafeMutablePointer<addrinfo>? = first
    while let ai = p {
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
            let s = String(cString: buf)
            if !out.contains(s) { out.append(s) }
        }
        p = ai.pointee.ai_next
    }
    return out
}

func reverseLookup(_ ip: String) -> String? {
    var hints = addrinfo()
    hints.ai_flags = AI_NUMERICHOST
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(ip, nil, &hints, &res) == 0, let ai = res else { return nil }
    defer { freeaddrinfo(ai) }
    var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    guard getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NAMEREQD) == 0
    else { return nil }
    return String(cString: buf)
}

struct HostCheck: Equatable {
    enum DNS: Equatable { case ip, resolved([String]), failed }
    var host: String
    var dns: DNS
    var reachable: Bool
    var reverseName: String?
}

func checkHost(_ host: String) -> HostCheck {
    if isIPAddress(host) {
        return HostCheck(host: host, dns: .ip, reachable: smbReachable(host), reverseName: reverseLookup(host))
    }
    let addrs = resolve(host)
    if addrs.isEmpty { return HostCheck(host: host, dns: .failed, reachable: false) }
    return HostCheck(host: host, dns: .resolved(addrs), reachable: smbReachable(host))
}

// MARK: - Data

struct Share: Identifiable, Equatable {
    var id = UUID()
    var url: String
    var networks: String
    var alias = ""
    // false: the service leaves the share alone ("!" in shares.conf)
    var enabled = true

    // what the UI shows: the alias, or else the share name
    var title: String {
        let a = alias.trimmingCharacters(in: .whitespaces)
        return a.isEmpty ? name : a
    }

    // the menu bar menu has no second line: the alias, or else "server/share"
    var menuTitle: String {
        title == name ? "\(host)/\(name)" : title
    }

    // "server/share" in lower case, as it appears in the mount output
    var hostShare: String {
        var r = url.trimmingCharacters(in: .whitespaces)
        if r.lowercased().hasPrefix("smb://") { r = String(r.dropFirst(6)) }
        if let at = r.firstIndex(of: "@"), at < (r.firstIndex(of: "/") ?? r.endIndex) {
            r = String(r[r.index(after: at)...])
        }
        return r.lowercased()
    }

    var host: String { String(hostShare.split(separator: "/").first ?? "") }

    var name: String {
        let parts = url.split(separator: "/")
        return parts.count >= 3 ? String(parts.last!).removingPercentEncoding ?? String(parts.last!) : url
    }

    var networkList: [String] {
        networks.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var isValid: Bool {
        url.lowercased().hasPrefix("smb://") && hostShare.split(separator: "/").count >= 2
    }

    // \\server\share (Windows) or server/share → smb://server/share
    var suggestedURL: String? {
        let t = url.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("\\\\") {
            return "smb://" + t.dropFirst(2).replacingOccurrences(of: "\\", with: "/")
        }
        if !t.contains("://"), t.contains("/"), !t.hasPrefix("/") {
            return "smb://" + t
        }
        return nil
    }

    // "server/share" with the server replaced, e.g. by its remembered IP
    func hostShare(via ip: String) -> String {
        ip.lowercased() + hostShare.dropFirst(host.count)
    }

    // only the server part: "smb://nas@nas/x" keeps its user name, a server called "smb"
    // keeps the scheme
    func replacingHost(with newHost: String) -> String {
        let t = url.trimmingCharacters(in: .whitespaces)
        guard t.lowercased().hasPrefix("smb://") else { return url }
        var start = t.index(t.startIndex, offsetBy: 6)
        let slash = t[start...].firstIndex(of: "/") ?? t.endIndex
        if let at = t[start..<slash].firstIndex(of: "@") { start = t.index(after: at) }
        return String(t[..<start]) + newHost + t[slash...]
    }
}

// MARK: - Updates (GitHub Releases)

struct Release: Equatable {
    var version: String
    var pkgURL: URL
    var pageURL: URL?
    var notes: String
}

// "v1.10" is newer than "1.9"; missing components count as 0
func isNewer(_ a: String, than b: String) -> Bool {
    func parts(_ v: String) -> [Int] {
        let t = v.hasPrefix("v") || v.hasPrefix("V") ? String(v.dropFirst()) : v
        return t.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }
    let x = parts(a), y = parts(b)
    for i in 0..<max(x.count, y.count) {
        let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
        if l != r { return l > r }
    }
    return false
}

// response of api.github.com/repos/<repo>/releases/latest; nil without a .pkg file
func parseRelease(_ data: Data) -> Release? {
    struct Asset: Decodable { let name: String; let browser_download_url: URL }
    struct GitHubRelease: Decodable { let tag_name: String; let html_url: URL?; let body: String?; let assets: [Asset] }
    guard let r = try? JSONDecoder().decode(GitHubRelease.self, from: data),
          let pkg = r.assets.first(where: { $0.name.lowercased().hasSuffix(".pkg") })
    else { return nil }
    let version = r.tag_name.hasPrefix("v") ? String(r.tag_name.dropFirst()) : r.tag_name
    return Release(version: version, pkgURL: pkg.browser_download_url, pageURL: r.html_url, notes: r.body ?? "")
}

// first search domain of the Mac (macOS maintains /etc/resolv.conf from the network configuration)
func searchDomain() -> String? {
    guard let text = try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8) else { return nil }
    for line in text.split(separator: "\n") {
        let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        if f.count >= 2, f[0] == "search" || f[0] == "domain" { return String(f[1]) }
    }
    return nil
}

// example of a full name for a short name
func fullNameExample(_ host: String) -> String {
    "\(host).\(searchDomain() ?? "example.com")"
}

// One shares.conf line: "[!]smb://[user@]server/share [prefix,prefix] [# alias]",
// "!" marks a disabled share. nil for blank lines and comment lines.
func parseShareLine(_ line: String) -> Share? {
    var t = line.trimmingCharacters(in: .whitespaces)
    guard !t.isEmpty, !t.hasPrefix("#") else { return nil }
    let enabled = !t.hasPrefix("!")
    if !enabled { t = t.dropFirst().trimmingCharacters(in: .whitespaces) }
    guard !t.isEmpty else { return nil }
    var alias = ""
    if let hash = t.firstIndex(of: "#") {
        alias = t[t.index(after: hash)...].trimmingCharacters(in: .whitespaces)
        t = t[..<hash].trimmingCharacters(in: .whitespaces)
    }
    let parts = t.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
    let nets = parts.count > 1 ? parts[1].replacingOccurrences(of: " ", with: "") : ""
    return Share(url: String(parts[0]), networks: nets, alias: alias, enabled: enabled)
}

func shareLine(_ s: Share) -> String? {
    let url = s.url.trimmingCharacters(in: .whitespaces)
    guard !url.isEmpty else { return nil }
    var line = (s.enabled ? "" : "!") + url
    let nets = s.networks.replacingOccurrences(of: " ", with: "")
    if !nets.isEmpty { line += " \(nets)" }
    // "#" would start a new alias when the line is read back
    let alias = s.alias.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces)
    if !alias.isEmpty { line += " # \(alias)" }
    return line
}

// mount point of "server/share" in the output of `mount -t smbfs`, e.g.
// "//user@server/share on /Volumes/share (smbfs, ...)"; case-insensitive
func mountPoint(of hostShare: String, in mountOutput: String) -> String? {
    for line in mountOutput.split(separator: "\n") {
        // the name must start right after "@" or "//", so "example.com" does not match "fileserver.example.com"
        guard let r = line.range(of: "\(hostShare) on ", options: .caseInsensitive),
              r.lowerBound > line.startIndex, "@/".contains(line[line.index(before: r.lowerBound)]),
              let end = line.range(of: " (smbfs", options: .backwards), r.upperBound <= end.lowerBound
        else { continue }
        return String(line[r.upperBound..<end.lowerBound])
    }
    return nil
}

// ~/.config/mountwell/servers.yaml, written by mountwell.sh: a list under "servers:" of
// name, ip, network, router, server_id and seen, one entry per name and network.
// Lower-case name → its IPs in file order, for entries with all fields, as the script
// reads them.
func parseServers(_ yaml: String) -> [String: [String]] {
    var out: [String: [String]] = [:]
    var entry: [String: String] = [:]
    func flush() {
        if let n = entry["name"], let ip = entry["ip"], isIPAddress(ip),
           ["network", "router", "server_id"].allSatisfy({ entry[$0] != nil }) {
            if !(out[n.lowercased()] ?? []).contains(ip) { out[n.lowercased(), default: []].append(ip) }
        }
        entry = [:]
    }
    for line in yaml.split(separator: "\n") {
        let l = String(line)
        let item = l.hasPrefix("  - ")
        guard item || l.hasPrefix("    "), let colon = l.firstIndex(of: ":") else { continue }
        if item { flush() }
        let key = l[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: " -"))
        let value = l[l.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        entry[key] = value
    }
    flush()
    return out
}

// servers.yaml without the entry of one server name
func forgettingServer(_ name: String, in yaml: String) -> String {
    var out: [Substring] = []
    var skipping = false
    for line in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix("  - ") {
            let value = line.drop(while: { $0 != ":" }).dropFirst()
                .trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            skipping = line.hasPrefix("  - name:") && value.lowercased() == name.lowercased()
        } else if !line.hasPrefix("    ") {
            skipping = false
        }
        if !skipping { out.append(line) }
    }
    var text = out.joined(separator: "\n")
    // the last entry gone: the script writes an empty list the same way
    if !text.contains("\n  - ") { text = text.replacingOccurrences(of: "\nservers:\n", with: "\nservers: []\n") }
    return text
}

// SMB shares in the output of `mount -t smbfs` that are not configured yet, as proposals
// for shares.conf. "//[domain;]user[:password]@server/share on /Volumes/x (smbfs, ...)";
// a password never goes into the address.
func importProposals(_ mountOutput: String, configured: [Share], servers: [String: [String]] = [:]) -> [(share: Share, mountPoint: String)] {
    // a configured share mounted via one of its remembered IPs is not new either
    var known = Set(configured.flatMap { s in [s.hostShare] + (servers[s.host] ?? []).map { s.hostShare(via: $0) } })
    var out: [(share: Share, mountPoint: String)] = []
    for line in mountOutput.split(separator: "\n") {
        guard line.hasPrefix("//"), let on = line.range(of: " on "),
              let end = line.range(of: " (smbfs", options: .backwards), on.upperBound <= end.lowerBound
        else { continue }
        var addr = String(line[line.index(line.startIndex, offsetBy: 2)..<on.lowerBound])
        if let at = addr.firstIndex(of: "@") {
            let user = addr[..<at].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)[0]
            addr = (user.isEmpty ? "" : "\(user)@") + addr[addr.index(after: at)...]
        }
        let share = Share(url: "smb://" + addr, networks: "")
        guard share.isValid, known.insert(share.hostShare).inserted else { continue }
        out.append((share, String(line[on.upperBound..<end.lowerBound])))
    }
    return out
}

// "192.168.10.20" → "192.168.10."
func prefix24(_ ip: String) -> String {
    ip.split(separator: ".").prefix(3).joined(separator: ".") + "."
}

// Team ID of a package signed with a Developer ID Installer certificate, read from the
// output of `pkgutil --check-signature`: "1. Developer ID Installer: Name (TEAMID)".
// nil for unsigned packages and any other kind of signature. Whether the chain is
// trusted is pkgutil's exit status, which the caller checks.
func installerTeamID(_ output: String) -> String? {
    let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    guard lines.contains("Status: signed by a developer certificate issued by Apple for distribution"),
          let leaf = lines.first(where: { $0.hasPrefix("1. ") }),
          leaf.hasPrefix("1. Developer ID Installer: "), leaf.hasSuffix(")"),
          lines.contains("2. Developer ID Certification Authority"),
          lines.contains("3. Apple Root CA"),
          let open = leaf.lastIndex(of: "(")
    else { return nil }
    let team = String(leaf[leaf.index(after: open)..<leaf.index(before: leaf.endIndex)])
    return isTeamID(team) ? team : nil
}

// Apple team IDs are 10 characters, upper-case letters and digits
func isTeamID(_ s: String) -> Bool {
    s.count == 10 && s.allSatisfy { ($0.isUppercase || $0.isNumber) && $0.isASCII }
}

// Release notes for a plain-text alert: "### Fixed" → "Fixed:", without `code` and **bold** marks
func plainNotes(_ markdown: String) -> String {
    markdown.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
        var l = String(line)
        if l.hasPrefix("#") {
            l = l.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            if !l.isEmpty { l += ":" }
        }
        return l.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
    }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - SMB server ID

// SMB2 NEGOTIATE request with its NetBIOS session header. The answer carries the
// server's ServerGuid; nothing is authenticated and no credentials are sent.
// Offers SMB 2.0.2 to 3.1.1; 3.1.1 requires the pre-authentication integrity context.
func smbNegotiateRequest() -> [UInt8] {
    func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8 & 0xff)] }
    func le32(_ v: Int) -> [UInt8] { le16(v & 0xffff) + le16(v >> 16) }
    let dialects = [0x0202, 0x0210, 0x0300, 0x0302, 0x0311]
    var header: [UInt8] = [0xfe, 0x53, 0x4d, 0x42] + le16(64)   // "\u{fe}SMB", StructureSize
    header += [UInt8](repeating: 0, count: 6)                   // CreditCharge, Status
    header += le16(0) + le16(1)                                 // NEGOTIATE, CreditRequest
    header += [UInt8](repeating: 0, count: 64 - header.count)   // flags, ids, signature
    let contextOffset = 112                                     // 64 + 36 + 10, 8-aligned
    var body = le16(36) + le16(dialects.count) + le16(1) + le16(0) + le32(0)
    body += (0..<16).map { _ in UInt8.random(in: 0...255) }     // ClientGuid
    body += le32(contextOffset) + le16(1) + le16(0)
    body += dialects.flatMap { le16($0) }
    body += [UInt8](repeating: 0, count: contextOffset - 64 - body.count)
    let salt = (0..<32).map { _ in UInt8.random(in: 0...255) }
    let preauth = le16(1) + le16(salt.count) + le16(1) + salt   // one hash: SHA-512
    body += le16(1) + le16(preauth.count) + le32(0) + preauth
    let message = header + body
    return [0, UInt8(message.count >> 16 & 0xff), UInt8(message.count >> 8 & 0xff), UInt8(message.count & 0xff)] + message
}

// ServerGuid as 32 lower-case hex digits from a NEGOTIATE response (with NetBIOS header);
// nil for anything else, an SMB1-only server or an error status included
func smbServerGUID(_ r: [UInt8]) -> String? {
    guard r.count >= 4 + 64 + 24,
          r[4..<8].elementsEqual([0xfe, 0x53, 0x4d, 0x42]),
          r[12..<16].allSatisfy({ $0 == 0 }),                     // STATUS_SUCCESS
          r[16] == 0, r[17] == 0,                                 // NEGOTIATE
          r[68] == 65, r[69] == 0                                 // response StructureSize
    else { return nil }
    let guid = r[76..<92]
    guard guid.contains(where: { $0 != 0 }) else { return nil }
    return guid.map { String(format: "%02x", $0) }.joined()
}
