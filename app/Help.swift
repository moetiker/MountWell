// The Help window (A-12).

import SwiftUI

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.tint)
                    Text("MountWell Help").font(.title.bold())
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
                section("Alias", "tag", """
                    Optional name for a share, e.g. **Photos at home**. The window and the menu bar show it instead of the share name. Without an alias the menu bar shows **server/share**. The folder in /Volumes keeps the share's own name.
                    """)
                section("Importing and switching off", "square.and.arrow.down.on.square", """
                    **Import Mounted Shares…** in the menu bar menu proposes every SMB share that is mounted right now but not in MountWell yet, for example one you connected to in Finder. Check the address, network limit and alias, then import.

                    **Mount Automatically** in a share's context menu, its edit window or its menu bar entry turns it off without removing it: MountWell then neither mounts nor unmounts it. **Mount** still works by hand.
                    """)
                section("When DNS fails", "point.3.connected.trianglepath.dotted", """
                    While a server name resolves, the background service remembers its IP address, the network you are in (address range and router) and the server's SMB ID. If the name later does not resolve (DNS down, VPN DNS broken), it mounts the share via that address, but only in the same network and only if the same server answers there. A different device at the same address in another office or at home gets no login attempt. The card shows the address next to the server.

                    The keychain password belongs to the server name. So connect once via the address too: right-click the share → **Connect via … in Finder** and save the password. Until then a crossed-out key shows next to the address and the fallback is not used. Servers that only allow Kerberos (Active Directory) logins do not work via the address.

                    A share entered **by IP address** is pinned the same way on its first mount, once per network. In a network where it has not been mounted yet, connect it by hand once; after that it mounts there by itself. If a server is replaced, choose **Forget Remembered Server** in its context menu.
                    """)
                section("Ejecting", "eject", """
                    Use the **eject button** on a share, or its entry in the menu bar, to unmount it by hand. MountWell then leaves it alone until you mount it again or the server goes out of reach, e.g. when you leave the office network. Ejecting in Finder does not work for this: the background service mounts the share again within a minute.
                    """)
                section("Password", "key", """
                    The background service takes the password from the keychain. So connect once per share with the **link button** and choose **“Remember this password in my keychain”** in the Finder dialog.
                    """)
                section("Starting at login", "power", """
                    **Run at Login** starts MountWell when you log in; it then sits in the menu bar. With **Show Window at Login**, the window opens as well. Both are in the menu bar menu and in **MountWell → Settings** (⌘,). The background service mounts your shares even when MountWell is not running.
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
