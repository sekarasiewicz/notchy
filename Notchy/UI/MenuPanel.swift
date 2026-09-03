import SwiftUI

struct MenuPanel: View {
    @EnvironmentObject private var manager: MenuBarManager
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Notchy").font(.headline)
                Spacer()
                Toggle("Collapse", isOn: Binding(
                    get: { manager.isHiddenSectionCollapsed },
                    set: { manager.setHiddenSectionCollapsed($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            if !manager.lostItems.isEmpty {
                Label("\(manager.lostItems.count) item(s) have no room on screen", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            sectionHeader("Hidden", hint: "Folds behind ‹")
            if manager.hiddenSectionItems.isEmpty {
                Text("Nothing yet. Use Hide next to a visible icon, or ⌘-drag icons left of ‹ in the menu bar.")
                    .font(.caption).foregroundStyle(.tertiary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 36), spacing: 4)], spacing: 4) {
                    ForEach(manager.hiddenSectionItems) { item in
                        Button { manager.reveal(item) } label: {
                            Group {
                                if let image = manager.hiddenImages[item.key] {
                                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                                } else if let icon = manager.fallbackIcon(for: item) {
                                    Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).padding(3)
                                } else {
                                    Text(String(item.displayName.prefix(2))).font(.caption).foregroundStyle(.white)
                                }
                            }
                            .frame(width: 36, height: 24)
                            .padding(2)
                            // Menu bar glyphs are white on a dark bar; keep that ground.
                            .background(Color(white: 0.18), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .help("\(item.displayName) — click to open")
                        .contextMenu {
                            Button("Show in menu bar") { manager.show(item) }
                        }
                    }
                }
                Text("Click to open. Right-click to move back out.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            Toggle("Fold hidden section when icons run out of room", isOn: $manager.autoCollapse)
                .font(.caption)
                .controlSize(.mini)

            if !ItemImageCapture.hasPermission() {
                HStack(spacing: 6) {
                    Text("Showing app icons. Allow Screen Recording to see the real glyphs.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Allow…") { ItemImageCapture.requestPermission() }
                        .controlSize(.mini)
                }
            }

            sectionHeader("Visible", hint: "Stays in the bar")
            ForEach(manager.pinnedItems) { item in
                HStack(spacing: 6) {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                    Text(item.displayName).font(.callout).lineLimit(1)
                    Spacer()
                    Text("pinned by macOS").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            ForEach(manager.visibleSectionItems.filter { !$0.isOwnedByNotchy }) { item in
                HStack(spacing: 6) {
                    Circle()
                        .fill(item.isOnScreen ? Color.green : Color.red)
                        .frame(width: 6, height: 6)
                    Text(item.displayName).font(.callout).lineLimit(1)
                    Spacer()
                    Button("Hide") { manager.hide(item) }
                        .controlSize(.mini)
                        .disabled(!item.canBeManaged)
                }
            }

            Divider()
            HStack {
                Button("Settings…") {
                    manager.closePanel()
                    SettingsWindow.open(openSettings)
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 300)
        #if DEBUG
        .task {
            if ProcessInfo.processInfo.environment["NOTCHY_OPEN_SETTINGS"] != nil {
                manager.closePanel()
                SettingsWindow.open(openSettings)
            }
        }
        #endif
    }

    private func sectionHeader(_ title: String, hint: String) -> some View {
        HStack {
            Text(title.uppercased()).font(.caption2.weight(.semibold))
            Spacer()
            Text(hint).font(.caption2)
        }
        .foregroundStyle(.secondary)
    }
}
