// Import Mounted Shares (A-18).

import SwiftUI

struct ImportItem: Identifiable {
    let id = UUID()
    var share: Share
    let mountPoint: String
    var selected = true
}

struct ImportSheet: View {
    @State var items: [ImportItem]
    let onImport: ([ImportItem]) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import Mounted Shares").font(.title2.bold())
                    Text("These SMB shares are mounted but not in MountWell yet.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding([.horizontal, .top], 20)

            Form {
                ForEach($items) { $item in
                    Section {
                        Toggle(isOn: $item.selected) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: item.share.menuTitle).fontWeight(.medium)
                                Text(verbatim: item.mountPoint).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if item.selected {
                            TextField("Address", text: $item.share.url)
                            TextField("Only in networks", text: $item.share.networks, prompt: Text("optional, e.g. 10.46.,192.168.1."))
                            TextField("Alias", text: $item.share.alias, prompt: Text("optional, shown instead of the share name"))
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: 420)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .glassButton()
                Button("Import \(items.filter(\.selected).count)") {
                    onImport(items)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!items.contains { $0.selected } || items.contains { $0.selected && !$0.share.isValid })
                .glassButton(prominent: true)
            }
            .controlSize(.large)
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 520)
    }
}
