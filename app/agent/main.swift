// mountwell-agent: the program launchd starts for the LaunchAgent ch.oetiker.mountwell.
// Runs the script Contents/Resources/mountwell and passes on its exit status.
// launchd starting the script itself showed the service in Login Items as from an unknown
// developer: AssociatedBundleIdentifiers ties a job to the app only when its program is
// signed by the app's team (I-6). The script runs as a child, not via exec, so this signed
// program stays the process macOS holds responsible for it.

import Foundation

let script = Bundle.main.path(forResource: "mountwell", ofType: nil)
    ?? "/Applications/MountWell.app/Contents/Resources/mountwell"
let p = Process()
p.executableURL = URL(fileURLWithPath: script)
p.arguments = Array(CommandLine.arguments.dropFirst())
do {
    try p.run()
} catch {
    FileHandle.standardError.write(Data("mountwell-agent: \(script): \(error)\n".utf8))
    exit(1)
}
p.waitUntilExit()
exit(p.terminationStatus)
