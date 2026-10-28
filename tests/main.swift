// Tests for app/Core.swift (no UI). Run via tests/run.sh.
// Named main.swift because Swift only allows top-level code there.

import Foundation

var failures = 0
var count = 0

func check<T: Equatable>(_ got: T, _ expected: T, _ what: String, line: Int = #line) {
    count += 1
    if got != expected {
        failures += 1
        print("FAIL line \(line): \(what)\n     expected: \(expected)\n     got:      \(got)")
    }
}

// Share addresses
let s = Share(url: "smb://fileserver.example.com/team", networks: "")
check(s.hostShare, "fileserver.example.com/team", "hostShare simple")
check(s.host, "fileserver.example.com", "host simple")
check(s.name, "team", "name simple")
check(s.isValid, true, "valid address")

let u = Share(url: "smb://Anna@FileServer.Example.com/Photos", networks: "")
check(u.hostShare, "fileserver.example.com/photos", "hostShare without user, lowercase")
check(u.host, "fileserver.example.com", "host without user")
check(u.name, "Photos", "name keeps its case")

check(Share(url: "smb://srv/My%20Files", networks: "").name, "My Files", "name decodes %20")
check(Share(url: "smb://srv/share/sub/dir", networks: "").hostShare, "srv/share/sub/dir", "subdirectory")

check(Share(url: "smb://", networks: "").isValid, false, "scheme only is invalid")
check(Share(url: "smb://srv", networks: "").isValid, false, "without share is invalid")
check(Share(url: "srv/share", networks: "").isValid, false, "without scheme is invalid")
check(Share(url: "SMB://srv/share", networks: "").isValid, true, "scheme in upper case")

// Conversion suggestions
check(Share(url: "\\\\srv\\share", networks: "").suggestedURL, "smb://srv/share", "Windows path")
check(Share(url: "\\\\srv\\share\\sub", networks: "").suggestedURL, "smb://srv/share/sub", "Windows path with subfolder")
check(Share(url: "srv/share", networks: "").suggestedURL, "smb://srv/share", "missing scheme")
check(Share(url: "smb://srv/share", networks: "").suggestedURL, nil, "valid address, no suggestion")
check(Share(url: "/Volumes/x", networks: "").suggestedURL, nil, "local path, no suggestion")
check(Share(url: "smb://", networks: "").suggestedURL, nil, "empty input, no suggestion")

// Replace host (IP → name)
check(Share(url: "smb://192.168.10.20/photos", networks: "").replacingHost(with: "fileserver.example.com"),
      "smb://fileserver.example.com/photos", "replace IP with name")
check(Share(url: "smb://me@192.168.10.20/photos", networks: "").replacingHost(with: "srv.example.ch"),
      "smb://me@srv.example.ch/photos", "replace IP with name, with user")

// Network prefixes
check(Share(url: "smb://a/b", networks: "10.46., 192.168.1.").networkList, ["10.46.", "192.168.1."], "prefix list")
check(Share(url: "smb://a/b", networks: "").networkList, [], "empty prefix list")
check(Share(url: "smb://a/b", networks: ",,10.,").networkList, ["10."], "ignore empty entries")

// IP addresses
check(isIPAddress("192.168.10.20"), true, "IPv4")
check(isIPAddress("fd00::1"), true, "IPv6")
check(isIPAddress("fileserver.example.com"), false, "name is not an IP")
check(isIPAddress("192.168.0"), false, "incomplete IPv4")
check(isPrivateIP("10.46.105.116"), true, "10/8 private")
check(isPrivateIP("192.168.10.20"), true, "192.168/16 private")
check(isPrivateIP("172.16.0.1"), true, "172.16 private")
check(isPrivateIP("172.31.255.1"), true, "172.31 private")
check(isPrivateIP("172.15.0.1"), false, "172.15 public")
check(isPrivateIP("172.32.0.1"), false, "172.32 public")
check(isPrivateIP("8.8.8.8"), false, "8.8.8.8 public")
check(isPrivateIP("fd12::1"), true, "IPv6 ULA private")

