// smb-mount <url>: mounts an SMB share under /Volumes without any dialog.
// mountwell.sh uses it instead of AppleScript's "mount volume". That one let macOS ask
// "You are attempting to connect to the server" and then for name and password whenever
// the keychain held no password; the dialog waited for a click, the script with it, and
// launchd started no further run, so no other share was mounted or unmounted meanwhile.
// With no UI the mount fails at once instead.
//
// Exit 0 when mounted, 3 when the server wants a password the keychain does not have,
// 1 for any other failure. The NetFS error number goes to stderr.

import Foundation
import NetFS

guard CommandLine.arguments.count == 2, let url = URL(string: CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: smb-mount <smb://...>\n".utf8))
    exit(2)
}

let openOptions = NSMutableDictionary()
openOptions[kNAUIOptionKey] = kNAUIOptionNoUI
var mountpoints: Unmanaged<CFArray>?
let rc = NetFSMountURLSync(url as CFURL, nil, nil, nil, openOptions, nil, &mountpoints)
mountpoints?.release()
if rc == 0 { exit(0) }
FileHandle.standardError.write(Data("smb-mount: error \(rc)\n".utf8))
exit(rc == EAUTH || rc == EACCES || rc == Int32(ENETFSNOAUTHMECHSUPP) ? 3 : 1)
