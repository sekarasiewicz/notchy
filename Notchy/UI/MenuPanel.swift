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
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 8)], spacing: 8) {
                    ForEach(manager.hiddenSectionItems) { item in
                        HiddenTile(item: item)
                    }
                }
                Text("Click to open. Hover and press ↗ (or right-click) to move back to the menu bar.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            Toggle("Fold hidden section when icons run out of room", isOn: $manager.autoCollapse)
                .font(.caption)
                .controlSize(.mini)


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

/// One hidden icon: click opens it in place, the corner button moves it
/// back out to the visible section.
private struct HiddenTile: View {
    @EnvironmentObject private var manager: MenuBarManager
    let item: MenuBarItem
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
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
                .padding(4)
                // Menu bar glyphs are white on a dark bar; keep that ground, but soft.
                .background(Color(white: 0.5).opacity(hovering ? 0.35 : 0.22), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .help("\(item.displayName) — click to open")

            if hovering {
                Button { manager.show(item) } label: {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 14, height: 14)
                        .background(.tint, in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
                .help("Show \(item.displayName) in the menu bar")
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Show in menu bar") { manager.show(item) }
        }
    }
}