// Name resolution (local, no network)
let lh = resolve("localhost")
check(lh.contains("127.0.0.1") || lh.contains("::1"), true, "localhost resolves")
check(resolve("does-not-exist.invalid"), [], ".invalid does not resolve")
check(checkHost("does-not-exist.invalid").dns, .failed, "checkHost: does not resolve")
check(checkHost("127.0.0.1").dns, .ip, "checkHost: IP detected")

// Mount points from `mount -t smbfs`
let mountOut = """
    //anna@fileserver.example.com/team on /Volumes/team (smbfs, nodev, nosuid, mounted by anna)
    //anna@fileserver.example.com/My%20Files on /Volumes/My Files (smbfs, nodev, nosuid, mounted by anna)
    //anna@srv.example/share-old on /Volumes/share-old (smbfs, nodev, nosuid, mounted by anna)
    """
check(mountPoint(of: "fileserver.example.com/team", in: mountOut), "/Volumes/team", "mount point")
check(mountPoint(of: "FileServer.Example.com/Team", in: mountOut), "/Volumes/team", "mount point ignores case")
check(mountPoint(of: "fileserver.example.com/my%20files", in: mountOut), "/Volumes/My Files", "mount point with space")
check(mountPoint(of: "srv.example/share", in: mountOut), nil, "similar name is not a mount point")
check(mountPoint(of: "example.com/team", in: mountOut), nil, "host suffix is not a match")

// Version comparison
check(isNewer("1.1", than: "1.0"), true, "1.1 > 1.0")
check(isNewer("1.10", than: "1.9"), true, "1.10 > 1.9 (numeric)")
check(isNewer("v1.1", than: "1.1"), false, "v prefix, same version")
check(isNewer("1.0.1", than: "1.0"), true, "extra component")
check(isNewer("1.0", than: "1.0.0"), false, "1.0 = 1.0.0")
check(isNewer("0.9", than: "1.0"), false, "older version")
check(isNewer("1.0", than: "dev"), true, "development build is older")

// Reading a GitHub release
let releaseJSON = """
    {"tag_name": "v1.2", "html_url": "https://github.com/o/r/releases/tag/v1.2", "body": "New: updates",
     "assets": [{"name": "notes.txt", "browser_download_url": "https://x/notes.txt"},
                {"name": "Mountwell-1.2.pkg", "browser_download_url": "https://x/Mountwell-1.2.pkg"}]}
    """
let rel = parseRelease(Data(releaseJSON.utf8))
check(rel?.version, "1.2", "release: version without v")
check(rel?.pkgURL.absoluteString, "https://x/Mountwell-1.2.pkg", "release: .pkg file chosen")
check(rel?.notes, "New: updates", "release: notes")
check(parseRelease(Data(#"{"tag_name": "v1.3", "assets": []}"#.utf8)), nil, "ignore release without .pkg")
check(parseRelease(Data("no json".utf8)), nil, "invalid response")

// Release notes as plain text
check(plainNotes("### Fixed\n- `example.com` is **no** match\n"), "Fixed:\n- example.com is no match", "notes without Markdown")
check(plainNotes("## 1.0 - 2026-01-01\n### New\n- a"), "1.0 - 2026-01-01:\nNew:\n- a", "headings become labels")

// Optionally a real internal server: MOUNTWELL_TEST_SERVER=fileserver.example.com tests/run.sh
if let server = ProcessInfo.processInfo.environment["MOUNTWELL_TEST_SERVER"], !server.isEmpty {
    if !resolve(server).isEmpty {
        let c = checkHost(server)
        if case .resolved(let addrs) = c.dns {
            check(addrs.contains(where: isPrivateIP), true, "\(server) has an internal address")
        } else {
            check("\(c.dns)", "resolved", "\(server) resolves")
        }
        print("info: \(server) reachable: \(c.reachable)")
    } else {
        print("info: \(server) does not resolve, network test skipped")
    }
}

print("\(count - failures)/\(count) Swift tests ok")
exit(failures == 0 ? 0 : 1)
